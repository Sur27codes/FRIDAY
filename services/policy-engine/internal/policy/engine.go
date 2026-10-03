package policy

import (
	"fmt"

	"friday/policytoken"
)

// Engine is the Phase-1 Policy Engine's decision core. It holds the
// Ed25519 Signer (ADR-021: only the Policy Engine process ever constructs
// one), and nothing else — no database handle, no network client. At M1
// there is no gRPC wrapper yet (that is M4's server package); Evaluate is
// called directly, in-process, by tests.
type Engine struct {
	signer Signer
}

// NewEngine constructs an Engine from a freshly (or persistently, at M4+)
// generated Signer.
func NewEngine(s Signer) *Engine {
	return &Engine{signer: s}
}

// Verifier exposes the public half of this Engine's key pair, for
// components that only need to validate tokens (e.g., the Capability Bus
// at M4) — never the private key itself.
func (e *Engine) Verifier() policytoken.Verifier {
	return e.signer.Public()
}

// Evaluate is the single decision entrypoint (ST §S.2: "Evaluate(policy_input)
// -> policy_output"). It is deterministic: identical input (including
// EvaluatedAt) always produces an identical decision, which is what makes
// this testable as a plain input-matrix fixture (L §L.5.3, Y.3).
func (e *Engine) Evaluate(in PolicyInput) PolicyOutput {
	required := requiredAAL(in.Risk)

	// ST §S.14 / NFR-AUTONOMY-003: L3+ autonomy requires a Simulator
	// verification on file. Phase-1 capabilities are configured at L0/L1
	// (PHASE-1-SCOPE-LOCK.md), so this branch is not exercised by the
	// Phase-1 capability set today, but the rule is implemented and
	// tested now so it is never retrofitted under pressure later.
	if in.AutonomyLevelConfigured >= 3 && !in.SimulatorVerified {
		return PolicyOutput{
			Decision:    Confirm,
			RequiredAAL: required,
			Reason:      "L3+ autonomy requires a Simulator verification on file; none found",
		}
	}

	// JK §K.8 / ST §S.2.1 check 6f, evaluated here as a precondition too
	// (Evaluate() itself should not issue a token for an already-cancelled
	// task, even before the Capability Bus's own re-check at invocation
	// time — defense in depth, not duplicated trust; see PHASE-1-EXECUTION-SPEC.md
	// §1.2's note that checks 5-7 are independently re-verified downstream).
	if in.TaskCancelled {
		return PolicyOutput{
			Decision:    Deny,
			RequiredAAL: required,
			Reason:      "owning task is already cancelled",
		}
	}

	if !satisfiesAAL(required, in.AssuranceFactors, in.EvaluatedAt) {
		return PolicyOutput{
			Decision:    decisionForUnsatisfiedAAL(required),
			RequiredAAL: required,
			Reason:      fmt.Sprintf("required %s not satisfied by presented assurance factors", required),
		}
	}

	token, err := e.signer.Issue(in, in.EvaluatedAt)
	if err != nil {
		// Fail closed: a token-issuance failure is a DENY, never a
		// silent ALLOW-without-token (which the Capability Bus's
		// mandatory-token contract would reject anyway, but Evaluate()
		// should not even claim ALLOW here).
		return PolicyOutput{
			Decision:    Deny,
			RequiredAAL: required,
			Reason:      "token issuance failed: " + err.Error(),
		}
	}

	return PolicyOutput{
		Decision:    Allow,
		RequiredAAL: required,
		Reason:      "required assurance satisfied",
		Token:       token,
	}
}

// decisionForUnsatisfiedAAL maps an unmet assurance requirement to the
// decision that tells the caller what's needed (ST §S.13's risk->AAL
// table, read in reverse). AAL-005 permits either CONFIRM or DENY for an
// unsatisfied AAL1 case ("not ALLOW" is the hard requirement); this
// implementation chooses DENY for AAL0/AAL1 shortfalls (an untrusted
// session is not something re-prompting fixes on its own) and reserves
// CONFIRM/STRONG_AUTH_REQUIRED for the cases where presenting an
// additional factor is the actual remedy.
func decisionForUnsatisfiedAAL(required AAL) Decision {
	switch required {
	case AAL0, AAL1:
		return Deny
	case AAL2:
		return Confirm
	case AAL3, AAL4:
		return StrongAuthRequired
	default:
		return Deny
	}
}
