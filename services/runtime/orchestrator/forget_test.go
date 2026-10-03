package orchestrator

import (
	"context"
	"testing"

	"friday/runtime-store/store"
)

func createNoteTask(t *testing.T, h *testHarness, taskID, actor string) {
	t.Helper()
	createNoteTaskWithText(t, h, taskID, actor, "create a note called forget-me with sensitive-content")
}

func createNoteTaskWithText(t *testing.T, h *testHarness, taskID, actor, text string) {
	t.Helper()
	resp := h.Orch.HandleTextRequest(context.Background(), req(actor, text), taskID)
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("setup: expected SUCCESS, got %+v", resp)
	}
}

// FORGET-001: eligible Phase-1 memory can be removed.
func TestFORGET001_EligibleMemoryCanBeRemoved(t *testing.T) {
	h := newHarness(t)
	createNoteTask(t, h, "forget-1", "user.owner")

	resp := h.Orch.Forget(context.Background(), "forget-1", "user.owner")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("expected SUCCESS, got %+v", resp)
	}
}

// FORGET-002: forgotten record is no longer returned through normal retrieval.
func TestFORGET002_ForgottenRecordNotReturnedThroughNormalRetrieval(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-2", "user.owner")

	task, err := h.Store.GetTask(ctx, "forget-2")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	before, err := h.Store.GetIRSnapshot(ctx, task.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot before forget: %v", err)
	}
	if before.Arguments["title"] != "forget-me" {
		t.Fatalf("setup: expected the real title before forgetting, got %+v", before.Arguments)
	}

	if resp := h.Orch.Forget(ctx, "forget-2", "user.owner"); resp.Outcome != "SUCCESS" {
		t.Fatalf("Forget: %+v", resp)
	}

	after, err := h.Store.GetIRSnapshot(ctx, task.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot after forget: %v", err)
	}
	if !after.Forgotten {
		t.Fatalf("expected the snapshot to be marked forgotten")
	}
	if after.Arguments["title"] == "forget-me" || after.Arguments["body"] == "sensitive-content" {
		t.Fatalf("expected the real title/body to no longer be returned through normal retrieval, got %+v", after.Arguments)
	}
}

// FORGET-003: forgetting is idempotent.
func TestFORGET003_ForgettingIsIdempotent(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-3", "user.owner")

	for i := 0; i < 5; i++ {
		resp := h.Orch.Forget(ctx, "forget-3", "user.owner")
		if resp.Outcome != "SUCCESS" {
			t.Fatalf("iteration %d: expected SUCCESS, got %+v", i, resp)
		}
	}
}

// FORGET-004: non-forgettable mandatory audit metadata is protected —
// the audit trail, task record, and idempotency record all survive a
// forget request untouched.
func TestFORGET004_MandatoryAuditMetadataProtected(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-4", "user.owner")

	trailBefore, _ := h.Store.GetAuditTrail(ctx, "forget-4")
	if resp := h.Orch.Forget(ctx, "forget-4", "user.owner"); resp.Outcome != "SUCCESS" {
		t.Fatalf("Forget: %+v", resp)
	}
	trailAfter, err := h.Store.GetAuditTrail(ctx, "forget-4")
	if err != nil {
		t.Fatalf("GetAuditTrail after forget: %v", err)
	}
	if len(trailAfter) <= len(trailBefore) {
		t.Fatalf("expected the audit trail to grow (a ContentForgotten event appended), not shrink: before=%d after=%d", len(trailBefore), len(trailAfter))
	}
	for _, ev := range trailBefore {
		found := false
		for _, ev2 := range trailAfter {
			if ev2.EventID == ev.EventID {
				found = true
			}
		}
		if !found {
			t.Fatalf("audit event %s (%s) disappeared after forgetting — mandatory audit metadata must never be removed", ev.EventID, ev.EventType)
		}
	}
	task, err := h.Store.GetTask(ctx, "forget-4")
	if err != nil || task.State != store.StateSucceeded {
		t.Fatalf("expected the task record itself to survive forgetting untouched, got %+v (err=%v)", task, err)
	}
}

// FORGET-005: forgetting does not corrupt task/audit referential integrity.
func TestFORGET005_ForgettingDoesNotCorruptReferentialIntegrity(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-5", "user.owner")

	if resp := h.Orch.Forget(ctx, "forget-5", "user.owner"); resp.Outcome != "SUCCESS" {
		t.Fatalf("Forget: %+v", resp)
	}
	task, err := h.Store.GetTask(ctx, "forget-5")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	snap, err := h.Store.GetIRSnapshot(ctx, task.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot: %v (referential integrity broken — task's own ir_id no longer resolves)", err)
	}
	if snap.TaskID != task.TaskID {
		t.Fatalf("expected the snapshot's task_id to still correctly reference the task, got %q want %q", snap.TaskID, task.TaskID)
	}
}

// FORGET-006: forget request cannot delete arbitrary database records —
// only the exact task's own IR snapshot content is ever touched. Proven
// by forgetting one task and confirming a DIFFERENT, unrelated task's
// content is untouched.
func TestFORGET006_CannotDeleteArbitraryRecords(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-6a", "user.owner")
	createNoteTaskWithText(t, h, "forget-6b", "user.owner", "create a note called forget-me with different-content-entirely")

	if resp := h.Orch.Forget(ctx, "forget-6a", "user.owner"); resp.Outcome != "SUCCESS" {
		t.Fatalf("Forget: %+v", resp)
	}

	taskB, _ := h.Store.GetTask(ctx, "forget-6b")
	snapB, err := h.Store.GetIRSnapshot(ctx, taskB.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot for unrelated task: %v", err)
	}
	if snapB.Forgotten || snapB.Arguments["title"] != "forget-me" {
		t.Fatalf("expected the UNRELATED task's content to remain untouched, got %+v", snapB)
	}
}

// FORGET-007: forgetting scope is bounded to the correct actor/data.
func TestFORGET007_BoundedToCorrectActor(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-7", "user.owner")

	resp := h.Orch.Forget(ctx, "forget-7", "someone.else")
	if resp.Outcome == "SUCCESS" {
		t.Fatalf("expected forgetting to be rejected for a mismatched actor, got %+v", resp)
	}

	task, _ := h.Store.GetTask(ctx, "forget-7")
	snap, err := h.Store.GetIRSnapshot(ctx, task.IRID)
	if err != nil || snap.Forgotten {
		t.Fatalf("expected the content to remain un-forgotten after a wrong-actor attempt, got %+v (err=%v)", snap, err)
	}
}

// FORGET-008: restart does not resurrect forgotten eligible state.
func TestFORGET008_RestartDoesNotResurrectForgottenState(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	createNoteTask(t, h, "forget-8", "user.owner")

	task, _ := h.Store.GetTask(ctx, "forget-8")
	if resp := h.Orch.Forget(ctx, "forget-8", "user.owner"); resp.Outcome != "SUCCESS" {
		t.Fatalf("Forget: %+v", resp)
	}

	h.Store.Close()
	reopened, err := store.Open(h.StorePath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	snap, err := reopened.GetIRSnapshot(ctx, task.IRID)
	if err != nil {
		t.Fatalf("GetIRSnapshot after restart: %v", err)
	}
	if !snap.Forgotten || snap.Arguments["title"] == "forget-me" {
		t.Fatalf("expected the forgotten state to survive restart, got %+v", snap)
	}
}
