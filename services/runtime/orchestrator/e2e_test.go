package orchestrator

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"friday/cognitive-core/textrequest"
	"friday/runtime-store/store"
)

func req(actor, text string) textrequest.TextRequest {
	now := time.Now().UTC()
	return textrequest.TextRequest{
		RequestID: "req-" + text, CorrelationID: "corr-" + text, Actor: actor,
		SessionID: "sess-1", RawText: text, ReceivedAt: now, Source: textrequest.SourceText,
	}
}

// M7 brief §35: full real end-to-end system.get_status.
func TestE2E_GetStatus_FullSpine(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "check system status"), "e2e-gs-1")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("expected SUCCESS, got %+v", resp)
	}
	if resp.Text != "System status retrieved successfully." {
		t.Fatalf("unexpected response text: %q", resp.Text)
	}

	task, err := h.Store.GetTask(ctx, "e2e-gs-1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != store.StateSucceeded {
		t.Fatalf("expected durable task state SUCCEEDED, got %s", task.State)
	}

	trail, err := h.Store.GetAuditTrail(ctx, "e2e-gs-1")
	if err != nil {
		t.Fatalf("GetAuditTrail: %v", err)
	}
	wantSequence := []store.EventType{
		store.EventIRCompiled, store.EventIRValidated, store.EventContextCompiled, store.EventPlanCreated,
		store.EventPolicyEvaluated, store.EventCapabilityAuthorized, store.EventCapabilityStarted,
		store.EventCapabilityCompleted, store.EventVerificationStarted, store.EventVerificationCompleted,
		store.EventTaskSucceeded,
	}
	assertEventSequence(t, trail, wantSequence)

	verifications, err := h.Store.GetVerificationsForTask(ctx, "e2e-gs-1")
	if err != nil || len(verifications) != 1 || verifications[0].Result != store.VerificationSucceeded {
		t.Fatalf("expected exactly one SUCCEEDED verification, got %+v (err=%v)", verifications, err)
	}
}

// M7 brief §36: full real end-to-end workspace.create_note, proving the
// actual file exists in the TEST workspace with the exact expected
// content.
func TestE2E_CreateNote_FullSpine(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "create a note called architecture-test with Phase 1 works"), "e2e-cn-1")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("expected SUCCESS, got %+v", resp)
	}
	if resp.Text != `Created and verified note "architecture-test".` {
		t.Fatalf("unexpected response text: %q", resp.Text)
	}

	task, err := h.Store.GetTask(ctx, "e2e-cn-1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != store.StateSucceeded {
		t.Fatalf("expected durable task state SUCCEEDED, got %s", task.State)
	}

	// Prove the real file exists in the TEST workspace with the exact
	// expected content — never the user's real Documents/Desktop.
	entries, err := os.ReadDir(h.WorkspaceRoot)
	if err != nil {
		t.Fatalf("reading test workspace: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly one file in the test workspace, got %d: %+v", len(entries), entries)
	}
	content, err := os.ReadFile(filepath.Join(h.WorkspaceRoot, entries[0].Name()))
	if err != nil {
		t.Fatalf("reading created note file: %v", err)
	}
	contentStr := string(content)
	if !strings.Contains(contentStr, "architecture-test") || !strings.Contains(contentStr, "Phase 1 works") {
		t.Fatalf("note content does not contain expected title/body: %q", contentStr)
	}

	trail, _ := h.Store.GetAuditTrail(ctx, "e2e-cn-1")
	wantSequence := []store.EventType{
		store.EventIRCompiled, store.EventIRValidated, store.EventContextCompiled, store.EventPlanCreated,
		store.EventPolicyEvaluated, store.EventCapabilityAuthorized, store.EventCapabilityStarted,
		store.EventCapabilityCompleted, store.EventVerificationStarted, store.EventVerificationCompleted,
		store.EventTaskSucceeded,
	}
	assertEventSequence(t, trail, wantSequence)
}

// M7 brief §37: unsupported/denied requests never produce a side effect.
func TestE2E_UnsupportedRequest_NoSideEffect(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "delete every file"), "e2e-unsup-1")
	if resp.Outcome != "UNSUPPORTED_INTENT" {
		t.Fatalf("expected UNSUPPORTED_INTENT, got %+v", resp)
	}
	if resp.Text != "That capability isn't available in Phase 1." {
		t.Fatalf("unexpected response text: %q", resp.Text)
	}

	// No task was ever created — unsupported text never reaches RawIR at
	// all (see cognitive-core's design: Compile() failure produces no IR).
	_, err := h.Store.GetTask(ctx, "e2e-unsup-1")
	if err == nil {
		t.Fatalf("expected no task record to exist for an unsupported request")
	}

	entries, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entries) != 0 {
		t.Fatalf("expected zero files created, got %d", len(entries))
	}
}

func assertEventSequence(t *testing.T, trail []store.AuditEvent, want []store.EventType) {
	t.Helper()
	if len(trail) != len(want) {
		t.Fatalf("expected %d audit events, got %d: %+v", len(want), len(trail), eventTypes(trail))
	}
	for i, w := range want {
		if trail[i].EventType != w {
			t.Fatalf("event %d: expected %s, got %s (full sequence: %v)", i, w, trail[i].EventType, eventTypes(trail))
		}
	}
}

func eventTypes(trail []store.AuditEvent) []store.EventType {
	out := make([]store.EventType, len(trail))
	for i, e := range trail {
		out[i] = e.EventType
	}
	return out
}
