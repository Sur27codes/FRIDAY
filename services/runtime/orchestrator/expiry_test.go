package orchestrator

import (
	"context"
	"os"
	"testing"
	"time"

	"friday/cognitive-core/intentcompiler"
	"friday/ir"
	"friday/runtime-store/store"
	"friday/runtime/wireclient"
)

// M7 brief §39: token expiry. No clock-injection configuration exists on
// either real daemon — by design, not by oversight: "server owns the
// clock" (policy-engine/internal/rpc/server.go's handleEvaluate, and
// bus.Dispatch's own per-call time.Now() since the M4 clock-ownership
// fix) is a deliberate security property specifically preventing a
// caller from lying about the current time to extend or fabricate
// freshness. There is therefore no "controlled clock" configuration to
// use instead of a real wait — this reuses M4's own already-accepted
// real-sleep pattern (TestM4POL012) rather than reintroducing a frozen-
// clock shortcut, which is exactly the bug M4's fix closed.
func TestE2E_TokenExpiry_RejectedAfterRealTTL(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping real 15s token-expiry wait in -short mode")
	}
	h := newHarness(t)
	ctx := context.Background()

	textReq := req("user.owner", "check system status")
	raw, cerr := intentcompiler.Compile(textReq)
	if cerr != nil {
		t.Fatalf("Compile: %v", cerr)
	}
	taskID := "e2e-expiry-1"
	if err := h.Store.CreateTask(ctx, store.Task{
		TaskID: taskID, CorrelationID: textReq.CorrelationID, Actor: textReq.Actor,
		CapabilityID: raw.Goal.Type, IRID: raw.IRID, IdempotencyKey: raw.Idempotency.IdempotencyKey,
	}); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	digest := mustDigest(raw.Content.Parameters)
	if err := h.Store.SaveIRSnapshot(ctx, store.IRSnapshot{
		IRID: raw.IRID, TaskID: taskID, CapabilityID: raw.Goal.Type, RiskLevel: raw.Risk.Level,
		Reversible: raw.Effects.Reversible, Arguments: raw.Content.Parameters, ArgumentsDigest: digest,
		DataClassification: "INTERNAL",
	}); err != nil {
		t.Fatalf("SaveIRSnapshot: %v", err)
	}
	if _, verr := ir.Validate(raw, ir.Phase1Registry()); verr != nil {
		t.Fatalf("ir.Validate: %v", verr)
	}
	h.Store.TransitionTask(ctx, taskID, store.StateValidated)
	h.Store.TransitionTask(ctx, taskID, store.StatePlanned)
	h.Store.TransitionTask(ctx, taskID, store.StateAwaitingAuthorization)

	evalResp, err := h.Orch.policyClient.EvaluateAuthorization(ctx, wireclient.EvaluateRequest{
		RequestID: textReq.RequestID, CorrelationID: textReq.CorrelationID, TaskID: taskID, IRID: raw.IRID,
		Actor: textReq.Actor, Capability: raw.Goal.Type, Risk: string(raw.Risk.Level), ArgumentsDigest: digest,
		AssuranceFactors: h.Orch.assuranceFactors(),
	})
	if err != nil || evalResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evalResp.Decision, err)
	}
	h.Store.TransitionTask(ctx, taskID, store.StateAuthorized)

	time.Sleep(16 * time.Second) // real token TTL is 15s (policy-engine/internal/policy/token.go)

	if err := h.Orch.busClient.DevSeedIR(ctx, wireclient.DevSeedIRRequest{IRID: raw.IRID, CapabilityID: raw.Goal.Type, Arguments: raw.Content.Parameters}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := h.Orch.busClient.DevSeedTask(ctx, wireclient.DevSeedTaskRequest{TaskID: taskID, State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	envelope := buildEnvelope(textReq, taskID, contextObjFromRaw(raw, taskID, textReq.RequestID, digest), raw.IRVersion, evalResp)
	_, dispatchErr := h.Orch.busClient.Dispatch(ctx, wireclient.DispatchRequest{Envelope: envelope})
	if dispatchErr == nil {
		t.Fatalf("expected dispatch to be rejected after real TTL elapsed, got success")
	}

	entries, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entries) != 0 {
		t.Fatalf("expected zero files created for an expired-token dispatch attempt, got %d", len(entries))
	}
}
