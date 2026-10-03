package orchestrator

import (
	"context"
	"os"
	"testing"
	"time"

	"friday/runtime-store/store"
)

// M7 brief §24A: Policy Engine unavailable BEFORE authorization is even
// attempted -> fail closed, no execution.
func TestE2E_ProcessFailure_PolicyEngineUnavailableBeforeAuth(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.PolicyEngine.Kill()
	time.Sleep(100 * time.Millisecond)

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "check system status"), "e2e-pf-policy-1")
	if resp.Outcome != "POLICY_UNAVAILABLE" {
		t.Fatalf("expected POLICY_UNAVAILABLE, got %+v", resp)
	}
	task, err := h.Store.GetTask(ctx, "e2e-pf-policy-1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State == store.StateSucceeded || task.State == store.StateAuthorized || task.State == store.StateRunning {
		t.Fatalf("task must not progress past AWAITING_AUTHORIZATION when the Policy Engine is unreachable, got %s", task.State)
	}
	entries, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entries) != 0 {
		t.Fatalf("expected zero files created, got %d", len(entries))
	}
}

// M7 brief §24B: Policy Engine killed DURING the authorization request ->
// no execution, no fabricated ALLOW.
func TestE2E_ProcessFailure_PolicyEngineKilledDuringAuth(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	raw := h.createTaskUpTo(t, "e2e-pf-policy-2", "check system status", store.StateAwaitingAuthorization)
	h.PolicyEngine.Kill() // gone before the orchestrator would call EvaluateAuthorization

	digest := mustDigest(raw.Content.Parameters)
	_, err := h.Orch.policyClient.EvaluateAuthorization(ctx, evaluateRequestWithFactors(raw, "e2e-pf-policy-2", digest, h.Orch.assuranceFactors()))
	if err == nil {
		t.Fatalf("expected EvaluateAuthorization to fail once the Policy Engine process is dead")
	}
	task, _ := h.Store.GetTask(ctx, "e2e-pf-policy-2")
	if task.State != store.StateAwaitingAuthorization {
		t.Fatalf("expected the task to remain AWAITING_AUTHORIZATION, got %s", task.State)
	}
}

// M7 brief §24C: Capability Bus unavailable BEFORE dispatch -> task does
// not falsely succeed.
func TestE2E_ProcessFailure_CapabilityBusUnavailableBeforeDispatch(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.CapabilityBus.Kill()
	time.Sleep(100 * time.Millisecond)

	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "check system status"), "e2e-pf-bus-1")
	if resp.Outcome != "CAPABILITY_UNAVAILABLE" {
		t.Fatalf("expected CAPABILITY_UNAVAILABLE, got %+v", resp)
	}
	task, err := h.Store.GetTask(ctx, "e2e-pf-bus-1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State == store.StateSucceeded {
		t.Fatalf("task must never falsely reach SUCCEEDED when the Capability Bus is unreachable")
	}
	entries, _ := os.ReadDir(h.WorkspaceRoot)
	if len(entries) != 0 {
		t.Fatalf("expected zero files created, got %d", len(entries))
	}
}
