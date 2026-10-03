// Package ir implements the Phase-1 FRIDAY IR schema and its deterministic
// 4-stage validator (docs/JK-friday-ir-and-runtime-architecture.md §J.2,
// §J.2.1). This package is pure: no network I/O, no disk I/O, no calls
// into the policy-engine module. It defines the trust boundary between
// untrusted, LLM/Intent-Compiler-produced IR and validated IR that may be
// handed to a Planner (M5+).
//
// RawIR and ValidatedIR are deliberately distinct Go types (not a single
// mutable struct with a "validated" bool field) so that a function
// signature accepting ValidatedIR makes it a compile error to pass
// unvalidated model output downstream — see PHASE-1-IMPLEMENTATION-PLAN.md
// M2 and PHASE-1-EXECUTION-SPEC.md §1.1's "FRIDAY IR != EXECUTION
// AUTHORITY" statement, which this package's type system makes literal:
// a RawIR cannot even be mistaken for a ValidatedIR by the compiler.
package ir

import "time"

const SupportedSchemaVersion = "0.2"

type RiskLevel string

const (
	RiskNone               RiskLevel = "none"
	RiskLow                RiskLevel = "low"
	RiskExternalSideEffect RiskLevel = "external_side_effect"
	RiskHigh               RiskLevel = "high"
	RiskCritical           RiskLevel = "critical"
)

func (r RiskLevel) valid() bool {
	switch r {
	case RiskNone, RiskLow, RiskExternalSideEffect, RiskHigh, RiskCritical:
		return true
	}
	return false
}

// AAL is duplicated here, deliberately, from services/policy-engine's
// equivalent type — NOT imported from that module. This keeps the `ir`
// module fully independent per PHASE-1-IMPLEMENTATION-PLAN.md §4's module
// boundary ("ir ... Must never do: Make policy decisions"), at the cost of
// two small parallel definitions of the same ST §S.13 table that must be
// kept in sync by hand. This tradeoff is disclosed, not hidden — see the
// M2 status report for why it was chosen over introducing a cross-module
// dependency the approved implementation plan's dependency graph does not
// show.
type AAL int

const (
	AAL0 AAL = iota
	AAL1
	AAL2
	AAL3
	AAL4
)

func (a AAL) String() string {
	return [...]string{"AAL0", "AAL1", "AAL2", "AAL3", "AAL4"}[a]
}

// requiredAALForRisk mirrors ST §S.13's risk -> required-AAL table.
func requiredAALForRisk(r RiskLevel) AAL {
	switch r {
	case RiskNone:
		return AAL0
	case RiskLow:
		return AAL1
	case RiskExternalSideEffect:
		return AAL2
	case RiskHigh:
		return AAL3
	case RiskCritical:
		return AAL4
	default:
		return AAL4 // fail closed on an unrecognized value, never AAL0
	}
}

type CancellationEffect string

const (
	CancellationNoneYetStarted       CancellationEffect = "none_yet_started"
	CancellationCompensate           CancellationEffect = "compensate"
	CancellationRequiresManualReview CancellationEffect = "requires_manual_review"
)

func (c CancellationEffect) valid() bool {
	switch c {
	case CancellationNoneYetStarted, CancellationCompensate, CancellationRequiresManualReview:
		return true
	}
	return false
}

// Source mirrors J.2's `source` block.
type Source struct {
	Actor         string `json:"actor"`
	Device        string `json:"device"`
	SessionID     string `json:"session_id"`
	InputModality string `json:"input_modality"`
}

// Goal mirrors J.2's `goal` block. Type names a capability_id, per J.2.1
// stage 2 ("goal.type names a capability_id registered on the Capability
// Bus").
type Goal struct {
	Type        string `json:"type"`
	Description string `json:"description"`
}

// Entity mirrors one element of J.2's `entities` array.
type Entity struct {
	Ref              string  `json:"ref"`
	ResolutionMethod string  `json:"resolution_method"`
	Confidence       float64 `json:"confidence"`
}

// Content mirrors J.2's `content` block.
type Content struct {
	Intent     string                 `json:"intent"`
	Parameters map[string]interface{} `json:"parameters"`
}

// Constraint mirrors one element of J.2's `constraints` array.
type Constraint struct {
	Type  string      `json:"type"`
	Value interface{} `json:"value"`
}

// Effects mirrors J.2's `effects` block.
type Effects struct {
	ExternalCommunication bool     `json:"external_communication"`
	DataWritten           []string `json:"data_written"`
	DataRead              []string `json:"data_read"`
	DeviceStateChange     bool     `json:"device_state_change"`
	Financial             bool     `json:"financial"`
	Reversible            bool     `json:"reversible"`
}

func (e Effects) hasSideEffect() bool {
	return e.ExternalCommunication || e.DeviceStateChange || e.Financial || len(e.DataWritten) > 0
}

// Risk mirrors J.2's `risk` block.
type Risk struct {
	Level               RiskLevel   `json:"level"`
	BlastRadiusEstimate interface{} `json:"blast_radius_estimate"`
}

// ExpectedOutcome mirrors J.2's `expected_outcome` block (v0.2).
type ExpectedOutcome struct {
	Description      string      `json:"description"`
	SuccessCondition interface{} `json:"success_condition"`
}

func (e ExpectedOutcome) present() bool {
	return e.Description != "" && e.SuccessCondition != nil
}

// Cancellation mirrors J.2's `cancellation` block (v0.2).
type Cancellation struct {
	Cancellable        bool               `json:"cancellable"`
	CancellationEffect CancellationEffect `json:"cancellation_effect"`
}

// Idempotency mirrors J.2's `idempotency` block (v0.2).
type Idempotency struct {
	IdempotencyKey string `json:"idempotency_key"`
	SafeToRetry    bool   `json:"safe_to_retry"`
}

// Verification mirrors J.2's `verification` block.
type Verification struct {
	Required bool   `json:"required"`
	Method   string `json:"method"`
}

// KnowledgeStateEntry mirrors one element of J.2's `knowledge_state` array.
type KnowledgeStateEntry struct {
	Fact       string  `json:"fact"`
	State      string  `json:"state"`
	Confidence float64 `json:"confidence"`
}

// Provenance mirrors J.2's `provenance` block.
type Provenance struct {
	CompiledBy string `json:"compiled_by"`
	ModelUsed  string `json:"model_used"`
}

// RawIR is the untrusted document shape as received from the Intent
// Compiler (or, in tests, a hand-constructed fixture). Every field is a
// plain Go zero-valuable type deliberately: an absent JSON field simply
// unmarshals to that type's zero value (empty string, false, nil slice),
// which the validator must then explicitly reject where the field is
// required — there is no field in this struct that silently defaults to
// a permissive value that a reader could mistake for "validated as
// intentionally minimal" (IR-018's fail-closed requirement).
type RawIR struct {
	IRVersion       string                `json:"ir_version"`
	IRID            string                `json:"ir_id"`
	CorrelationID   string                `json:"correlation_id"`
	CausationID     string                `json:"causation_id"`
	CreatedAt       time.Time             `json:"created_at"`
	Source          Source                `json:"source"`
	Goal            Goal                  `json:"goal"`
	Entities        []Entity              `json:"entities"`
	Content         Content               `json:"content"`
	Constraints     []Constraint          `json:"constraints"`
	Effects         Effects               `json:"effects"`
	Risk            Risk                  `json:"risk"`
	ExpectedOutcome ExpectedOutcome       `json:"expected_outcome"`
	Cancellation    Cancellation          `json:"cancellation"`
	Idempotency     Idempotency           `json:"idempotency"`
	Dependencies    []string              `json:"dependencies"`
	Verification    Verification          `json:"verification"`
	KnowledgeState  []KnowledgeStateEntry `json:"knowledge_state"`
	Provenance      Provenance            `json:"provenance"`

	// UnknownFields is populated only when decoding from a generic
	// map[string]interface{} representation (see DecodeStrict in
	// canonical.go) and is used solely by stage-1 validation to detect
	// unexpected top-level keys (e.g. a smuggled "policy_token" or
	// "authorization" field) — see the security-invariant note in
	// validate.go. It is never part of the JSON schema itself.
	UnknownFields []string `json:"-"`
}

// ValidatedIR is the trusted result of a successful 4-stage Validate()
// call. Its only field is unexported, so the only way to construct one is
// through this package's Validate function — there is no public literal
// syntax that lets a caller build a ValidatedIR{} directly and skip
// validation, which is the concrete mechanism behind IR-022 ("validation
// cannot mark an IR executable by itself" — and, symmetrically, nothing
// *other than* validation can mark one valid either).
type ValidatedIR struct {
	raw RawIR
}

// Raw returns a copy of the underlying validated data for read-only
// downstream use (e.g., the Planner constructing a Task DAG, M5). It
// deliberately returns a value copy, not a pointer, so downstream code
// cannot mutate the validated document in place and have that mutation
// silently treated as still-validated.
func (v ValidatedIR) Raw() RawIR {
	return v.raw
}
