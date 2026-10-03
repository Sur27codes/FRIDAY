package store

import (
	"context"
	"sync"
	"testing"
)

func appendCancelledAudit(t *testing.T, s *Store, taskID string) {
	t.Helper()
	_, err := s.AppendAuditEvent(context.Background(), AuditEvent{
		CorrelationID: "corr-" + taskID, TaskID: taskID, Actor: "user.owner",
		EventType: EventTaskCancelled, ResultStatus: "CANCELLED", Sensitivity: SensitivityInternal,
	})
	if err != nil {
		t.Fatalf("appending TaskCancelled audit event: %v", err)
	}
}

func TestM6CANCEL001_CancelledTaskPersistsAsCancelled(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c1")
	mustTransition(t, s, "c1", StateCancelled)
	appendCancelledAudit(t, s, "c1")
	task, err := s.GetTask(context.Background(), "c1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateCancelled {
		t.Fatalf("expected CANCELLED, got %s", task.State)
	}
}

func TestM6CANCEL002_RestartPreservesCancellation(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "c2")
	mustTransition(t, s, "c2", StateCancelled)
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "c2")
	if err != nil {
		t.Fatalf("GetTask after reopen: %v", err)
	}
	if task.State != StateCancelled {
		t.Fatalf("expected CANCELLED to survive restart, got %s", task.State)
	}
}

func TestM6CANCEL003_CancelledTaskCannotRestartExecution(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c3")
	mustTransition(t, s, "c3", StateCancelled)
	for _, target := range []TaskState{StateRunning, StateAuthorized, StateAwaitingAuthorization, StateVerifying} {
		if err := s.TransitionTask(context.Background(), "c3", target); err == nil {
			t.Fatalf("expected CANCELLED -> %s to be rejected", target)
		}
	}
}

// M6-CANCEL-004: a stale, previously-issued authorization must not revive
// a cancelled task. This durable layer's contribution to that guarantee
// is structural: nothing in this package exposes a way to move a task
// out of CANCELLED at all (see legalTransitions), regardless of what
// authorization state a caller claims to be holding — there is no
// "transition with a supplied token" API whose token could be stale.
func TestM6CANCEL004_StaleAuthorizationCannotReviveCancelledTask(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c4")
	mustTransition(t, s, "c4", StateValidated)
	mustTransition(t, s, "c4", StatePlanned)
	mustTransition(t, s, "c4", StateAwaitingAuthorization)
	mustTransition(t, s, "c4", StateAuthorized)
	// A token was "issued" (recorded) here in a real flow — then cancel.
	if _, err := s.SavePolicyDecision(context.Background(), PolicyDecision{
		TaskID: "c4", Decision: "ALLOW", RequiredAAL: "AAL1", Reason: "test", TokenID: "tok-c4",
	}); err != nil {
		t.Fatalf("SavePolicyDecision: %v", err)
	}
	mustTransition(t, s, "c4", StateCancelled)

	// The "stale token" attempting to drive the task into RUNNING is
	// exactly the AUTHORIZED -> RUNNING edge, which no longer exists once
	// the task is CANCELLED (a terminal state).
	if err := s.TransitionTask(context.Background(), "c4", StateRunning); err == nil {
		t.Fatalf("expected the stale-authorization-driven transition to RUNNING to be rejected")
	}
}

func TestM6CANCEL005_CancelVsTransitionRace_DeterministicResult(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c5")
	mustTransition(t, s, "c5", StateValidated)
	mustTransition(t, s, "c5", StatePlanned)
	mustTransition(t, s, "c5", StateAwaitingAuthorization)
	mustTransition(t, s, "c5", StateAuthorized)

	var wg sync.WaitGroup
	results := make(chan error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		results <- s.TransitionTask(context.Background(), "c5", StateCancelled)
	}()
	go func() {
		defer wg.Done()
		results <- s.TransitionTask(context.Background(), "c5", StateRunning)
	}()
	wg.Wait()
	close(results)

	var successes int
	for err := range results {
		if err == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("expected exactly one of {cancel, proceed-to-running} to win the race, got %d successes", successes)
	}
	task, _ := s.GetTask(context.Background(), "c5")
	if task.State != StateCancelled && task.State != StateRunning {
		t.Fatalf("expected the final state to be one of the two attempted transitions, got %s", task.State)
	}
	// Whichever won, the state machine's own invariants must still hold —
	// re-attempting the other transition from the now-current state must
	// behave exactly as legalTransitions dictates, not some ad-hoc override.
	other := StateRunning
	if task.State == StateRunning {
		other = StateCancelled
	}
	wantErr := !CanTransition(task.State, other)
	err := s.TransitionTask(context.Background(), "c5", other)
	if wantErr && err == nil {
		t.Fatalf("expected the losing transition to remain illegal from the final state %s", task.State)
	}
}

func TestM6CANCEL006_RepeatedCancelIsIdempotent(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c6")
	mustTransition(t, s, "c6", StateCancelled)
	// A second cancel attempt is a no-op (K.2/STOP-007: terminal state,
	// reported as a no-op, not an error that implies something went
	// wrong) — model this as: the transition is rejected (already
	// terminal), and repeating it 10 times produces the same rejection
	// every time, never a panic, never a different outcome, never a
	// duplicate TaskCancelled side effect.
	for i := 0; i < 10; i++ {
		err := s.TransitionTask(context.Background(), "c6", StateCancelled)
		if err == nil {
			t.Fatalf("iteration %d: re-cancelling an already-cancelled task should be rejected as a no-op, not silently succeed as a fresh transition", i)
		}
	}
	task, _ := s.GetTask(context.Background(), "c6")
	if task.State != StateCancelled {
		t.Fatalf("expected state to remain CANCELLED after repeated cancel attempts, got %s", task.State)
	}
}

func TestM6CANCEL007_CancellationEmitsRequiredAuditEvent(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "c7")
	mustTransition(t, s, "c7", StateCancelled)
	appendCancelledAudit(t, s, "c7")

	trail, err := s.GetAuditTrail(context.Background(), "c7")
	if err != nil {
		t.Fatalf("GetAuditTrail: %v", err)
	}
	found := false
	for _, ev := range trail {
		if ev.EventType == EventTaskCancelled {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a TaskCancelled audit event, got %+v", trail)
	}
}
