// P2-M4R: reproduces, at the real end-to-end orchestrator level (real
// policyengined/capabilitybusd subprocesses via newHarness, exactly like
// e2e_test.go), the actual production bug a real owner voice interaction
// surfaced — see docs/E-traceability-matrix.md's P2-M4R section for the
// full narrative and root-cause evidence.
//
// The real production client (macos/FridayCompanion's WakeCoordinator,
// via RuntimeClient) submitted every voice command with an EMPTY
// CorrelationID. For a zero-argument capability like "check system
// status", the Intent Compiler's IdempotencyKey
// (correlation_id + ":" + capability_id + ":" + arguments_digest)
// therefore collapsed to the SAME constant string on every call,
// independent of the fresh, unique RequestID each call actually had.
// orchestrator.HandleTextRequest's CreateTask call requires a non-empty
// CorrelationID (store.Task's own validation) and failed every time,
// returning INTERNAL_ERROR — but the failure branch did not call
// store.CompleteIdempotency (unlike every sibling failure branch),
// permanently orphaning the just-registered PENDING idempotency record.
// Every subsequent call for the same key — ANY new RequestID, forever —
// then read that still-PENDING record and was misclassified as
// DUPLICATE_REQUEST, with no way to recover short of manual database
// surgery.
package orchestrator

import (
	"context"
	"testing"
	"time"

	"friday/cognitive-core/textrequest"
)

func reqWithCorrelation(actor, text, requestID, correlationID string) textrequest.TextRequest {
	return textrequest.TextRequest{
		RequestID: requestID, CorrelationID: correlationID, Actor: actor,
		SessionID: "sess-1", RawText: text, ReceivedAt: time.Now().UTC(), Source: textrequest.SourceText,
	}
}

// A: a single, well-formed request executes normally (baseline, already
// covered by e2e_test.go — restated here only as the first step of the
// exact real scenario below, not new coverage on its own).

// B: a genuine retry (same RequestID, same CorrelationID) of an
// ALREADY-SUCCEEDED request is recognized as a duplicate of that
// specific completed task — the existing, correct idempotent-retry
// contract — not a new execution and not a permanent lock.
func TestP2M4R_SameRequestIDSameCorrelationID_RetryOfSucceeded_IsRecognizedDuplicate(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	first := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-b1", "corr-b1"), "task-b1")
	if first.Outcome != "SUCCESS" {
		t.Fatalf("expected first submission to succeed, got %+v", first)
	}

	retry := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-b1", "corr-b1"), "task-b1-retry")
	if retry.Outcome != "DUPLICATE_REQUEST" {
		t.Fatalf("expected a genuine retry of the same request to be recognized as DUPLICATE_REQUEST, got %+v", retry)
	}
	if retry.TaskID != first.TaskID {
		t.Fatalf("a real retry must resolve to the ORIGINAL task, got %q want %q", retry.TaskID, first.TaskID)
	}
}

// C: the actual real-world fix target — two SEPARATE user interactions
// (fresh RequestID AND fresh CorrelationID each, exactly what
// WakeCoordinator now sends after the P2-M4R Swift fix) saying the exact
// same text must BOTH succeed as independent executions, never collide.
func TestP2M4R_SameTextDifferentCorrelationIDs_BothSucceedAsDistinctInteractions(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	first := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-c1", "corr-c1"), "task-c1")
	if first.Outcome != "SUCCESS" {
		t.Fatalf("expected first interaction to succeed, got %+v", first)
	}

	second := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-c2", "corr-c2"), "task-c2")
	if second.Outcome != "SUCCESS" {
		t.Fatalf("a second, independent real-world interaction with identical text must ALSO succeed, not be misclassified as a duplicate — got %+v", second)
	}
	if second.TaskID == first.TaskID {
		t.Fatalf("the two interactions must produce distinct tasks, got the same TaskID %q for both", second.TaskID)
	}
}

// D: the exact real bug — an invalid request (empty CorrelationID, the
// actual pre-fix production client behavior) fails with INTERNAL_ERROR,
// and — this is the P2-M4R regression proper — that failure must NOT
// permanently lock out the capability+arguments combination. A
// SUBSEQUENT, well-formed request (proper non-empty CorrelationID) for
// the exact same text must still succeed normally, not be rejected
// merely because an earlier, differently-broken request touched the
// same idempotency key space.
func TestP2M4R_FailedRequestWithEmptyCorrelationID_DoesNotBlockLaterWellFormedRequest(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// The exact real trigger: empty CorrelationID (pre-fix
	// WakeCoordinator/RuntimeClient default) fails CreateTask's
	// required-field validation.
	broken := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-d1", ""), "task-d1")
	if broken.Outcome != "INTERNAL_ERROR" {
		t.Fatalf("expected the malformed (empty CorrelationID) request to fail with INTERNAL_ERROR, got %+v", broken)
	}

	// A second malformed request (still empty CorrelationID, a different
	// RequestID) must fail the SAME truthful way — INTERNAL_ERROR again —
	// never DUPLICATE_REQUEST. With the fix, the first failure's
	// CompleteIdempotency call leaves the record COMPLETED (not
	// permanently PENDING); this second call's RegisterIdempotency then
	// finds that COMPLETED record (created=false) and
	// respondForExistingIdempotentTask tries GetTask(rec.TaskID) — but
	// "task-d1" was never actually created (CreateTask failed for it
	// too), so that lookup fails and correctly surfaces as
	// INTERNAL_ERROR again, truthfully, rather than a fabricated
	// DUPLICATE_REQUEST. Before the P2-M4R fix, the record was left
	// PENDING forever, and every subsequent call — including this one —
	// hit the PENDING branch and returned DUPLICATE_REQUEST instead.
	brokenAgain := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-d2", ""), "task-d2")
	if brokenAgain.Outcome != "INTERNAL_ERROR" {
		t.Fatalf("P2-M4R regression: a second malformed request must fail the same truthful way (INTERNAL_ERROR), not be misclassified as DUPLICATE_REQUEST — got %+v", brokenAgain)
	}

	// The real fix target: a WELL-FORMED request for the exact same text
	// (proper non-empty CorrelationID) must succeed normally afterward —
	// the earlier failures must not have permanently wedged this
	// capability+arguments combination.
	fixed := h.Orch.HandleTextRequest(ctx, reqWithCorrelation("user.owner", "check system status", "req-d3", "corr-d3"), "task-d3")
	if fixed.Outcome != "SUCCESS" {
		t.Fatalf("P2-M4R regression: a well-formed request must succeed even after earlier malformed requests touched the same idempotency key space — got %+v", fixed)
	}
}
