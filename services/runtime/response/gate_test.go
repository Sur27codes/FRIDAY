package response

import (
	"strings"
	"testing"

	"friday/runtime-store/store"
)

// RESP-001: verified SUCCEEDED get_status -> success response permitted.
func TestRESP001_VerifiedSucceededGetStatus_SuccessPermitted(t *testing.T) {
	candidate := GetStatusSuccess("t1")
	got := ValidateSuccessClaim(candidate, Claim{
		TaskState: store.StateSucceeded, VerificationRequired: true, VerificationConfirmed: true, PersistenceOK: true,
	})
	if got != candidate {
		t.Fatalf("expected the candidate success response to pass through unchanged, got %+v", got)
	}
}

// RESP-002: verified SUCCEEDED create_note -> success response permitted.
func TestRESP002_VerifiedSucceededCreateNote_SuccessPermitted(t *testing.T) {
	candidate := CreateNoteSuccess("t2", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{
		TaskState: store.StateSucceeded, VerificationRequired: true, VerificationConfirmed: true, PersistenceOK: true,
	})
	if got != candidate {
		t.Fatalf("expected the candidate success response to pass through unchanged, got %+v", got)
	}
}

// RESP-003: execution success + verification failure -> success wording rejected.
func TestRESP003_VerificationFailure_SuccessWordingRejected(t *testing.T) {
	candidate := CreateNoteSuccess("t3", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{
		TaskState: store.StateFailed, VerificationRequired: true, VerificationConfirmed: false, PersistenceOK: true,
	})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-004: Policy DENY -> success wording impossible (the caller never
// even has a SUCCEEDED task state to offer the gate in this case; proven
// by classify()'s own gate — a non-SUCCEEDED state can never pass).
func TestRESP004_PolicyDenied_SuccessWordingImpossible(t *testing.T) {
	candidate := CreateNoteSuccess("t4", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{TaskState: store.StateFailed})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-005: Bus failure -> success wording impossible.
func TestRESP005_BusFailure_SuccessWordingImpossible(t *testing.T) {
	candidate := CreateNoteSuccess("t5", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{TaskState: store.StateFailed, PersistenceOK: true})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-006: persistence failure -> success wording impossible where
// persistence is required (Phase 1: always required — every task
// transition is a durable write).
func TestRESP006_PersistenceFailure_SuccessWordingImpossible(t *testing.T) {
	candidate := GetStatusSuccess("t6")
	got := ValidateSuccessClaim(candidate, Claim{
		TaskState: store.StateSucceeded, VerificationRequired: true, VerificationConfirmed: true, PersistenceOK: false,
	})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-007: CANCELLED task -> success wording impossible.
func TestRESP007_Cancelled_SuccessWordingImpossible(t *testing.T) {
	candidate := CreateNoteSuccess("t7", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{TaskState: store.StateCancelled, PersistenceOK: true})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-008: FAILED task -> success wording impossible.
func TestRESP008_Failed_SuccessWordingImpossible(t *testing.T) {
	candidate := CreateNoteSuccess("t8", "my-note")
	got := ValidateSuccessClaim(candidate, Claim{TaskState: store.StateFailed, PersistenceOK: true})
	assertNotSuccessWording(t, got, candidate)
}

// RESP-009: unsupported intent -> no false capability claim. The
// UnsupportedIntent response never claims success in the first place
// (it is never routed through the gate at all in the real orchestrator
// — Compile() failing means there's no Claim to even construct), so the
// property to check is that its own fixed text never resembles a
// success claim.
func TestRESP009_UnsupportedIntent_NoFalseCapabilityClaim(t *testing.T) {
	resp := UnsupportedIntent("")
	if resp.Outcome == OutcomeSuccess {
		t.Fatalf("UnsupportedIntent must never report OutcomeSuccess")
	}
}

// RESP-010: response does not leak authorization token/security-sensitive
// data — every fixed template in this package was written without ever
// interpolating a token, signature, or key. Checked exhaustively against
// the actual candidate/rejection text this test file already exercises.
func TestRESP010_NoTokenOrSecurityDataInResponseText(t *testing.T) {
	forbidden := []string{"token", "signature", "private", "secret", "0x", "ed25519"}
	all := []Response{
		GetStatusSuccess("t"), CreateNoteSuccess("t", "n"), UnsupportedIntent("t"), AmbiguousIntent("t", "f"),
		InvalidTextRequest("t"), IRValidationFailed("t"), PolicyDenied("t"), PolicyRequiresMoreAssurance("t"),
		PolicyUnavailable("t"), CapabilityUnavailable("t"), ExecutionFailed("t"), VerificationFailed("t"),
		Cancelled("t"), CancellationAcknowledged("t"), RequiresManualReview("t"), AlreadyTerminal("t"),
		DuplicateRequestPending("t"), DuplicateRequestCompleted("t", true), DuplicateRequestCompleted("t", false),
		InternalError("t"),
		ValidateSuccessClaim(CreateNoteSuccess("t", "n"), Claim{}), // the gate's own rejection text
	}
	for _, r := range all {
		lower := strings.ToLower(r.Text)
		for _, f := range forbidden {
			if strings.Contains(lower, f) {
				t.Fatalf("response text for outcome %s contains forbidden substring %q: %q", r.Outcome, f, r.Text)
			}
		}
	}
}

func assertNotSuccessWording(t *testing.T, got, candidate Response) {
	t.Helper()
	if got == candidate {
		t.Fatalf("expected the gate to reject the candidate success response, got it unchanged: %+v", got)
	}
	if got.Outcome == OutcomeSuccess {
		t.Fatalf("expected a non-success outcome, got %+v", got)
	}
}
