// Package store is M6's durable state layer: the Phase-1 Task record, its
// K.2 state machine, the append-only audit event log, durable idempotency
// records, and the small IR/policy/verification snapshot tables a future
// Runtime (M7) needs to actually drive execution and recover safely after
// a crash. This package implements NO orchestration itself — it never
// calls the Policy Engine or Capability Bus, never decides when a
// transition SHOULD happen, only whether a requested transition is legal
// and, if so, persists it atomically with its audit event. That decision
// boundary is exactly M6 brief's "durable state layer, not M7's
// end-to-end orchestration."
package store

import "friday/ir"

// TaskState mirrors docs/JK-friday-ir-and-runtime-architecture.md §K.2's
// full state machine verbatim — same names, no alternate/invented set
// (M6 brief §5). Extends planner.TaskState (M5, which only implemented
// the CREATED/VALIDATED/PLANNED prefix) with every remaining K.2 state
// this durable layer must now enforce.
type TaskState string

const (
	StateCreated               TaskState = "CREATED"
	StateValidated             TaskState = "VALIDATED"
	StatePlanned               TaskState = "PLANNED"
	StateAwaitingAuthorization TaskState = "AWAITING_AUTHORIZATION"
	StateAuthorized            TaskState = "AUTHORIZED"
	StateRunning               TaskState = "RUNNING"
	StateVerifying             TaskState = "VERIFYING"
	StateSucceeded             TaskState = "SUCCEEDED"
	StateFailed                TaskState = "FAILED"
	StateCancelled             TaskState = "CANCELLED"
	StateCompensating          TaskState = "COMPENSATING"
	StateCompensated           TaskState = "COMPENSATED"
	StateRequiresManualReview  TaskState = "requires_manual_review" // K.2's own casing, verbatim
)

func (s TaskState) valid() bool {
	switch s {
	case StateCreated, StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized,
		StateRunning, StateVerifying, StateSucceeded, StateFailed, StateCancelled,
		StateCompensating, StateCompensated, StateRequiresManualReview:
		return true
	}
	return false
}

// Terminal reports whether a state has no legal outgoing transition at
// all (see legalTransitions below). FAILED is deliberately NOT terminal:
// K.2/§K.6 allow FAILED -> AWAITING_AUTHORIZATION (retry) and
// FAILED -> COMPENSATING (compensation after a failed, side-effecting
// attempt) — a FAILED task may still resolve further; it just isn't
// guaranteed to.
func (s TaskState) Terminal() bool {
	switch s {
	case StateSucceeded, StateCancelled, StateCompensated, StateRequiresManualReview:
		return true
	}
	return false
}

// legalTransitions is the complete K.2 adjacency map, compiled from:
//   - JK §K.2's state diagram (the base CREATED..SUCCEEDED/FAILED/
//     COMPENSATING/COMPENSATED/requires_manual_review graph)
//   - PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §3's "which states accept
//     STOP" table (every non-terminal state -> CANCELLED)
//   - PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §4's flowchart (VERIFYING's
//     three branches: SUCCEEDED / FAILED / CANCELLED / COMPENSATING /
//     requires_manual_review, and COMPENSATING's two outcomes)
//   - STOP-005's "FAILED, about to retry (re-entering
//     AWAITING_AUTHORIZATION per K.6)" — FAILED -> AWAITING_AUTHORIZATION
//
// Three edges are this package's own disclosed, minimal completions of an
// undrawn corner of K.2, not silently invented:
//  1. AWAITING_AUTHORIZATION -> FAILED. K.2's diagram only draws the
//     ALLOW path forward from AWAITING_AUTHORIZATION; it never draws what
//     happens on a Policy Engine DENY. FAILED is the natural resting
//     state for "authorization did not succeed," consistent with how
//     FAILED is already used elsewhere (verification failure) — recorded
//     here, not left as an unreachable gap the store would otherwise
//     reject with no legal transition at all for a real DENY outcome.
//  2. VERIFYING -> COMPENSATING is legal even outside the stop-triggered
//     path (a side-effecting capability's verification can fail in a way
//     that itself calls for compensation, per K.2's base diagram showing
//     FAILED -> COMPENSATING; VERIFYING -> COMPENSATING covers the
//     emergency-stop spec's §4 flow where compensation is entered
//     directly from VERIFYING without an intermediate FAILED record).
//  3. CREATED -> FAILED, added during M7. K.2 annotates the CREATED ->
//     VALIDATED edge with its condition ("IR validation... all 4 stages
//     pass") but never draws what happens when validation does NOT pass
//     — M7's real orchestrator hits this exact case (a compiler-produced
//     RawIR that ir.Validate rejects) and needs a legal resting state for
//     it. FAILED is used for the same reason as completion #1 above:
//     it's already the established resting state for "a pipeline gate
//     did not pass," applied consistently at every gate (validation,
//     authorization, verification) rather than inventing a fourth
//     failure-state name.
var legalTransitions = map[TaskState]map[TaskState]bool{
	StateCreated:               {StateValidated: true, StateCancelled: true, StateFailed: true},
	StateValidated:             {StatePlanned: true, StateCancelled: true},
	StatePlanned:               {StateAwaitingAuthorization: true, StateCancelled: true},
	StateAwaitingAuthorization: {StateAuthorized: true, StateCancelled: true, StateFailed: true},
	StateAuthorized:            {StateRunning: true, StateCancelled: true},
	StateRunning:               {StateVerifying: true, StateCancelled: true},
	StateVerifying: {
		StateSucceeded: true, StateFailed: true, StateCancelled: true,
		StateCompensating: true, StateRequiresManualReview: true,
	},
	StateFailed: {StateCompensating: true, StateAwaitingAuthorization: true, StateCancelled: true},
	StateCompensating: {
		StateCompensated: true, StateRequiresManualReview: true,
	},
	StateSucceeded:            {},
	StateCancelled:            {},
	StateCompensated:          {},
	StateRequiresManualReview: {},
}

// CanTransition reports whether from -> to is a legal K.2 transition.
func CanTransition(from, to TaskState) bool {
	next, ok := legalTransitions[from]
	if !ok {
		return false
	}
	return next[to]
}

// requiredAALForRisk is duplicated, deliberately, from services/ir and
// services/policy-engine's equivalent tables — same disclosed tradeoff as
// those two modules' own copies (module independence over a shared
// import; see ir/types.go's doc comment). Used only by validation.go's
// read-time sanity checks, never to make an authorization decision.
func requiredAALForRisk(r ir.RiskLevel) ir.AAL {
	switch r {
	case ir.RiskNone:
		return ir.AAL0
	case ir.RiskLow:
		return ir.AAL1
	case ir.RiskExternalSideEffect:
		return ir.AAL2
	case ir.RiskHigh:
		return ir.AAL3
	case ir.RiskCritical:
		return ir.AAL4
	default:
		return ir.AAL4
	}
}
