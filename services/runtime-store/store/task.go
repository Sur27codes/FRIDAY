package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

// Task is the durable, mutable current-state projection (M6 brief §14:
// distinct from AuditEvent, which is historical). Every field here is
// safe to read back after a restart with no further interpretation
// needed to know "what state is this task in right now."
type Task struct {
	TaskID                string
	CorrelationID         string
	CausationID           string // "" if this is the root task
	Actor                 string
	CapabilityID          string
	IRID                  string
	State                 TaskState
	IdempotencyKey        string
	CancellationRequested bool
	CreatedAt             time.Time
	UpdatedAt             time.Time
}

// CreateTask persists a brand-new task in StateCreated. taskID/irID are
// caller-supplied (the not-yet-built Runtime, or a test harness) — this
// package never mints them, matching M3/M4's established pattern.
func (s *Store) CreateTask(ctx context.Context, t Task) error {
	if t.TaskID == "" || t.CorrelationID == "" || t.Actor == "" || t.CapabilityID == "" || t.IRID == "" || t.IdempotencyKey == "" {
		return newStoreErr(ErrInvalidStateTransition, "task is missing one or more required fields", nil)
	}
	now := time.Now().UTC()
	return s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO tasks (task_id, correlation_id, causation_id, actor, capability_id, ir_id, state, idempotency_key, cancellation_requested, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
			t.TaskID, t.CorrelationID, nullIfEmpty(t.CausationID), t.Actor, t.CapabilityID, t.IRID,
			string(StateCreated), t.IdempotencyKey, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano))
		if err != nil {
			if isUniqueConstraintErr(err) {
				return newStoreErr(ErrPersistenceConflict, "task_id already exists", err)
			}
			return newStoreErr(ErrPersistenceUnavailable, "inserting task", err)
		}
		return nil
	})
}

// GetTask reads a task's current projection, validating every stored
// field on read (M6 brief §23: malformed persisted state must never
// become a permissive default) — an unrecognized state string, for
// example, fails closed as CORRUPT_RECORD rather than being treated as
// some default state.
func (s *Store) GetTask(ctx context.Context, taskID string) (Task, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT task_id, correlation_id, causation_id, actor, capability_id, ir_id, state, idempotency_key, cancellation_requested, created_at, updated_at
		FROM tasks WHERE task_id = ?`, taskID)
	return scanTask(row)
}

func scanTask(row *sql.Row) (Task, error) {
	var t Task
	var causationID sql.NullString
	var state, createdAt, updatedAt string
	var cancellationRequested int
	err := row.Scan(&t.TaskID, &t.CorrelationID, &causationID, &t.Actor, &t.CapabilityID, &t.IRID,
		&state, &t.IdempotencyKey, &cancellationRequested, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Task{}, newStoreErr(ErrRecordNotFound, "task not found", err)
	}
	if err != nil {
		return Task{}, newStoreErr(ErrPersistenceUnavailable, "reading task", err)
	}

	t.CausationID = causationID.String
	t.CancellationRequested = cancellationRequested != 0
	t.State = TaskState(state)
	if !t.State.valid() {
		return Task{}, newStoreErr(ErrCorruptRecord, "stored task has an unrecognized state value", nil)
	}
	t.CreatedAt, err = time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return Task{}, newStoreErr(ErrCorruptRecord, "stored task has an unparseable created_at", err)
	}
	t.UpdatedAt, err = time.Parse(time.RFC3339Nano, updatedAt)
	if err != nil {
		return Task{}, newStoreErr(ErrCorruptRecord, "stored task has an unparseable updated_at", err)
	}
	return t, nil
}

// TransitionTask attempts to move a task from its currently-persisted
// state to toState. It re-reads the current state INSIDE the same
// transaction (never trusts a caller-supplied "from" state), validates
// legality via CanTransition, and applies a conditional UPDATE guarded by
// the exact state just read — if a concurrent transition already changed
// the state between the read and this write, the conditional UPDATE
// affects zero rows and this returns PERSISTENCE_CONFLICT rather than
// silently overwriting a state some other actor already moved past (M6
// brief §25, M6-STATE-008).
//
// A CANCELLED task's terminal-state check happens here structurally:
// Terminal states have no legal outgoing edges in legalTransitions at
// all, so any attempted transition out of CANCELLED (e.g. -> RUNNING)
// fails as INVALID_STATE_TRANSITION regardless of caller intent — this
// is the concrete mechanism behind M6-STATE-006/STOP-008 ("cancelled task
// cannot silently resume").
func (s *Store) TransitionTask(ctx context.Context, taskID string, to TaskState) error {
	if !to.valid() {
		return newStoreErr(ErrInvalidStateTransition, "target state is not a recognized K.2 state", nil)
	}
	return s.withTx(ctx, func(tx *sql.Tx) error {
		var current string
		err := tx.QueryRowContext(ctx, `SELECT state FROM tasks WHERE task_id = ?`, taskID).Scan(&current)
		if errors.Is(err, sql.ErrNoRows) {
			return newStoreErr(ErrRecordNotFound, "task not found", err)
		}
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "reading current task state", err)
		}
		from := TaskState(current)
		if !from.valid() {
			return newStoreErr(ErrCorruptRecord, "stored task has an unrecognized state value", nil)
		}
		if !CanTransition(from, to) {
			return newStoreErr(ErrInvalidStateTransition, string(from)+" -> "+string(to)+" is not a legal K.2 transition", nil)
		}

		res, err := tx.ExecContext(ctx, `UPDATE tasks SET state = ?, updated_at = ? WHERE task_id = ? AND state = ?`,
			string(to), time.Now().UTC().Format(time.RFC3339Nano), taskID, current)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "applying transition", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "checking transition result", err)
		}
		if n == 0 {
			return newStoreErr(ErrPersistenceConflict, "task state changed concurrently; transition not applied", nil)
		}
		return nil
	})
}

// RequestCancellation records that cancellation was requested for a task
// — a durable flag distinct from the state transition itself, so a
// future Runtime can observe "a stop was requested" even for a task that
// is (correctly) still finishing an in-flight VERIFYING step before its
// terminal state is decided (PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §3's
// VERIFYING row: verification is allowed to complete; the stop request
// itself is still durably recorded the moment it arrives, per STOP-010's
// audit-reconstruction requirement).
func (s *Store) RequestCancellation(ctx context.Context, taskID string) error {
	return s.withTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE tasks SET cancellation_requested = 1, updated_at = ? WHERE task_id = ?`,
			time.Now().UTC().Format(time.RFC3339Nano), taskID)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "recording cancellation request", err)
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return newStoreErr(ErrRecordNotFound, "task not found", nil)
		}
		return nil
	})
}

func nullIfEmpty(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func isUniqueConstraintErr(err error) bool {
	// modernc.org/sqlite reports constraint violations with this
	// substring — matched narrowly so this only ever recognizes a genuine
	// uniqueness conflict, never masks a different failure as one.
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
