package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"friday/ir"
)

// IRSnapshot is the "ValidatedIR snapshot or safe reference" M6 brief §4
// asks for — enough of the validated IR for a future Runtime to actually
// drive execution and re-derive the arguments digest after a restart,
// without duplicating the entire IR document (constraints/entities/
// knowledge_state are Planner/Compiler-internal detail this durable layer
// does not need to replay).
type IRSnapshot struct {
	IRID               string
	TaskID             string
	CapabilityID       string
	RiskLevel          ir.RiskLevel
	Reversible         bool
	Arguments          map[string]interface{}
	ArgumentsDigest    string
	DataClassification string
	Forgotten          bool
	ForgottenAt        *time.Time
	CreatedAt          time.Time
}

func (s *Store) SaveIRSnapshot(ctx context.Context, snap IRSnapshot) error {
	if snap.IRID == "" || snap.TaskID == "" || snap.CapabilityID == "" {
		return newStoreErr(ErrPersistenceUnavailable, "IR snapshot is missing required fields", nil)
	}
	argsJSON, err := json.Marshal(snap.Arguments)
	if err != nil {
		return newStoreErr(ErrPersistenceUnavailable, "marshaling snapshot arguments", err)
	}
	now := snap.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	return s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO ir_snapshots (ir_id, task_id, capability_id, risk_level, reversible, arguments_json, arguments_digest, data_classification, forgotten, forgotten_at, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)`,
			snap.IRID, snap.TaskID, snap.CapabilityID, string(snap.RiskLevel), boolToInt(snap.Reversible),
			string(argsJSON), snap.ArgumentsDigest, snap.DataClassification, now.Format(time.RFC3339Nano))
		if err != nil {
			if isUniqueConstraintErr(err) {
				return newStoreErr(ErrPersistenceConflict, "ir_id already has a snapshot", err)
			}
			return newStoreErr(ErrPersistenceUnavailable, "inserting IR snapshot", err)
		}
		return nil
	})
}

func (s *Store) GetIRSnapshot(ctx context.Context, irID string) (IRSnapshot, error) {
	var snap IRSnapshot
	var riskLevel, argsJSON, createdAt string
	var reversible, forgotten int
	var forgottenAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT ir_id, task_id, capability_id, risk_level, reversible, arguments_json, arguments_digest, data_classification, forgotten, forgotten_at, created_at
		FROM ir_snapshots WHERE ir_id = ?`, irID).
		Scan(&snap.IRID, &snap.TaskID, &snap.CapabilityID, &riskLevel, &reversible, &argsJSON,
			&snap.ArgumentsDigest, &snap.DataClassification, &forgotten, &forgottenAt, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return IRSnapshot{}, newStoreErr(ErrRecordNotFound, "IR snapshot not found", err)
	}
	if err != nil {
		return IRSnapshot{}, newStoreErr(ErrPersistenceUnavailable, "reading IR snapshot", err)
	}
	snap.RiskLevel = ir.RiskLevel(riskLevel)
	snap.Reversible = reversible != 0
	snap.Forgotten = forgotten != 0
	if err := json.Unmarshal([]byte(argsJSON), &snap.Arguments); err != nil {
		return IRSnapshot{}, newStoreErr(ErrCorruptRecord, "unparseable snapshot arguments", err)
	}
	snap.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return IRSnapshot{}, newStoreErr(ErrCorruptRecord, "unparseable snapshot created_at", err)
	}
	if forgottenAt.Valid {
		t, err := time.Parse(time.RFC3339Nano, forgottenAt.String)
		if err != nil {
			return IRSnapshot{}, newStoreErr(ErrCorruptRecord, "unparseable snapshot forgotten_at", err)
		}
		snap.ForgottenAt = &t
	}
	return snap, nil
}

// ForgetIRSnapshotContent implements the durable-storage half of FR-MEM-004
// (mechanism only, Phase 1): it overwrites the CONTENT-bearing fields of
// an IR snapshot (arguments_json, arguments_digest — the note title/body
// for workspace.create_note) with a tombstone, and marks it forgotten.
// It deliberately does NOT touch, and has no way to touch, the tasks,
// audit_events, idempotency_records, verification_results, or
// capability_invocations tables — those are mandatory operational/audit
// records (M8 brief §9/§10), never eligible for this operation, and this
// function's SQL statement has no path to them at all.
//
// Idempotent: forgetting an already-forgotten snapshot is a no-op
// success, not an error (FORGET-003) — the second call still returns nil
// and leaves forgotten_at at its original value.
func (s *Store) ForgetIRSnapshotContent(ctx context.Context, irID string) error {
	return s.withTx(ctx, func(tx *sql.Tx) error {
		var forgotten int
		err := tx.QueryRowContext(ctx, `SELECT forgotten FROM ir_snapshots WHERE ir_id = ?`, irID).Scan(&forgotten)
		if errors.Is(err, sql.ErrNoRows) {
			return newStoreErr(ErrRecordNotFound, "IR snapshot not found", err)
		}
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "reading IR snapshot", err)
		}
		if forgotten != 0 {
			return nil // already forgotten — idempotent no-op
		}
		tombstone, _ := json.Marshal(map[string]interface{}{"__forgotten__": true})
		_, err = tx.ExecContext(ctx, `
			UPDATE ir_snapshots SET arguments_json = ?, arguments_digest = '', forgotten = 1, forgotten_at = ?
			WHERE ir_id = ?`,
			string(tombstone), time.Now().UTC().Format(time.RFC3339Nano), irID)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "forgetting IR snapshot content", err)
		}
		return nil
	})
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
