package orchestrator

import (
	"context"
	"testing"

	"friday/cognitive-core/intentcompiler"
	"friday/ir"
	"friday/runtime-store/store"
	"friday/runtime/wireclient"
)

// createTaskUpTo drives a task manually up to (and including) upToState,
// using the real Compile/Validate pipeline, for tests that need to
// inspect or act at a specific pre-execution checkpoint
// (PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §3's table).
func (h *testHarness) createTaskUpTo(t *testing.T, taskID, text string, upToState store.TaskState) ir.RawIR {
	t.Helper()
	textReq := req("user.owner", text)
	raw, cerr := intentcompiler.Compile(textReq)
	if cerr != nil {
		t.Fatalf("Compile: %v", cerr)
	}
	if err := h.Store.CreateTask(context.Background(), store.Task{
		TaskID: taskID, CorrelationID: textReq.CorrelationID, Actor: textReq.Actor,
		CapabilityID: raw.Goal.Type, IRID: raw.IRID, IdempotencyKey: raw.Idempotency.IdempotencyKey,
	}); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	if upToState == store.StateCreated {
		return raw
	}
	if _, verr := ir.Validate(raw, ir.Phase1Registry()); verr != nil {
		t.Fatalf("ir.Validate: %v", verr)
	}
	h.Store.TransitionTask(context.Background(), taskID, store.StateValidated)
	if upToState == store.StateValidated {
		return raw
	}
	h.Store.TransitionTask(context.Background(), taskID, store.StatePlanned)
	if upToState == store.StatePlanned {
		return raw
	}
	h.Store.TransitionTask(context.Background(), taskID, store.StateAwaitingAuthorization)
	return raw
}

// M7 brief §40 / STOP-001: stop while PLANNED -> immediate CANCELLED, no
// authorization ever attempted, Bus never invoked.
func TestE2E_Cancel_BeforeExecution_Planned(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.createTaskUpTo(t, "e2e-cancel-1", "check system status", store.StatePlanned)

	resp := h.Orch.Cancel(ctx, "e2e-cancel-1")
	if resp.Outcome != "CANCELLED" {
		t.Fatalf("expected CANCELLED, got %+v", resp)
	}
	task, _ := h.Store.GetTask(ctx, "e2e-cancel-1")
	if task.State != store.StateCancelled {
		t.Fatalf("expected durable CANCELLED, got %s", task.State)
	}
	trail, _ := h.Store.GetAuditTrail(ctx, "e2e-cancel-1")
	foundStopRequested, foundTaskCancelled := false, false
	for _, ev := range trail {
		if ev.EventType == store.EventStopRequested {
			foundStopRequested = true
		}
		if ev.EventType == store.EventTaskCancelled {
			foundTaskCancelled = true
		}
	}
	if !foundStopRequested || !foundTaskCancelled {
		t.Fatalf("expected StopRequested and TaskCancelled audit events, got %v", eventTypes(trail))
	}
}

// STOP-002: stop while AWAITING_AUTHORIZATION.
func TestE2E_Cancel_WhileAwaitingAuthorization(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.createTaskUpTo(t, "e2e-cancel-2", "check system status", store.StateAwaitingAuthorization)

	resp := h.Orch.Cancel(ctx, "e2e-cancel-2")
	if resp.Outcome != "CANCELLED" {
		t.Fatalf("expected CANCELLED, got %+v", resp)
	}
	task, _ := h.Store.GetTask(ctx, "e2e-cancel-2")
	if task.State != store.StateCancelled {
		t.Fatalf("expected durable CANCELLED, got %s", task.State)
	}
}

// STOP-002/STOP-009: a token obtained BEFORE cancellation becomes unusable
// afterward — the Bus rejects dispatch once the task is durably CANCELLED
// (this Runtime seeds the Bus's own TaskStore from durable state, so a
// cancelled durable task cannot be represented to the Bus as AUTHORIZED
// at all — the mechanism is structural, not a race hoped to resolve
// correctly).
func TestE2E_Cancel_AuthorizationBecomesUnusable(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	raw := h.createTaskUpTo(t, "e2e-cancel-3", "check system status", store.StateAwaitingAuthorization)

	digest := mustDigest(raw.Content.Parameters)
	evalResp, err := h.Orch.policyClient.EvaluateAuthorization(ctx, wireclient.EvaluateRequest{
		RequestID: "r3", CorrelationID: "c3", TaskID: "e2e-cancel-3", IRID: raw.IRID,
		Actor: "user.owner", Capability: raw.Goal.Type, Risk: string(raw.Risk.Level), ArgumentsDigest: digest,
		AssuranceFactors: h.Orch.assuranceFactors(),
	})
	if err != nil || evalResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evalResp.Decision, err)
	}
	h.Store.TransitionTask(ctx, "e2e-cancel-3", store.StateAuthorized)
	h.Store.SaveIRSnapshot(ctx, store.IRSnapshot{IRID: raw.IRID, TaskID: "e2e-cancel-3", CapabilityID: raw.Goal.Type,
		RiskLevel: raw.Risk.Level, Reversible: raw.Effects.Reversible, Arguments: raw.Content.Parameters,
		ArgumentsDigest: digest, DataClassification: "INTERNAL"})

	// Now cancel — the durable AUTHORIZED token's owning task moves to
	// CANCELLED, a terminal state with no legal path back to RUNNING.
	cancelResp := h.Orch.Cancel(ctx, "e2e-cancel-3")
	if cancelResp.Outcome != "CANCELLED" {
		t.Fatalf("expected CANCELLED, got %+v", cancelResp)
	}

	// Seed the Bus honestly reflecting the durable (CANCELLED) task state
	// — a real Runtime would never claim AUTHORIZED for a task it knows
	// is cancelled. This proves the Bus's own check 6f rejects it too.
	h.Orch.busClient.DevSeedIR(ctx, wireclient.DevSeedIRRequest{IRID: raw.IRID, CapabilityID: raw.Goal.Type, Arguments: raw.Content.Parameters})
	h.Orch.busClient.DevSeedTask(ctx, wireclient.DevSeedTaskRequest{TaskID: "e2e-cancel-3", State: "CANCELLED"})

	envelope := buildEnvelope(req("user.owner", "check system status"), "e2e-cancel-3", contextObjFromRaw(raw, "e2e-cancel-3", "r3", digest), raw.IRVersion, evalResp)
	_, dispatchErr := h.Orch.busClient.Dispatch(ctx, wireclient.DispatchRequest{Envelope: envelope})
	if dispatchErr == nil {
		t.Fatalf("expected the previously-issued token to be rejected once the owning task is CANCELLED")
	}
}

// STOP-012-adjacent: a cancelled task's durable state never resumes on
// its own — proven both by direct re-transition attempts (already
// covered at the store level, M6-CANCEL-003) and here by confirming a
// restart (real store close/reopen) doesn't change anything.
func TestE2E_Cancel_DoesNotAutoResumeAfterRestart(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.createTaskUpTo(t, "e2e-cancel-4", "check system status", store.StatePlanned)
	h.Orch.Cancel(ctx, "e2e-cancel-4")

	h.Store.Close()
	reopened, err := store.Open(h.StorePath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(ctx, "e2e-cancel-4")
	if err != nil {
		t.Fatalf("GetTask after reopen: %v", err)
	}
	if task.State != store.StateCancelled {
		t.Fatalf("expected CANCELLED to survive restart, got %s", task.State)
	}
}

// STOP-007: repeated stop is safe and idempotent, no duplicate
// TaskCancelled event.
func TestE2E_Cancel_Idempotent(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.createTaskUpTo(t, "e2e-cancel-5", "check system status", store.StatePlanned)

	first := h.Orch.Cancel(ctx, "e2e-cancel-5")
	if first.Outcome != "CANCELLED" {
		t.Fatalf("expected CANCELLED, got %+v", first)
	}
	for i := 0; i < 10; i++ {
		resp := h.Orch.Cancel(ctx, "e2e-cancel-5")
		if resp.Outcome != "ALREADY_TERMINAL" {
			t.Fatalf("iteration %d: expected ALREADY_TERMINAL for a repeated stop, got %+v", i, resp)
		}
	}
	trail, _ := h.Store.GetAuditTrail(ctx, "e2e-cancel-5")
	cancelledCount := 0
	for _, ev := range trail {
		if ev.EventType == store.EventTaskCancelled {
			cancelledCount++
		}
	}
	if cancelledCount != 1 {
		t.Fatalf("expected exactly one TaskCancelled audit event despite 11 stop attempts, got %d", cancelledCount)
	}
}
