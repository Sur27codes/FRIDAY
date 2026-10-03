// Package policy implements the Phase-1 Policy Engine decision logic.
//
// This package is intentionally pure: it performs no network I/O, no disk
// I/O, and holds no process state beyond what is passed into it or held in
// an explicit Engine struct. This is deliberate (PHASE-1-IMPLEMENTATION-PLAN.md
// M1): the safety-critical decision logic is unit-tested in isolation before
// any process boundary (ADR-021), IPC transport, or database is introduced.
//
// Schema below matches docs/ST-security-and-privacy-architecture.md §S.2,
// §S.2.1, §S.13 and docs/L-world-user-self-policy-models.md §L.5.1 exactly.
// Any divergence between this file and those documents is a bug in one of
// the two, not a judgment call to be made in code.
package policy

import (
	"time"

	"friday/policytoken"
)

// RiskLevel mirrors FRIDAY IR's risk.level field (JK §J.2).
type RiskLevel string

const (
	RiskNone               RiskLevel = "none"
	RiskLow                RiskLevel = "low"
	RiskExternalSideEffect RiskLevel = "external_side_effect"
	RiskHigh               RiskLevel = "high"
	RiskCritical           RiskLevel = "critical"
)

// Reversibility mirrors FRIDAY IR's effects.reversible-derived classification.
type Reversibility string

const (
	Reversible   Reversibility = "reversible"
	Compensable  Reversibility = "compensable"
	Irreversible Reversibility = "irreversible"
)

// Decision is the Policy Engine's output verdict (ST §S.2).
type Decision string

const (
	Allow              Decision = "ALLOW"
	Deny               Decision = "DENY"
	Confirm            Decision = "CONFIRM"
	StrongAuthRequired Decision = "STRONG_AUTH_REQUIRED"
)

// AAL is an Authentication Assurance Level (ST §S.13).
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

// AssuranceFactor is a discrete, independently-obtainable authentication
// signal (ST §S.13). These are never blended into a single score.
type AssuranceFactor string

const (
	FactorDeviceTrustedSession AssuranceFactor = "device_trusted_session"
	FactorActiveUserConfirm    AssuranceFactor = "active_user_confirmation"
	FactorOSBiometric          AssuranceFactor = "os_biometric"
	FactorSecurityKey          AssuranceFactor = "security_key"
	FactorVoiceMatch           AssuranceFactor = "voice_match"
)

// PresentedFactor is an assurance factor as actually observed for this
// request, carrying its own establishment time so freshness (ST §S.13,
// closure-pass addition) can be checked per-factor, not per-session.
type PresentedFactor struct {
	Factor        AssuranceFactor
	EstablishedAt time.Time
	// Available is false when the underlying provider (e.g. OS biometric
	// hardware) was queried and failed/was unavailable. A false or absent
	// PresentedFactor is always treated as the factor being absent — never
	// as present-by-default (ST §S.13's fail-closed rule). This field
	// exists to distinguish "we checked and it failed" from "we never
	// asked" for audit purposes; both resolve to "not satisfied" in the
	// AAL check either way.
	Available bool
}

// PolicyInput is the Evaluate() request schema (ST §S.2, L §L.5.1).
type PolicyInput struct {
	Actor         string
	Device        string
	Capability    string // capability_id
	IRID          string
	Action        string
	Risk          RiskLevel
	Reversibility Reversibility
	Sensitivity   string // data classification, O.2

	AssuranceFactors []PresentedFactor

	Environment             string // context mode (§275) — unused in Phase 1, present for schema completeness
	AutonomyLevelConfigured int    // L0..L4, only L0/L1 meaningful in Phase 1
	SimulatorVerified       bool   // ST §S.14 — false is correct default until Simulator exists (Phase 4)
	Jurisdiction            string // unused in Phase 1

	// EvaluatedAt is the time this decision is being made, injected rather
	// than read from time.Now() so tests are deterministic (this is why
	// PresentedFactor.EstablishedAt is compared against this field, not
	// against wall-clock time, throughout this package).
	EvaluatedAt time.Time

	// ArgumentsDigest is the digest of the canonical arguments this
	// request concerns (ST §S.2.1's closure-pass addition, POL-017). The
	// Policy Engine does not compute this itself in M1 — it is supplied
	// by the caller (which, at M4+, is the Capability Bus re-deriving it
	// from the immutable IR store) and is carried through into the issued
	// token unchanged, so the Capability Bus can compare it again at
	// invocation time (defense in depth, not duplicated trust).
	ArgumentsDigest string

	// Purpose is the Consent Ledger purpose this request is bound to, or
	// "" (treated as "none") if the capability is not purpose-bound.
	// Neither Phase-1 capability is purpose-bound (PHASE-1-EXECUTION-SPEC.md
	// §9), so this is always "" in M1 — present for schema completeness
	// and for POL-009's mechanism-level test.
	Purpose string

	// TaskCancelled, if true, means the owning task has already reached a
	// CANCELLED (or other non-executable terminal) state (JK §K.8). A
	// precondition check some callers set directly; Evaluate() also
	// re-derives this via TaskStateChecker at token *validation* time
	// (that check lives in the token package, not here — see POL-012/013).
	TaskCancelled bool
}

// PolicyOutput is the Evaluate() response schema (ST §S.2).
type PolicyOutput struct {
	Decision    Decision
	RequiredAAL AAL
	Reason      string
	Token       *policytoken.PolicyToken // non-nil only if Decision == Allow
}
