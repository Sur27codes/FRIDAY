package store

import (
	"context"
	"testing"
)

func TestM6STATE001_CreatedToValidated_Allowed(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t1")
	mustTransition(t, s, "t1", StateValidated)
	task, err := s.GetTask(context.Background(), "t1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateValidated {
		t.Fatalf("expected VALIDATED, got %s", task.State)
	}
}

func TestM6STATE002_ValidatedToPlanned_Allowed(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t2")
	mustTransition(t, s, "t2", StateValidated)
	mustTransition(t, s, "t2", StatePlanned)
}

func TestM6STATE003_PlannedToAwaitingAuthorization_Allowed(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t3")
	mustTransition(t, s, "t3", StateValidated)
	mustTransition(t, s, "t3", StatePlanned)
	mustTransition(t, s, "t3", StateAwaitingAuthorization)
}

func TestM6STATE004_IllegalTransitionRejected(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t4")
	// CREATED -> RUNNING skips every intermediate state.
	err := s.TransitionTask(context.Background(), "t4", StateRunning)
	if err == nil {
		t.Fatalf("expected rejection")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrInvalidStateTransition {
		t.Fatalf("expected INVALID_STATE_TRANSITION, got %v", err)
	}
}

func TestM6STATE005_TerminalSucceededCannotReturnToRunning(t *testing.T) {
	s, _ := newTestStore(t)
	taskID := "t5"
	mustCreateTask(t, s, taskID)
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning, StateVerifying, StateSucceeded} {
		mustTransition(t, s, taskID, st)
	}
	err := s.TransitionTask(context.Background(), taskID, StateRunning)
	if err == nil {
		t.Fatalf("expected SUCCEEDED -> RUNNING to be rejected")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrInvalidStateTransition {
		t.Fatalf("expected INVALID_STATE_TRANSITION, got %v", err)
	}
}

func TestM6STATE006_CancelledCannotTransitionToRunning(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t6")
	mustTransition(t, s, "t6", StateCancelled)
	err := s.TransitionTask(context.Background(), "t6", StateRunning)
	if err == nil {
		t.Fatalf("expected CANCELLED -> RUNNING to be rejected")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrInvalidStateTransition {
		t.Fatalf("expected INVALID_STATE_TRANSITION, got %v", err)
	}
}

func TestM6STATE007_TransitionSurvivesStoreReopen(t *testing.T) {
	s, path := newTestStore(t)
	mustCreateTask(t, s, "t7")
	mustTransition(t, s, "t7", StateValidated)
	mustTransition(t, s, "t7", StatePlanned)
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	task, err := reopened.GetTask(context.Background(), "t7")
	if err != nil {
		t.Fatalf("GetTask after reopen: %v", err)
	}
	if task.State != StatePlanned {
		t.Fatalf("expected PLANNED to survive reopen, got %s", task.State)
	}
}

func TestM6STATE008_ConcurrentConflictingTransitions_OnlyOneSucceeds(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t8")
	mustTransition(t, s, "t8", StateValidated)
	mustTransition(t, s, "t8", StatePlanned)
	mustTransition(t, s, "t8", StateAwaitingAuthorization)
	mustTransition(t, s, "t8", StateAuthorized)
	mustTransition(t, s, "t8", StateRunning)
	// Two goroutines both attempt RUNNING -> VERIFYING concurrently
	// (simulating a duplicate completion signal) — only one may succeed;
	// the second must see the state has already moved and be rejected.
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			results <- s.TransitionTask(context.Background(), "t8", StateVerifying)
		}()
	}
	var successes, failures int
	for i := 0; i < 2; i++ {
		if err := <-results; err == nil {
			successes++
		} else {
			failures++
		}
	}
	if successes != 1 || failures != 1 {
		t.Fatalf("expected exactly 1 success and 1 failure, got %d successes, %d failures", successes, failures)
	}
	task, _ := s.GetTask(context.Background(), "t8")
	if task.State != StateVerifying {
		t.Fatalf("expected final state VERIFYING, got %s", task.State)
	}
}

func TestM6STATE009_CapabilityCompletionDoesNotDirectlyMarkSucceeded(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t9")
	mustTransition(t, s, "t9", StateValidated)
	mustTransition(t, s, "t9", StatePlanned)
	mustTransition(t, s, "t9", StateAwaitingAuthorization)
	mustTransition(t, s, "t9", StateAuthorized)
	mustTransition(t, s, "t9", StateRunning)
	// RUNNING -> SUCCEEDED, skipping VERIFYING entirely, must be illegal —
	// this is the durable form of "EXECUTED does not equal SUCCEEDED"
	// (M6 core invariant 3).
	err := s.TransitionTask(context.Background(), "t9", StateSucceeded)
	if err == nil {
		t.Fatalf("expected RUNNING -> SUCCEEDED (skipping VERIFYING) to be rejected")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrInvalidStateTransition {
		t.Fatalf("expected INVALID_STATE_TRANSITION, got %v", err)
	}
}

func TestM6STATE010_VerificationFailureDoesNotProduceSucceeded(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "t10")
	for _, st := range []TaskState{StateValidated, StatePlanned, StateAwaitingAuthorization, StateAuthorized, StateRunning} {
		mustTransition(t, s, "t10", st)
	}
	mustTransition(t, s, "t10", StateVerifying)
	mustTransition(t, s, "t10", StateFailed)
	task, err := s.GetTask(context.Background(), "t10")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateFailed {
		t.Fatalf("expected FAILED, got %s", task.State)
	}
	if task.State == StateSucceeded {
		t.Fatalf("a failed verification must never leave the task SUCCEEDED")
	}
}

// Additional structural coverage: every terminal state has zero legal
// outgoing transitions (the general form of STATE-005/006, checked for
// all four terminal states at once).
func TestTerminalStatesHaveNoOutgoingTransitions(t *testing.T) {
	for _, term := range []TaskState{StateSucceeded, StateCancelled, StateCompensated, StateRequiresManualReview} {
		if !term.Terminal() {
			t.Fatalf("%s should be reported as Terminal()", term)
		}
		for _, target := range []TaskState{StateCreated, StateValidated, StatePlanned, StateRunning, StateVerifying, StateFailed} {
			if CanTransition(term, target) {
				t.Fatalf("terminal state %s must have no legal transition to %s", term, target)
			}
		}
	}
}

func TestM7_CreatedToFailed_Allowed(t *testing.T) {
	s, _ := newTestStore(t)
	mustCreateTask(t, s, "cf1")
	mustTransition(t, s, "cf1", StateFailed)
	task, err := s.GetTask(context.Background(), "cf1")
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if task.State != StateFailed {
		t.Fatalf("expected FAILED, got %s", task.State)
	}
}

func TestFailedIsNotTerminal_RetryAndCompensationRemainReachable(t *testing.T) {
	if StateFailed.Terminal() {
		t.Fatalf("FAILED must not be reported as Terminal() — K.6 retry and compensation remain legal from it")
	}
	if !CanTransition(StateFailed, StateAwaitingAuthorization) {
		t.Fatalf("FAILED -> AWAITING_AUTHORIZATION (K.6 retry) must be legal")
	}
	if !CanTransition(StateFailed, StateCompensating) {
		t.Fatalf("FAILED -> COMPENSATING must be legal")
	}
}
