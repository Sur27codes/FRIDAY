package orchestrator

import (
	"context"
	"os"
	"testing"

	"friday/runtime-store/store"
	"friday/runtime/wireclient"
)

// M7 brief §41: PLANNED -> restart -> recover safely (durable state
// intact, no unauthorized automatic progress).
func TestE2E_Restart_PlannedRecoversSafely(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.createTaskUpTo(t, "e2e-restart-1", "check system status", store.StatePlanned)

	h.Store.Close()
	reopened, err := store.Open(h.StorePath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	task, err := reopened.GetTask(ctx, "e2e-restart-1")
	if err != nil {
		t.Fatalf("GetTask after reopen: %v", err)
	}
	if task.State != store.StatePlanned {
		t.Fatalf("expected PLANNED to survive restart, got %s", task.State)
	}
	// No automatic progress — reopening the store must never itself
	// advance a task's state.
	if task.State == store.StateAuthorized || task.State == store.StateRunning || task.State == store.StateSucceeded {
		t.Fatalf("restart must never automatically advance task state, got %s", task.State)
	}
}

// M7 brief §41: SUCCEEDED -> restart -> does not execute again. Runs the
// full real HandleTextRequest to real SUCCEEDED, restarts the store
// (rebuilding a fresh Orchestrator against the same on-disk file — a
// genuine process-restart simulation, not merely re-reading a task), then
// attempts the SAME request again and confirms no duplicate file is
// created.
func TestE2E_Restart_SucceededDoesNotReExecute(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	textReq := req("user.owner", "create a note called restart-test with content-a")
	resp := h.Orch.HandleTextRequest(ctx, textReq, "e2e-restart-2")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("setup: expected SUCCESS, got %+v", resp)
	}
	entriesBefore, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entriesBefore) != 1 {
		t.Fatalf("setup: expected exactly one file, got %d", len(entriesBefore))
	}

	// Simulate a Runtime process restart: close the store, reopen against
	// the same file, build a FRESH Orchestrator (fresh process startedAt,
	// fresh in-memory state) — but the same real Policy Engine/Capability
	// Bus subprocesses remain running (a Runtime restart, not a full
	// system restart).
	h.Store.Close()
	reopened, err := store.Open(h.StorePath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	restartedOrch := New(Config{
		Store:        reopened,
		PolicyClient: h.Orch.policyClient,
		BusClient:    h.Orch.busClient,
	})

	task, err := reopened.GetTask(ctx, "e2e-restart-2")
	if err != nil {
		t.Fatalf("GetTask after reopen: %v", err)
	}
	if task.State != store.StateSucceeded {
		t.Fatalf("expected SUCCEEDED to survive restart, got %s", task.State)
	}

	// A genuinely NEW task attempting the identical logical request
	// (same idempotency key, since it's the same title+body) must be
	// recognized as a duplicate, not re-executed.
	sameReq := req("user.owner", "create a note called restart-test with content-a")
	sameReq.CorrelationID = textReq.CorrelationID // same logical request
	dupResp := restartedOrch.HandleTextRequest(ctx, sameReq, "e2e-restart-2-retry")
	if dupResp.Outcome != "DUPLICATE_REQUEST" {
		t.Fatalf("expected DUPLICATE_REQUEST for a repeated identical request after restart, got %+v", dupResp)
	}

	entriesAfter, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entriesAfter) != 1 {
		t.Fatalf("expected still exactly one file after the post-restart duplicate attempt, got %d", len(entriesAfter))
	}
}

// M7 brief §24E-J: process-restart failure scenarios at each critical
// checkpoint, using a real store close/reopen.
func TestE2E_ProcessFailure_RestartAtEachCheckpoint(t *testing.T) {
	cases := []struct {
		name      string
		upTo      store.TaskState
		wantAfter store.TaskState
	}{
		{"after CREATED", store.StateCreated, store.StateCreated},
		{"after VALIDATED", store.StateValidated, store.StateValidated},
		{"after PLANNED", store.StatePlanned, store.StatePlanned},
		{"after AWAITING_AUTHORIZATION", store.StateAwaitingAuthorization, store.StateAwaitingAuthorization},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			ctx := context.Background()
			h.createTaskUpTo(t, "e2e-pf-"+c.name, "check system status", c.upTo)

			h.Store.Close()
			reopened, err := store.Open(h.StorePath)
			if err != nil {
				t.Fatalf("reopen: %v", err)
			}
			defer reopened.Close()

			task, err := reopened.GetTask(ctx, "e2e-pf-"+c.name)
			if err != nil {
				t.Fatalf("GetTask after reopen: %v", err)
			}
			if task.State != c.wantAfter {
				t.Fatalf("expected %s after restart, got %s", c.wantAfter, task.State)
			}
		})
	}
}

// M7 brief §24G/H: restart while RUNNING/VERIFYING must never be assumed
// SUCCEEDED — proven by confirming the legal-transition guard itself
// (already proven at the store level in M6, re-confirmed here at the E2E
// module boundary since M7 is a different module that must not silently
// weaken it).
func TestE2E_ProcessFailure_RunningAndVerifyingNeverAssumedSucceeded(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	raw := h.createTaskUpTo(t, "e2e-pf-running", "check system status", store.StateAwaitingAuthorization)

	digest := mustDigest(raw.Content.Parameters)
	evalResp, err := h.Orch.policyClient.EvaluateAuthorization(ctx, wireclient.EvaluateRequest{
		RequestID: "r", CorrelationID: "c", TaskID: "e2e-pf-running", IRID: raw.IRID,
		Actor: "user.owner", Capability: raw.Goal.Type, Risk: string(raw.Risk.Level), ArgumentsDigest: digest,
		AssuranceFactors: h.Orch.assuranceFactors(),
	})
	if err != nil || evalResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evalResp.Decision, err)
	}
	h.Store.TransitionTask(ctx, "e2e-pf-running", store.StateAuthorized)
	h.Store.TransitionTask(ctx, "e2e-pf-running", store.StateRunning)

	h.Store.Close()
	reopened, err := store.Open(h.StorePath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	if err := reopened.TransitionTask(ctx, "e2e-pf-running", store.StateSucceeded); err == nil {
		t.Fatalf("expected RUNNING -> SUCCEEDED to remain illegal after a Runtime restart")
	}
	task, _ := reopened.GetTask(ctx, "e2e-pf-running")
	if task.State != store.StateRunning {
		t.Fatalf("expected the recovered state to remain RUNNING, got %s", task.State)
	}
}
