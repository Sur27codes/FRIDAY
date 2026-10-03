package store

import (
	"context"
	"database/sql"
	"time"
)

type VerificationOutcome string

const (
	VerificationSucceeded VerificationOutcome = "SUCCEEDED"
	VerificationFailed    VerificationOutcome = "FAILED"
)

// VerificationResult is persisted SEPARATELY from CapabilityInvocation
// (M6 core invariant 4 / M6-AUD-008: "SUCCEEDED requires the verification
// contract to pass" — a durable record must be able to show these two
// facts independently, never conflated into one "it worked" flag).
type VerificationResult struct {
	VerificationID      string
	TaskID              string
	Method              string
	StartedAt           time.Time
	CompletedAt         *time.Time
	Result              VerificationOutcome
	SideEffectConfirmed *bool
}

func (s *Store) StartVerification(ctx context.Context, taskID, method string) (string, error) {
	id, err := newID()
	if err != nil {
		return "", newStoreErr(ErrPersistenceUnavailable, "generating verification_id", err)
	}
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO verification_results (verification_id, task_id, method, started_at, completed_at, result, side_effect_confirmed)
			VALUES (?, ?, ?, ?, NULL, NULL, NULL)`,
			id, taskID, method, time.Now().UTC().Format(time.RFC3339Nano))
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "inserting verification result", err)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

func (s *Store) CompleteVerification(ctx context.Context, verificationID string, result VerificationOutcome, sideEffectConfirmed bool) error {
	return s.withTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE verification_results SET completed_at = ?, result = ?, side_effect_confirmed = ? WHERE verification_id = ?`,
			time.Now().UTC().Format(time.RFC3339Nano), string(result), boolToInt(sideEffectConfirmed), verificationID)
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "completing verification result", err)
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return newStoreErr(ErrRecordNotFound, "verification result not found", nil)
		}
		return nil
	})
}

func (s *Store) GetVerificationsForTask(ctx context.Context, taskID string) ([]VerificationResult, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT verification_id, task_id, method, started_at, completed_at, result, side_effect_confirmed
		FROM verification_results WHERE task_id = ? ORDER BY started_at ASC`, taskID)
	if err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "querying verification results", err)
	}
	defer rows.Close()

	var out []VerificationResult
	for rows.Next() {
		var v VerificationResult
		var startedAt string
		var completedAt, result sql.NullString
		var sideEffect sql.NullInt64
		if err := rows.Scan(&v.VerificationID, &v.TaskID, &v.Method, &startedAt, &completedAt, &result, &sideEffect); err != nil {
			return nil, newStoreErr(ErrPersistenceUnavailable, "scanning verification result", err)
		}
		v.StartedAt, err = time.Parse(time.RFC3339Nano, startedAt)
		if err != nil {
			return nil, newStoreErr(ErrCorruptRecord, "unparseable verification started_at", err)
		}
		if completedAt.Valid {
			t, err := time.Parse(time.RFC3339Nano, completedAt.String)
			if err != nil {
				return nil, newStoreErr(ErrCorruptRecord, "unparseable verification completed_at", err)
			}
			v.CompletedAt = &t
		}
		v.Result = VerificationOutcome(result.String)
		if sideEffect.Valid {
			b := sideEffect.Int64 != 0
			v.SideEffectConfirmed = &b
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "iterating verification results", err)
	}
	return out, nil
}
