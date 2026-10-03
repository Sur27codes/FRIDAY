package orchestrator

import (
	"context"
	"os"
	"testing"

	"friday/cognitive-core/intentcompiler"
	"friday/ir"
	"friday/runtime-store/store"
	"friday/runtime/wireclient"
)

// M7 brief §38: alter the note's arguments between authorization and Bus
// invocation and confirm the M1/M2/M3 argument-binding invariant survives
// the entire M7 orchestration, not just M4's own isolated tests. This
// drives the same real subprocesses HandleTextRequest uses, but performs
// the sequence manually (same package, so it can reach the real
// intermediate state) to insert the tamper at the exact point the M7
// brief specifies: "between authorization and Bus invocation."
func TestE2E_ArgumentTamperBetweenAuthorizationAndDispatch(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	original := req("user.owner", "create a note called original-title with original-body")
	raw, cerr := intentcompiler.Compile(original)
	if cerr != nil {
		t.Fatalf("Compile: %v", cerr)
	}
	taskID := "e2e-tamper-1"
	if err := h.Store.CreateTask(ctx, store.Task{
		TaskID: taskID, CorrelationID: original.CorrelationID, Actor: original.Actor,
		CapabilityID: raw.Goal.Type, IRID: raw.IRID, IdempotencyKey: raw.Idempotency.IdempotencyKey,
	}); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	origDigest := mustDigest(raw.Content.Parameters)
	if err := h.Store.SaveIRSnapshot(ctx, store.IRSnapshot{
		IRID: raw.IRID, TaskID: taskID, CapabilityID: raw.Goal.Type, RiskLevel: raw.Risk.Level,
		Reversible: raw.Effects.Reversible, Arguments: raw.Content.Parameters, ArgumentsDigest: origDigest,
		DataClassification: "PERSONAL",
	}); err != nil {
		t.Fatalf("SaveIRSnapshot: %v", err)
	}
	validated, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		t.Fatalf("ir.Validate: %v", verr)
	}
	_ = validated
	h.Store.TransitionTask(ctx, taskID, store.StateValidated)
	h.Store.TransitionTask(ctx, taskID, store.StatePlanned)
	h.Store.TransitionTask(ctx, taskID, store.StateAwaitingAuthorization)

	// Real authorization, bound to the ORIGINAL arguments' digest.
	evalResp, err := h.Orch.policyClient.EvaluateAuthorization(ctx, wireclient.EvaluateRequest{
		RequestID: original.RequestID, CorrelationID: original.CorrelationID, TaskID: taskID, IRID: raw.IRID,
		Actor: original.Actor, Capability: raw.Goal.Type, Risk: string(raw.Risk.Level), ArgumentsDigest: origDigest,
		AssuranceFactors: h.Orch.assuranceFactors(),
	})
	if err != nil || evalResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evalResp.Decision, err)
	}
	h.Store.TransitionTask(ctx, taskID, store.StateAuthorized)

	// TAMPER: re-seed the Bus's own IR record with DIFFERENT arguments —
	// simulating a compromised/buggy path between authorization and
	// dispatch. The token in hand is still bound to origDigest.
	tampered := map[string]interface{}{"title": "TAMPERED-title", "body": "TAMPERED-body"}
	if err := h.Orch.busClient.DevSeedIR(ctx, wireclient.DevSeedIRRequest{IRID: raw.IRID, CapabilityID: raw.Goal.Type, Arguments: tampered}); err != nil {
		t.Fatalf("DevSeedIR (tamper): %v", err)
	}
	if err := h.Orch.busClient.DevSeedTask(ctx, wireclient.DevSeedTaskRequest{TaskID: taskID, State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	envelope := buildEnvelope(original, taskID, contextObjFromRaw(raw, taskID, original.RequestID, origDigest), raw.IRVersion, evalResp) // raw.Content.Parameters is still the ORIGINAL, matching a real caller who doesn't know about the tamper
	_, dispatchErr := h.Orch.busClient.Dispatch(ctx, wireclient.DispatchRequest{Envelope: envelope})
	if dispatchErr == nil {
		t.Fatalf("expected dispatch to be rejected for an argument-digest mismatch, got success")
	}

	// No file created, task never SUCCEEDED.
	entries, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entries) != 0 {
		t.Fatalf("expected zero files created after a rejected tampered dispatch, got %d", len(entries))
	}
	task, _ := h.Store.GetTask(ctx, taskID)
	if task.State == store.StateSucceeded {
		t.Fatalf("task must never reach SUCCEEDED after a rejected tampered dispatch")
	}
}
