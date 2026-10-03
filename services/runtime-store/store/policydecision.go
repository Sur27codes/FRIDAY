package store

import (
	"context"
	"database/sql"
	"time"
)

// PolicyDecision is a durable reference to a Policy Engine decision — it
// never stores the token's signature or any private key material, only
// the token_id and expiry needed to reason about freshness after a
// restart (M6 brief §4/§12: authorization metadata, not authorization
// material itself).
type PolicyDecision struct {
	DecisionID     string
	TaskID         string
	Decision       string // ALLOW | DENY | CONFIRM | STRONG_AUTH_REQUIRED
	RequiredAAL    string
	Reason         string
	TokenID        string // "" if no token was issued
	TokenExpiresAt *time.Time
	EvaluatedAt    time.Time
}

func (s *Store) SavePolicyDecision(ctx context.Context, d PolicyDecision) (string, error) {
	if d.TaskID == "" || d.Decision == "" {
		return "", newStoreErr(ErrPersistenceUnavailable, "policy decision is missing required fields", nil)
	}
	id, err := newID()
	if err != nil {
		return "", newStoreErr(ErrPersistenceUnavailable, "generating decision_id", err)
	}
	evaluatedAt := d.EvaluatedAt
	if evaluatedAt.IsZero() {
		evaluatedAt = time.Now().UTC()
	}
	var expiresAt interface{}
	if d.TokenExpiresAt != nil {
		expiresAt = d.TokenExpiresAt.Format(time.RFC3339Nano)
	}
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO policy_decisions (decision_id, task_id, decision, required_aal, reason, token_id, token_expires_at, evaluated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			id, d.TaskID, d.Decision, d.RequiredAAL, d.Reason, nullIfEmpty(d.TokenID), expiresAt, evaluatedAt.Format(time.RFC3339Nano))
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "inserting policy decision", err)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return id, nil
}
