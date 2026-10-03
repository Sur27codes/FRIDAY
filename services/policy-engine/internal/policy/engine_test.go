package policy

import (
	"testing"
	"time"
)

// Tests in this file translate docs/PHASE-1-POLICY-SECURITY-TEST-SPEC.md
// §2 (AAL-001..AAL-010) into executable Go tests, scoped to what M1's pure
// Engine.Evaluate can actually exercise without a Capability Bus, gRPC
// transport, or database. Where a case depends on infrastructure not yet
// built (M4+), that is stated in the test's own comment, not silently
// skipped without explanation — this mirrors the discipline the test spec
// itself uses for POL-009/POL-018's "Phase-1 applicability" notes.

func newTestEngine(t *testing.T) *Engine {
	t.Helper()
	signer, _, err := NewKeyPair()
	if err != nil {
		t.Fatalf("generating test key pair: %v", err)
	}
	return NewEngine(signer)
}

// AAL-001: voice_match alone can NEVER satisfy AAL2 or higher, swept
// across every risk level where that matters (external_side_effect ->
// AAL2, high -> AAL3, critical -> AAL4).
func TestAAL001_VoiceMatchAloneNeverSatisfiesAAL2Plus(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()

	risks := []RiskLevel{RiskExternalSideEffect, RiskHigh, RiskCritical}
	for _, risk := range risks {
		in := PolicyInput{
			Actor:      "user.owner",
			Capability: "workspace.create_note",
			IRID:       "ir-1",
			Risk:       risk,
			AssuranceFactors: []PresentedFactor{
				{Factor: FactorVoiceMatch, EstablishedAt: now, Available: true},
			},
			EvaluatedAt: now,
		}
		out := e.Evaluate(in)
		if out.Decision == Allow {
			t.Errorf("risk=%s: voice_match alone produced ALLOW; must never be sufficient (got token=%v)", risk, out.Token != nil)
		}
	}
}

// AAL-002: an AAL0 action succeeds without any assurance factor, and a
// token is still issued (AAL0 does not mean "no token" — ST §S.13).
func TestAAL002_AAL0SucceedsWithoutAssuranceFactor_TokenStillIssued(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()

	in := PolicyInput{
		Actor:            "user.owner",
		Capability:       "system.get_status",
		IRID:             "ir-2",
		Risk:             RiskNone,
		AssuranceFactors: nil, // empty — nothing presented
		EvaluatedAt:      now,
	}
	out := e.Evaluate(in)
	if out.Decision != Allow {
		t.Fatalf("expected ALLOW at AAL0 with no factors, got %s (reason: %s)", out.Decision, out.Reason)
	}
	if out.Token == nil {
		t.Fatal("AAL0 request must still receive a policy_token (ST §S.13: AAL0 does not mean no token)")
	}
	if out.RequiredAAL != AAL0 {
		t.Errorf("expected required_aal AAL0, got %s", out.RequiredAAL)
	}

	// Second half of AAL-002: an unrelated policy-denying condition must
	// still be able to produce DENY even at AAL0. M1 has not yet
	// implemented autonomy budgets / blast-radius (NFR-AUTONOMY-002,
	// NFR-SAFETY-003 — both Phase 4), so the only denial path available
	// in M1 is TaskCancelled. This still proves AAL0 is not an
	// unconditional bypass of policy generally.
	cancelledIn := in
	cancelledIn.TaskCancelled = true
	cancelledOut := e.Evaluate(cancelledIn)
	if cancelledOut.Decision == Allow {
		t.Error("AAL0 must not bypass other denial conditions (task-cancelled case still produced ALLOW)")
	}
}

// AAL-004: AAL2-satisfying factors do not satisfy an AAL3 requirement —
// levels are strictly ordered, not substitutable by "more of a lower one."
func TestAAL004_AAL2FactorsDoNotSatisfyAAL3Requirement(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()

	in := PolicyInput{
		Actor:      "user.owner",
		Capability: "some.high-risk.capability",
		IRID:       "ir-4",
		Risk:       RiskHigh, // requires AAL3
		AssuranceFactors: []PresentedFactor{
			{Factor: FactorDeviceTrustedSession, EstablishedAt: now, Available: true},
			{Factor: FactorActiveUserConfirm, EstablishedAt: now, Available: true},
			// missing: os_biometric or security_key
		},
		EvaluatedAt: now,
	}
	out := e.Evaluate(in)
	if out.Decision != StrongAuthRequired {
		t.Fatalf("expected STRONG_AUTH_REQUIRED (AAL2 factor set insufficient for AAL3), got %s", out.Decision)
	}
}

// AAL-005: voice_match + an untrusted (absent) device_trusted_session does
// not elevate assurance — voice cannot substitute for the base factor.
func TestAAL005_VoiceMatchWithUntrustedSessionDoesNotElevate(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()

	in := PolicyInput{
		Actor:      "user.owner",
		Capability: "workspace.create_note",
		IRID:       "ir-5",
		Risk:       RiskLow, // requires AAL1
		AssuranceFactors: []PresentedFactor{
			{Factor: FactorVoiceMatch, EstablishedAt: now, Available: true},
			// device_trusted_session explicitly absent
		},
		EvaluatedAt: now,
	}
	out := e.Evaluate(in)
	if out.Decision == Allow {
		t.Fatalf("voice_match without device_trusted_session must not satisfy even AAL1, got ALLOW")
	}
}

// AAL-006: an active_user_confirmation factor older than its freshness
// window is treated as absent, not as a valid-but-old factor.
func TestAAL006_StaleActiveUserConfirmationTreatedAsAbsent(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()
	stale := now.Add(-2 * activeUserConfirmWindow) // well outside the window

	in := PolicyInput{
		Actor:      "user.owner",
		Capability: "some.capability",
		IRID:       "ir-6",
		Risk:       RiskExternalSideEffect, // requires AAL2
		AssuranceFactors: []PresentedFactor{
			{Factor: FactorDeviceTrustedSession, EstablishedAt: now, Available: true},
			{Factor: FactorActiveUserConfirm, EstablishedAt: stale, Available: true},
		},
		EvaluatedAt: now,
	}
	out := e.Evaluate(in)
	if out.Decision != Confirm {
		t.Fatalf("expected CONFIRM (stale confirmation must be re-requested), got %s", out.Decision)
	}
}

// AAL-007 (partial — the IR-vs-capability cross-validation itself is a
// FR-IR-003/M2 concern): confirms requiredAAL is computed solely from the
// Risk field the caller supplies, with no separate "self-reported" input
// that could diverge from it inside this package.
func TestAAL007_RequiredAALDerivesOnlyFromSuppliedRiskField(t *testing.T) {
	if requiredAAL(RiskHigh) != AAL3 {
		t.Fatalf("requiredAAL(high) = %s, want AAL3", requiredAAL(RiskHigh))
	}
	// There is no second "IR-claimed risk" parameter to requiredAAL at
	// all — the function signature itself is the proof that no such input
	// exists for the Engine to be tricked by. The upstream guarantee that
	// the capability's registered risk_level (not an LLM's claim) is what
	// gets passed in here is enforced at IR validation stage 4 (M2), not
	// in this package.
}

// AAL-008 is an architectural/static-review check ("is AAL logic ever
// duplicated inside the Cognitive Core process"), not a runtime assertion
// this package can make about itself. Recorded here as a doc anchor so it
// isn't silently dropped from the test suite's index; the actual
// verification is: no code in services/cognitive-core (which does not
// exist until M5) may import this package's unexported decision logic,
// and this package exposes no decision-making function usable without a
// full Engine — reviewed at M5's Definition of Done, not here.
func TestAAL008_DocumentedArchitecturalCheck(t *testing.T) {
	t.Log("AAL-008 is verified by code review at M5 (no Cognitive Core import of policy internals), not a unit test in this package")
}

// AAL-009: an unavailable assurance-factor provider (e.g. failed
// biometric read) is treated as absent, never as satisfied-by-default.
func TestAAL009_UnavailableProviderFailsClosed(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()

	in := PolicyInput{
		Actor:      "user.owner",
		Capability: "some.critical.capability",
		IRID:       "ir-9",
		Risk:       RiskCritical, // requires AAL4
		AssuranceFactors: []PresentedFactor{
			{Factor: FactorDeviceTrustedSession, EstablishedAt: now, Available: true},
			{Factor: FactorActiveUserConfirm, EstablishedAt: now, Available: true},
			{Factor: FactorOSBiometric, EstablishedAt: now, Available: false}, // provider failed
		},
		EvaluatedAt: now,
	}
	out := e.Evaluate(in)
	if out.Decision == Allow {
		t.Fatal("an unavailable os_biometric provider must not be treated as satisfied — got ALLOW")
	}
	if out.Decision != StrongAuthRequired {
		t.Errorf("expected STRONG_AUTH_REQUIRED (AAL4 unmet), got %s", out.Decision)
	}
}

// Sanity check that Evaluate() is deterministic given identical input
// (required for it to be usable as a plain input-matrix fixture, L §L.5.3).
func TestEvaluate_Deterministic(t *testing.T) {
	e := newTestEngine(t)
	now := time.Now()
	in := PolicyInput{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-det",
		Risk: RiskNone, EvaluatedAt: now,
	}
	a := e.Evaluate(in)
	b := e.Evaluate(in)
	if a.Decision != b.Decision || a.RequiredAAL != b.RequiredAAL {
		t.Fatalf("Evaluate is not deterministic for identical input: %+v vs %+v", a, b)
	}
}
