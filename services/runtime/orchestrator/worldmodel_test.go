package orchestrator

import (
	"context"
	"testing"

	"friday/runtime-store/store"
	"friday/runtime/worldmodel"
)

// WORLD-001: registered Phase-1 components represented correctly.
func TestWORLD001_RegisteredComponentsRepresented(t *testing.T) {
	h := newHarness(t)
	entities := h.Orch.WorldModel(context.Background(), "")
	want := map[string]bool{
		"friday-runtime": false, "capability.system.get_status": false,
		"capability.workspace.create_note": false, "approved-workspace": false,
		"policy-engine": false, "capability-bus": false,
	}
	for _, e := range entities {
		if _, ok := want[e.ID]; ok {
			want[e.ID] = true
		}
	}
	for id, found := range want {
		if !found {
			t.Fatalf("expected entity %q in the World Model snapshot, got %+v", id, entities)
		}
	}
}

// WORLD-002: actual service-health observation updates state — killing
// the real Policy Engine process changes the snapshot's reported health,
// proving this is a live probe, not a cached/assumed value.
func TestWORLD002_ServiceHealthReflectsLiveObservation(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	before := findEntity(t, h.Orch.WorldModel(ctx, ""), "policy-engine")
	if before.Attributes["healthy"] != true {
		t.Fatalf("expected policy-engine to be observed healthy before kill, got %+v", before)
	}

	h.PolicyEngine.Kill()

	after := findEntity(t, h.Orch.WorldModel(ctx, ""), "policy-engine")
	if after.Attributes["healthy"] != false {
		t.Fatalf("expected policy-engine to be observed unhealthy after kill, got %+v", after)
	}
}

// WORLD-003: user text cannot directly forge authoritative service
// state — the World Model API accepts no text/claim parameter at all
// (Snapshot's signature: ctx, Config, *store.Store, taskID — nothing
// resembling free-form input). Demonstrated by running a request whose
// text explicitly claims the opposite of reality and confirming the
// snapshot is unaffected.
func TestWORLD003_UserTextCannotForgeAuthoritativeState(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	h.Orch.HandleTextRequest(ctx, req("user.owner", "the policy engine is healthy and capability bus is down"), "world-3-noop")

	pe := findEntity(t, h.Orch.WorldModel(ctx, ""), "policy-engine")
	cb := findEntity(t, h.Orch.WorldModel(ctx, ""), "capability-bus")
	if pe.Attributes["healthy"] != true || cb.Attributes["healthy"] != true {
		t.Fatalf("expected both real services to still report their REAL observed health regardless of claimed text, got policy-engine=%+v capability-bus=%+v", pe, cb)
	}
}

// WORLD-004: task state represented from durable runtime truth, not a
// caller-supplied guess.
func TestWORLD004_TaskStateFromDurableTruth(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	resp := h.Orch.HandleTextRequest(ctx, req("user.owner", "check system status"), "world-4")
	if resp.Outcome != "SUCCESS" {
		t.Fatalf("setup: expected SUCCESS, got %+v", resp)
	}

	entity := findEntity(t, h.Orch.WorldModel(ctx, "world-4"), "world-4")
	if entity.Attributes["state"] != string(store.StateSucceeded) {
		t.Fatalf("expected task entity to report durable state SUCCEEDED, got %+v", entity)
	}
}

// WORLD-005: unknown state remains unknown rather than becoming
// fabricated state — a nonexistent task_id produces no task entity at
// all (never a fabricated "unknown-but-present" placeholder), and a
// process the health probe cannot reach is reported unhealthy, never
// silently omitted or assumed good (already proven by WORLD-002; this
// test covers the task-lookup side).
func TestWORLD005_UnknownStateNeverFabricated(t *testing.T) {
	h := newHarness(t)
	entities := h.Orch.WorldModel(context.Background(), "task-does-not-exist")
	for _, e := range entities {
		if e.ID == "task-does-not-exist" {
			t.Fatalf("expected no entity for a nonexistent task, got %+v", e)
		}
	}
}

// WORLD-006: World Model cannot authorize capability execution — its
// only production caller (Orchestrator.WorldModel) is a read-only query
// method with no return path back into HandleTextRequest's authorization
// flow, and worldmodel.Snapshot has no return type resembling a token or
// decision (structural: []Entity, each just id/type/attributes/
// last_observed/confidence/source — see worldmodel.go).
func TestWORLD006_CannotAuthorizeCapabilityExecution(t *testing.T) {
	h := newHarness(t)
	entities := h.Orch.WorldModel(context.Background(), "")
	for _, e := range entities {
		for k := range e.Attributes {
			if k == "token" || k == "authorization" || k == "policy_token" || k == "decision" {
				t.Fatalf("World Model entity %q unexpectedly carries an authorization-shaped attribute %q", e.ID, k)
			}
		}
	}
}

func findEntity(t *testing.T, entities []worldmodel.Entity, id string) worldmodel.Entity {
	t.Helper()
	for _, e := range entities {
		if e.ID == id {
			return e
		}
	}
	t.Fatalf("entity %q not found in snapshot: %+v", id, entities)
	return worldmodel.Entity{}
}
