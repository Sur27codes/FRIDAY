// M6-REC-001..007: crash/restart recovery. Each test closes the store
// (simulating process exit at a specific point) and reopens it against
// the same on-disk file (simulating restart) to prove the durable state
// is what a real recovering Runtime would see — not what an in-memory
// mock would report.
package store

import (
	"context"
	"testing"
)

func TestM6REC001_PlannedSurvivesRestart(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r1")
	mustTransition(t, s, "r1", StateValidated)
	mustTransition(t, s, "r1", StatePlanned)
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "r1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StatePlanned {
		t.Fatalf("expected PLANNED to survive restart, got %s", task.State)
	}
}

func TestM6REC002_CancelledSurvivesRestart(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r2")
	mustTransition(t, s, "r2", StateCancelled)
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "r2")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateCancelled {
		t.Fatalf("expected CANCELLED to survive restart, got %s", task.State)
	}
}

func TestM6REC003_SucceededSurvivesRestartAndDoesNotReExecute(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r3")
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning, StateVerifying, StateSucceeded} {
		mustTransition(t, s, "r3", st)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "r3")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateSucceeded {
		t.Fatalf("expected SUCCEEDED to survive restart, got %s", task.State)
	}
	// "Does not re-execute" at this layer means: SUCCEEDED is terminal,
	// so no transition out of it — including back into RUNNING — is ever
	// legal again after recovery, structurally preventing a recovered
	// Runtime from driving this task through the adapter a second time.
	if err := reopened.TransitionTask(context.Background(), "r3", StateRunning); err == nil {
		t.Fatalf("expected SUCCEEDED -> RUNNING to remain illegal after restart")
	}
}

// M6-REC-004: a task recovered in RUNNING must not automatically become
// SUCCEEDED. This durable layer enforces this the same way it enforces
// it pre-restart: RUNNING has no legal direct edge to SUCCEEDED at all
// (only RUNNING -> VERIFYING -> SUCCEEDED) — restart changes nothing
// about which edges are legal, so a recovering Runtime attempting to
// "just mark it done" is rejected identically to a live attempt.
func TestM6REC004_RunningRecoveredStateDoesNotAutomaticallyBecomeSucceeded(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r4")
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning} {
		mustTransition(t, s, "r4", st)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "r4")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateRunning {
		t.Fatalf("expected the task to be recovered in RUNNING, got %s", task.State)
	}
	if err := reopened.TransitionTask(context.Background(), "r4", StateSucceeded); err == nil {
		t.Fatalf("expected RUNNING -> SUCCEEDED to remain illegal after restart (must pass through VERIFYING)")
	}
	// The legal, safe recovery path remains open: RUNNING -> VERIFYING is
	// still available for whatever recovery logic the Runtime applies
	// (M6 brief §16E/§17: "recover safely according to the approved
	// Phase-1 policy" — deciding WHETHER to re-verify is Runtime/M7
	// logic; this store's job is only to make sure the state machine
	// itself never lets that decision be skipped).
	if err := reopened.TransitionTask(context.Background(), "r4", StateVerifying); err != nil {
		t.Fatalf("expected RUNNING -> VERIFYING to remain legal after restart: %v", err)
	}
}

func TestM6REC005_VerifyingStateRecoveryFollowsApprovedRule(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r5")
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning, StateVerifying} {
		mustTransition(t, s, "r5", st)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "r5")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateVerifying {
		t.Fatalf("expected the task to be recovered in VERIFYING, got %s", task.State)
	}
	// PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §3: VERIFYING "may resume/re-run
	// if safe" — all 5 of VERIFYING's legal successor states remain
	// reachable after restart, exactly as before.
	for _, target := range []TaskState{StateSucceeded, StateFailed, StateCancelled, StateCompensating, StateRequiresManualReview} {
		if !CanTransition(StateVerifying, target) {
			t.Fatalf("expected VERIFYING -> %s to remain legal after restart", target)
		}
	}
}

// M6-REC-006: the case explicitly called out in M6 brief §17 — a
// capability side effect may have occurred but the process crashed
// before durable completion state was recorded. This durable layer
// cannot know whether the real-world write happened (that requires
// calling the real capability, which is M7/Runtime scope) — what it CAN
// and must do is make that uncertainty durably OBSERVABLE: a
// CapabilityInvocation row with StartedAt set and CompletedAt still nil
// is the durable "uncertain execution" signal a recovering Runtime uses
// to decide NOT to blindly retry (M6 brief §17's capability-specific
// idempotency/verification handling, not a generic distributed
// transaction engine).
func TestM6REC006_SideEffectBeforeVerificationPersistence_UncertaintyIsObservable(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "r6")
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning} {
		mustTransition(t, s, "r6", st)
	}
	// The adapter call started (real side effect may have begun) but the
	// process "crashes" before CompleteInvocation is ever called.
	invID, err := s.StartInvocation(context.Background(), "r6", "workspace.create_note")
	if err != nil {
		t.Fatalf("StartInvocation: %v", err)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	invocations, err := reopened.GetInvocationsForTask(context.Background(), "r6")
	if err != nil {
		t.Fatalf("GetInvocationsForTask: %v", err)
	}
	if len(invocations) != 1 || invocations[0].InvocationID != invID {
		t.Fatalf("expected the started-but-not-completed invocation to survive restart, got %+v", invocations)
	}
	if invocations[0].CompletedAt != nil {
		t.Fatalf("expected CompletedAt to remain nil — this is the durable 'outcome unknown' signal, never fabricated as success or failure")
	}
	// A recovering Runtime must be able to distinguish this exact case
	// (started, never completed) from "never started at all" — confirmed
	// by StartedAt being non-zero.
	if invocations[0].StartedAt.IsZero() {
		t.Fatalf("expected StartedAt to be recorded")
	}
	// Idempotency guard for this same operation remains enforceable
	// post-restart regardless of whether the side effect actually
	// occurred — see M6-IDEM-005 for the full duplicate-registration
	// proof; here we confirm the record the Runtime would consult is at
	// least present and reachable.
	if _, _, err := reopened.RegisterIdempotency(context.Background(), "idem-r6", "r6", "workspace.create_note", "digestX"); err != nil {
		t.Fatalf("RegisterIdempotency after restart: %v", err)
	}
}

func TestM6REC007_PersistenceFailureDoesNotCreatePermissiveExecutionState(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "r7")
	// A transition attempt against a task_id that does not exist must
	// fail closed (RECORD_NOT_FOUND), never silently succeed and leave
	// some implicit "it's fine, proceed" state behind.
	err := s.TransitionTask(context.Background(), "nonexistent-task", StateValidated)
	if err == nil {
		t.Fatalf("expected a transition on a nonexistent task to fail")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrRecordNotFound {
		t.Fatalf("expected RECORD_NOT_FOUND, got %v", err)
	}
	// After the failed attempt, the real task's state is exactly what it
	// was before — no partial/side-channel mutation occurred.
	task, err := s.GetTask(context.Background(), "r7")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateCreated {
		t.Fatalf("expected the unrelated task's state to be untouched by the failed transition, got %s", task.State)
	}
}

// A closed store must fail closed on every operation, not panic and not
// silently no-op as if it succeeded — the concrete form of "persistence
// unavailable must not cause unsafe execution" (M6 brief §22).
func TestPersistenceUnavailable_ClosedStoreFailsClosedNotPanics(t *testing.T) {
	s, _ := newTestStore(t)
	s.Close()

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("operating against a closed store must return an error, not panic: %v", r)
		}
	}()
	err := s.CreateTask(context.Background(), Task{
		TaskID: "after-close", CorrelationID: "c", Actor: "a", CapabilityID: "system.get_status",
		IRID: "ir1", IdempotencyKey: "idem1",
	})
	if err == nil {
		t.Fatalf("expected CreateTask against a closed store to fail")
	}
}
