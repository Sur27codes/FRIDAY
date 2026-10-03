// Package contract defines the Capability Bus's authoritative capability
// contract (docs/QR-aiml-and-capability-architecture.md §R.1, extended
// with the AAL/purpose/data-classification fields
// PHASE-1-EXECUTION-SPEC.md §9 adds). This is intentionally a richer,
// separate type from services/ir's CapabilitySchema — ir's registry is a
// minimal validation-only view ("must never know about specific
// capability implementations beyond schema-level capability_id
// references"); this package's Contract is the real, authoritative
// source the Capability Bus dispatches against. The two are kept in sync
// by hand at the two call sites that register the same two Phase-1
// capabilities, the same disclosed tradeoff as the RiskLevel/AAL
// duplication across services/ir and services/policytoken.
package contract

import "time"

type RiskLevel string

const (
	RiskNone               RiskLevel = "none"
	RiskLow                RiskLevel = "low"
	RiskExternalSideEffect RiskLevel = "external_side_effect"
	RiskHigh               RiskLevel = "high"
	RiskCritical           RiskLevel = "critical"
)

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

type RetrySemantics string

const (
	Idempotent              RetrySemantics = "IDEMPOTENT"
	ConditionallyIdempotent RetrySemantics = "CONDITIONALLY_IDEMPOTENT"
	NonIdempotent           RetrySemantics = "NON_IDEMPOTENT"
)

// ArgSchema is a minimal per-argument schema — sufficient for Phase-1's
// two capabilities (string arguments with a max length only). Extending
// this to a full JSON Schema is explicitly out of scope for Phase 1
// (PHASE-1-SCOPE-LOCK.md); the Contract's InputSchema is deliberately not
// a generic "any JSON Schema" field.
type ArgSchema struct {
	Type      string
	MaxLength int
	Required  bool
}

// Contract is the full R.1 contract, as required by the M3 brief §3.
type Contract struct {
	CapabilityID string
	Version      string
	Description  string

	InputSchema map[string]ArgSchema
	// AllowAdditionalArgs, if false, means the Bus rejects any argument
	// not named in InputSchema — the mechanism behind rejecting
	// path-traversal-style extra arguments (M3 §15).
	AllowAdditionalArgs bool

	RequiredPermission string // policy scope description, human-readable
	RequiredPurpose    string // "" if not purpose-bound
	MinimumAAL         AAL

	RiskLevel   RiskLevel
	Reversible  bool
	DataRead    []string
	DataWritten []string

	Timeout        time.Duration
	RetrySemantics RetrySemantics

	VerificationMethod string
	DataClassification string // O.2: PUBLIC|INTERNAL|PERSONAL|CONFIDENTIAL|HIGHLY_SENSITIVE
}
