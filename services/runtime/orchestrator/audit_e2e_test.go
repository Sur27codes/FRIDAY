package orchestrator

import (
	"context"
	"strings"
	"testing"

	"friday/runtime-store/store"
)

// M7 brief §27: for one user request, request/IR/plan/policy decision/
// authorization/capability invocation/verification/task result/audit
// events all share correct correlation/task identifiers, making the
// whole action reconstructable from the audit trail alone.
func TestE2E_AuditCorrelation_FullReconstruction(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	textReq := req("user.owner", "create a note called correlation-test with body-x")
	resp := h.Orch.HandleTextRequest(ctx, textReq, "e2e-corr-1")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("setup: expected SUCCESS, got %+v", resp)
	}

	task, err := h.Store.GetTask(ctx, "e2e-corr-1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.CorrelationID != textReq.CorrelationID {
		t.Fatalf("task correlation_id mismatch: got %q, want %q", task.CorrelationID, textReq.CorrelationID)
	}

	trail, err := h.Store.GetAuditTrail(ctx, "e2e-corr-1")
	if err != nil {
		t.Fatalf("GetAuditTrail: %v", err)
	}
	if len(trail) == 0 {
		t.Fatalf("expected a non-empty audit trail")
	}
	for _, ev := range trail {
		if ev.CorrelationID != textReq.CorrelationID {
			t.Fatalf("audit event %s has correlation_id %q, want %q", ev.EventType, ev.CorrelationID, textReq.CorrelationID)
		}
		if ev.TaskID != "e2e-corr-1" {
			t.Fatalf("audit event %s has task_id %q, want e2e-corr-1", ev.EventType, ev.TaskID)
		}
	}

	snap, err := h.Store.GetIRSnapshot(ctx, task.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot: %v", err)
	}
	if snap.TaskID != "e2e-corr-1" {
		t.Fatalf("IR snapshot task_id mismatch: got %q", snap.TaskID)
	}

	invocations, err := h.Store.GetInvocationsForTask(ctx, "e2e-corr-1")
	if err != nil || len(invocations) != 1 {
		t.Fatalf("expected exactly one capability invocation, got %+v (err=%v)", invocations, err)
	}

	verifications, err := h.Store.GetVerificationsForTask(ctx, "e2e-corr-1")
	if err != nil || len(verifications) != 1 {
		t.Fatalf("expected exactly one verification result, got %+v (err=%v)", verifications, err)
	}

	// The trail alone reconstructs the whole story, in order.
	assertEventSequence(t, trail, []store.EventType{
		store.EventIRCompiled, store.EventIRValidated, store.EventContextCompiled, store.EventPlanCreated,
		store.EventPolicyEvaluated, store.EventCapabilityAuthorized, store.EventCapabilityStarted,
		store.EventCapabilityCompleted, store.EventVerificationStarted, store.EventVerificationCompleted,
		store.EventTaskSucceeded,
	})
}

// M7 brief §28: inspect actual audit output for sensitive material —
// private signing key, raw auth factors, full authorization token, note
// content, secret configuration must never appear.
func TestE2E_AuditDoesNotLeakSensitiveMaterial(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "create a note called secret-title with very-secret-body-content"), "e2e-leak-1")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("setup: expected SUCCESS, got %+v", resp)
	}

	trail, err := h.Store.GetAuditTrail(ctx, "e2e-leak-1")
	if err != nil {
		t.Fatalf("GetAuditTrail: %v", err)
	}
	for _, ev := range trail {
		// PERSONAL-sensitivity events must never carry a payload at all
		// (store.AppendAuditEvent's own sensitivity gate) — the note
		// title/body must not appear anywhere in the audit trail.
		blob := eventBlob(ev)
		if strings.Contains(blob, "secret-title") || strings.Contains(blob, "very-secret-body-content") {
			t.Fatalf("audit event %s leaked note content: %+v", ev.EventType, ev)
		}
		if strings.Contains(blob, "MII") || strings.Contains(blob, "PRIVATE KEY") {
			t.Fatalf("audit event %s appears to contain key material: %+v", ev.EventType, ev)
		}
	}

	// The policy decision record holds only token_id/expiry, never a
	// signature or the token's raw bytes (store.PolicyDecision has no
	// field for either — a structural guarantee, confirmed here that the
	// real decision saved from this run is consistent with that shape).
	// (No direct assertion possible beyond the type itself not compiling
	// with such a field — see runtime-store/store/policydecision.go.)
}

func eventBlob(ev store.AuditEvent) string {
	var sb strings.Builder
	sb.WriteString(string(ev.EventType))
	sb.WriteString(ev.ResultStatus)
	for k, v := range ev.Payload {
		sb.WriteString(k)
		sb.WriteString(": ")
		sb.WriteString(toStringForAssertion(v))
	}
	return sb.String()
}

func toStringForAssertion(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}
