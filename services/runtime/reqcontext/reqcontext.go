// Package reqcontext implements the M8 closure milestone's minimal
// Phase-1 Context Compiler + Context Firewall (FR-CONTEXT-001,
// FR-CONTEXT-002; design: docs/MN-memory-and-knowledge-architecture.md
// §N.9 — "The Context Compiler selects the minimum relevant slice...
// optimizing for relevance, token cost, privacy, and freshness; the
// Context Firewall enforces that [a component] never receives
// [out-of-scope content]").
//
// This is deliberately NOT the future Universal Context Compiler: there
// is no person/project/device/memory knowledge base to select from in
// Phase 1, no model call that consumes assembled context, and no
// broader "context universe" a real request could pull from beyond its
// own validated IR. The minimal, honest Phase-1 version of this
// architecture is a two-step structural gate:
//
//  1. Compile: assembles a bounded Object from EXACTLY the validated IR
//     + actor + session — nothing else. This is proven, not merely
//     claimed, by Compile's own function signature: it has no parameter
//     through which any other task's data, another session's data, or
//     arbitrary environment data could reach it (FR-CONTEXT-001,
//     CTX-003/CTX-006).
//  2. Firewall: trims Object.Arguments to exactly the capability's own
//     declared allowed-argument-key set (the same set
//     capability-bus/internal/registry and services/ir's
//     CapabilitySchema.RequiredArgs already independently enforce at
//     validation time — this is intentional defense-in-depth, not the
//     only check) (FR-CONTEXT-002, CTX-001/CTX-002/CTX-004).
//
// Neither step can widen anything: Firewall only ever REMOVES keys, has
// no parameter through which it could add one, and neither function
// returns anything resembling an authorization decision, a token, or a
// capability grant — see runtime/orchestrator's own isolation test for
// the structural proof that this package has no dependency on
// friday/policy-engine or friday/capability-bus either.
package reqcontext

import (
	"sort"

	"friday/ir"
)

// Object is the bounded, request-scoped context assembled for exactly
// one Phase-1 request. Every field here already existed somewhere in the
// M1-M7 pipeline (RawIR, the Task record) — this type does not introduce
// any new data source, only a narrower, explicitly-scoped view of data
// that already flows through the system.
type Object struct {
	TaskID        string
	RequestID     string
	CorrelationID string
	IRID          string
	Actor         string
	SessionID     string
	CapabilityID  string
	Risk          ir.RiskLevel

	// Arguments starts as exactly the validated IR's own arguments (M2
	// already guarantees no undeclared key exists here) and is only ever
	// narrowed further by Firewall, never widened.
	Arguments       map[string]interface{}
	ArgumentsDigest string

	VerificationMethod         string
	ExpectedOutcomeDescription string
	ExpectedSuccessCondition   interface{}

	Cancellable        bool
	CancellationEffect string

	IdempotencyKey string
	SafeToRetry    bool
}

// Compile assembles the bounded context for one request from exactly its
// validated IR, actor, and session — no store handle, no other task's
// data, no arbitrary environment lookup is reachable from this function
// (FR-CONTEXT-001's "select context per-request... optimizing for...
// privacy," proven structurally: there is nothing broader available to
// leak from).
func Compile(validated ir.ValidatedIR, taskID, requestID string, argsDigest string) Object {
	raw := validated.Raw()
	args := make(map[string]interface{}, len(raw.Content.Parameters))
	for k, v := range raw.Content.Parameters {
		args[k] = v
	}
	return Object{
		TaskID: taskID, RequestID: requestID, CorrelationID: raw.CorrelationID, IRID: raw.IRID,
		Actor: raw.Source.Actor, SessionID: raw.Source.SessionID,
		CapabilityID: raw.Goal.Type, Risk: raw.Risk.Level,
		Arguments: args, ArgumentsDigest: argsDigest,
		VerificationMethod:         raw.Verification.Method,
		ExpectedOutcomeDescription: raw.ExpectedOutcome.Description,
		ExpectedSuccessCondition:   raw.ExpectedOutcome.SuccessCondition,
		Cancellable:                raw.Cancellation.Cancellable,
		CancellationEffect:         string(raw.Cancellation.CancellationEffect),
		IdempotencyKey:             raw.Idempotency.IdempotencyKey,
		SafeToRetry:                raw.Idempotency.SafeToRetry,
	}
}

// Firewall returns a COPY of obj with Arguments trimmed to exactly
// allowedArgKeys — any key not in that set is dropped, never added to,
// regardless of what Arguments contained going in. allowedArgKeys is the
// capability's own declared input schema key set (FR-CONTEXT-002: "a
// context field outside its declared data_access scope"), passed by the
// caller from the same capability registry M2/M3 already consult — this
// function has no capability-registry access of its own, so it cannot
// silently pick a more permissive scope than what the caller supplies.
func Firewall(obj Object, allowedArgKeys map[string]bool) Object {
	out := obj
	out.Arguments = make(map[string]interface{}, len(obj.Arguments))
	for k, v := range obj.Arguments {
		if allowedArgKeys[k] {
			out.Arguments[k] = v
		}
	}
	return out
}

// ExcludedKeys reports which Arguments keys Firewall would drop for a
// given allowed set, without mutating anything — used by tests (and
// available for audit-time disclosure) to prove exclusion happened,
// rather than merely asserting the positive case.
func ExcludedKeys(obj Object, allowedArgKeys map[string]bool) []string {
	var excluded []string
	for k := range obj.Arguments {
		if !allowedArgKeys[k] {
			excluded = append(excluded, k)
		}
	}
	sort.Strings(excluded)
	return excluded
}
