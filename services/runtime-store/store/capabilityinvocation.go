package store

import (
	"context"
	"database/sql"
	"time"
)

type InvocationOutcome string

const (
	OutcomeExecuted        InvocationOutcome = "EXECUTED" // adapter returned; NOT the same as succeeded (M6 core invariant 3)
	OutcomeExecutionFailed InvocationOutcome = "EXECUTION_FAILED"
)

// CapabilityInvocation records one adapter call attempt. CompletedAt/
// OutcomeStatus are nil/"" until StartInvocation's paired
// CompleteInvocation call runs — a row that only has a start time and no
// completion is exactly the durable signal M6-REC-004/007 need: "the
// process crashed somewhere between the call starting and its outcome
// being recorded," which is different information than "it succeeded"
// or "it failed."
type CapabilityInvocation struct {
	InvocationID  string
	TaskID        string
	CapabilityID  string
	StartedAt     time.Time
	CompletedAt   *time.Time
	OutcomeStatus InvocationOutcome
}

func (s *Store) StartInvocation(ctx context.Context, taskID, capabilityID string) (string, error) {
	id, err := newID()
	if err != nil {
		return "", newStoreErr(ErrPersistenceUnavailable, "generating invocation_id", err)
	}
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO capability_invocations (invocation_id, task_id, capability_id, started_at, completed_at, outcome_status)
			VALUES (?, ?, ?, ?, NULL, NULL)`,
			id, taskID, capabilityID, time.Now().UTC().Format(time.RFC3339Nano))
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "inserting capability invocation", err)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

func (s *Store) CompleteInvocation(ctx context.Context, invocationID string, outcome InvocationOutcome) error {
	return s.withTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE capability_invocations SET completed_at = ?, outcome_status = ? WHERE invocation_id = ?`,
			time.Now().UTC().Format(time.RFC3339Nano), string(outcome), invocationID)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "completing capability invocation", err)
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return newStoreErr(ErrRecordNotFound, "capability invocation not found", nil)
		}
		return nil
	})
}

// GetInvocationsForTask returns every invocation attempt for a task,
// oldest first — used by crash-recovery logic to answer "was the adapter
// ever actually called for this task" (distinct from whether it
// completed).
func (s *Store) GetInvocationsForTask(ctx context.Context, taskID string) ([]CapabilityInvocation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT invocation_id, task_id, capability_id, started_at, completed_at, outcome_status
		FROM capability_invocations WHERE task_id = ? ORDER BY started_at ASC`, taskID)
	if err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "querying capability invocations", err)
	}
	defer rows.Close()

	var out []CapabilityInvocation
	for rows.Next() {
		var inv CapabilityInvocation
		var startedAt string
		var completedAt, outcome sql.NullString
		if err := rows.Scan(&inv.InvocationID, &inv.TaskID, &inv.CapabilityID, &startedAt, &completedAt, &outcome); err != nil {
			return nil, newStoreErr(ErrPersistenceUnavailable, "scanning capability invocation", err)
		}
		inv.StartedAt, err = time.Parse(time.RFC3339Nano, startedAt)
		if err != nil {
			return nil, newStoreErr(ErrCorruptRecord, "unparseable invocation started_at", err)
		}
		if completedAt.Valid {
			t, err := time.Parse(time.RFC3339Nano, completedAt.String)
			if err != nil {
				return nil, newStoreErr(ErrCorruptRecord, "unparseable invocation completed_at", err)
			}
			inv.CompletedAt = &t
		}
		inv.OutcomeStatus = InvocationOutcome(outcome.String)
		out = append(out, inv)
	}
	if err := rows.Err(); err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "iterating capability invocations", err)
	}
	return out, nil
}
