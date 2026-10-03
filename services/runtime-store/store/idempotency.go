package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type IdempotencyStatus string

const (
	IdempotencyPending   IdempotencyStatus = "PENDING"
	IdempotencyCompleted IdempotencyStatus = "COMPLETED"
)

// IdempotencyRecord mirrors M6 brief §10's field list exactly — no raw
// sensitive payload, only the digest (M6 brief §10: "do not store raw
// sensitive payloads unnecessarily").
type IdempotencyRecord struct {
	IdempotencyKey  string
	TaskID          string
	CapabilityID    string
	ArgumentsDigest string
	Status          IdempotencyStatus
	CreatedAt       time.Time
	CompletedAt     *time.Time
}

// RegisterIdempotency implements M6 brief §9's durable semantics:
//   - key not yet seen                                -> new PENDING record created, Created=true
//   - key seen, SAME capability_id + arguments_digest  -> existing record returned, Created=false (deterministic duplicate handling)
//   - key seen, DIFFERENT capability_id or digest       -> IDEMPOTENCY_MISMATCH, rejected
//
// Correct under concurrent registration of the SAME key (M6-IDEM-004):
// the table's idempotency_key PRIMARY KEY makes a losing concurrent
// INSERT fail with a uniqueness violation rather than silently
// overwriting the winner; the loser then re-reads the now-existing row
// and applies the same match/mismatch logic a sequential caller would
// have seen, so both callers converge on one deterministic outcome
// regardless of arrival order.
func (s *Store) RegisterIdempotency(ctx context.Context, key, taskID, capabilityID, argumentsDigest string) (rec IdempotencyRecord, created bool, err error) {
	if key == "" || taskID == "" || capabilityID == "" || argumentsDigest == "" {
		return IdempotencyRecord{}, false, newStoreErr(ErrDuplicateIdempotency, "all idempotency fields are required", nil)
	}

	txErr := s.withTx(ctx, func(tx *sql.Tx) error {
		existing, getErr := getIdempotencyTx(ctx, tx, key)
		if getErr == nil {
			// Key already registered — deterministic match/mismatch check.
			if existing.CapabilityID != capabilityID || existing.ArgumentsDigest != argumentsDigest {
				return newStoreErr(ErrIdempotencyMismatch,
					"idempotency key already registered for different capability/arguments", nil)
			}
			rec, created = existing, false
			return nil
		}
		var se *StoreError
		if !errors.As(getErr, &se) || se.Code != ErrRecordNotFound {
			return getErr
		}

		now := time.Now().UTC()
		_, insErr := tx.ExecContext(ctx, `
			INSERT INTO idempotency_records (idempotency_key, task_id, capability_id, arguments_digest, status, created_at, completed_at)
			VALUES (?, ?, ?, ?, ?, ?, NULL)`,
			key, taskID, capabilityID, argumentsDigest, string(IdempotencyPending), now.Format(time.RFC3339Nano))
		if insErr != nil {
			if isUniqueConstraintErr(insErr) {
				// Lost a concurrent race to register the same key — re-read
				// and apply the same match/mismatch logic as above.
				existing, getErr2 := getIdempotencyTx(ctx, tx, key)
				if getErr2 != nil {
					return getErr2
				}
				if existing.CapabilityID != capabilityID || existing.ArgumentsDigest != argumentsDigest {
					return newStoreErr(ErrIdempotencyMismatch,
						"idempotency key already registered for different capability/arguments", nil)
				}
				rec, created = existing, false
				return nil
			}
			return newStoreErr(ErrPersistenceUnavailable, "inserting idempotency record", insErr)
		}
		rec = IdempotencyRecord{
			IdempotencyKey: key, TaskID: taskID, CapabilityID: capabilityID,
			ArgumentsDigest: argumentsDigest, Status: IdempotencyPending, CreatedAt: now,
		}
		created = true
		return nil
	})
	if txErr != nil {
		return IdempotencyRecord{}, false, txErr
	}
	return rec, created, nil
}

// CompleteIdempotency marks a PENDING idempotency record COMPLETED —
// called once the capability invocation it guards has actually finished
// (any terminal outcome), so a subsequent lookup can distinguish "still
// in flight" from "already resolved."
func (s *Store) CompleteIdempotency(ctx context.Context, key string) error {
	return s.withTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE idempotency_records SET status = ?, completed_at = ? WHERE idempotency_key = ?`,
			string(IdempotencyCompleted), time.Now().UTC().Format(time.RFC3339Nano), key)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "completing idempotency record", err)
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return newStoreErr(ErrRecordNotFound, "idempotency record not found", nil)
		}
		return nil
	})
}

// RepairOrphanedIdempotencyRecords removes idempotency records left
// permanently stuck in PENDING with no corresponding task row — a state
// that can only arise from a request that failed after
// RegisterIdempotency succeeded but before CreateTask succeeded (P2-M4R:
// found via a real production request whose orchestrator-level
// CreateTask call failed validation; that failure branch did not call
// CompleteIdempotency, the way every other failure branch in
// Orchestrator.HandleTextRequest does, leaving the PENDING row orphaned
// forever — every later request for the same idempotency key then read
// that same still-PENDING row and was permanently misclassified as
// DUPLICATE_REQUEST). The orchestrator-side gap is fixed directly (that
// failure branch now calls CompleteIdempotency like its siblings), so no
// NEW orphan of this shape can be created going forward — this function
// exists only to repair rows already written before that fix, on
// upgrade.
//
// Safe by construction: this daemon is a single process, so nothing can
// be "genuinely still in flight" for a request across a process
// restart — whatever was mid-flight when the process last stopped is
// already gone. A PENDING record whose task_id has no matching row in
// tasks is therefore, unconditionally, an orphan left over from an
// interrupted or failed attempt, never a currently-active guard, and is
// always safe to clear at startup, before any new request is served.
func (s *Store) RepairOrphanedIdempotencyRecords(ctx context.Context) (int, error) {
	var affected int64
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `
			DELETE FROM idempotency_records
			WHERE status = ? AND task_id NOT IN (SELECT task_id FROM tasks)`,
			string(IdempotencyPending))
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "repairing orphaned idempotency records", err)
		}
		affected, _ = res.RowsAffected()
		return nil
	})
	return int(affected), err
}

func (s *Store) GetIdempotency(ctx context.Context, key string) (IdempotencyRecord, error) {
	var rec IdempotencyRecord
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		r, err := getIdempotencyTx(ctx, tx, key)
		rec = r
		return err
	})
	return rec, err
}

func getIdempotencyTx(ctx context.Context, tx *sql.Tx, key string) (IdempotencyRecord, error) {
	var rec IdempotencyRecord
	var status, createdAt string
	var completedAt sql.NullString
	err := tx.QueryRowContext(ctx, `
		SELECT idempotency_key, task_id, capability_id, arguments_digest, status, created_at, completed_at
		FROM idempotency_records WHERE idempotency_key = ?`, key).
		Scan(&rec.IdempotencyKey, &rec.TaskID, &rec.CapabilityID, &rec.ArgumentsDigest, &status, &createdAt, &completedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return IdempotencyRecord{}, newStoreErr(ErrRecordNotFound, "idempotency record not found", err)
	}
	if err != nil {
		return IdempotencyRecord{}, newStoreErr(ErrPersistenceUnavailable, "reading idempotency record", err)
	}
	rec.Status = IdempotencyStatus(status)
	rec.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return IdempotencyRecord{}, newStoreErr(ErrCorruptRecord, "unparseable idempotency created_at", err)
	}
	if completedAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, completedAt.String)
		if err != nil {
			return IdempotencyRecord{}, newStoreErr(ErrCorruptRecord, "unparseable idempotency completed_at", err)
		}
		rec.CompletedAt = &t
	}
	return rec, nil
}
