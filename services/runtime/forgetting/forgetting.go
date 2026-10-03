// Package forgetting implements the M8 closure milestone's minimal
// Phase-1 forgetting mechanism (FR-MEM-004, "(mechanism)" scope for
// Phase 1 — full cross-store propagation is explicitly Core-Daily-Use/
// Phase-3 scope, not required here).
//
// Phase-1-eligible-for-forgetting data is exactly one thing: the
// content-bearing fields of an IR snapshot (a note's title/body — the
// only PERSONAL-classified content Phase 1 ever durably stores, per
// runtime-store's own DataClassification field). Mandatory operational/
// audit records — the task's own state history, every audit_events row,
// idempotency_records, verification_results, capability_invocations —
// are never eligible and are structurally unreachable from this
// package: the only runtime-store mutation this package calls is
// ForgetIRSnapshotContent, which itself has no SQL path to any other
// table (M8 brief §9/§10).
package forgetting

import (
	"context"
	"errors"

	"friday/runtime-store/store"
)

var (
	// ErrTaskNotFound: no such task — nothing to forget.
	ErrTaskNotFound = errors.New("task not found")
	// ErrActorMismatch: the requesting actor does not own this task —
	// forgetting is bounded to the correct actor (FORGET-007), never a
	// generic "delete any record by ID" operation (FORGET-006).
	ErrActorMismatch = errors.New("forgetting is bounded to the requesting actor")
)

// Request is a user's forget request, scoped to exactly one task's IR
// snapshot content.
type Request struct {
	TaskID string
	Actor  string
}

type Result struct {
	Forgotten bool // always true on success (including the idempotent-repeat case)
}

// Forget is the package's only mutating entry point. It resolves TaskID
// to its owning IR snapshot itself (never trusting a caller-supplied
// IR ID directly — FORGET-006's "cannot delete arbitrary database
// records"), verifies actor ownership, and delegates the actual
// tombstone write to runtime-store.
func Forget(ctx context.Context, st *store.Store, req Request) (Result, error) {
	if req.TaskID == "" || req.Actor == "" {
		return Result{}, ErrTaskNotFound
	}
	task, err := st.GetTask(ctx, req.TaskID)
	if err != nil {
		return Result{}, ErrTaskNotFound
	}
	if task.Actor != req.Actor {
		return Result{}, ErrActorMismatch
	}
	if err := st.ForgetIRSnapshotContent(ctx, task.IRID); err != nil {
		return Result{}, err
	}
	return Result{Forgotten: true}, nil
}

// Retrieve returns the current (possibly-tombstoned) IR snapshot for a
// task through the same normal retrieval path any other caller would
// use — used to prove FORGET-002 ("forgotten record is no longer
// returned through normal retrieval") without this package needing any
// special-cased read API of its own that could diverge from what every
// other caller actually sees.
func Retrieve(ctx context.Context, st *store.Store, taskID string) (store.IRSnapshot, error) {
	task, err := st.GetTask(ctx, taskID)
	if err != nil {
		return store.IRSnapshot{}, ErrTaskNotFound
	}
	return st.GetIRSnapshot(ctx, task.IRID)
}
