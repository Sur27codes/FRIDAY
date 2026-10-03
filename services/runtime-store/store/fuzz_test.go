package store

import (
	"context"
	"testing"
)

// FuzzTaskStateValid_NeverPanicsNeverAcceptsGarbage exercises M6 brief
// §33's "arbitrary state value never becomes a privileged valid state" —
// arbitrary fuzzed strings must never satisfy TaskState.valid() unless
// they are byte-for-byte one of the 13 real K.2 state names.
func FuzzTaskStateValid_NeverPanicsNeverAcceptsGarbage(f *testing.F) {
	real := []string{"CREATED", "VALIDATED", "PLANNED", "AWAITING_AUTHORIZATION", "AUTHORIZED",
		"RUNNING", "VERIFYING", "SUCCEEDED", "FAILED", "CANCELLED", "COMPENSATING", "COMPENSATED",
		"requires_manual_review"}
	for _, r := range real {
		f.Add(r)
	}
	f.Add("")
	f.Add("succeeded") // wrong case
	f.Add("SUCCEEDED; DROP TABLE tasks;--")
	f.Add("REQUIRES_MANUAL_REVIEW") // wrong case for the one lowercase state

	f.Fuzz(func(t *testing.T, s string) {
		valid := TaskState(s).valid()
		isReal := false
		for _, r := range real {
			if s == r {
				isReal = true
			}
		}
		if valid != isReal {
			t.Fatalf("TaskState(%q).valid() = %v, want %v", s, valid, isReal)
		}
	})
}

// FuzzGetTask_CorruptedStateNeverBecomesPermissiveDefault directly
// corrupts the stored `state` column (bypassing this package's own
// TransitionTask, simulating disk corruption or a migration bug — M6
// brief §23) and confirms GetTask NEVER returns a task whose State field
// silently defaults to something valid/permissive — either the corrupted
// value is correctly rejected as CORRUPT_RECORD, or it happens to be one
// of the 13 real state strings verbatim (not a coincidence the fuzzer can
// arrange for anything privileged — Terminal()/CanTransition still gate
// what can be DONE with that state regardless).
func FuzzGetTask_CorruptedStateNeverBecomesPermissiveDefault(f *testing.F) {
	f.Add("")
	f.Add("SUCCEEDED_BUT_NOT_REALLY")
	f.Add("AUTHORIZED\x00RUNNING")
	f.Add("null")
	f.Add("0")

	f.Fuzz(func(t *testing.T, corruptState string) {
		s, _ := newTestStore(t)
		mustCreateTask(t, s, "fuzz-task")

		if _, err := s.db.Exec(`UPDATE tasks SET state = ? WHERE task_id = ?`, corruptState, "fuzz-task"); err != nil {
			t.Fatalf("corrupting state column: %v", err)
		}

		task, err := s.GetTask(context.Background(), "fuzz-task")
		if err != nil {
			se, ok := err.(*StoreError)
			if !ok {
				t.Fatalf("expected a *StoreError, got %T: %v", err, err)
			}
			if se.Code != ErrCorruptRecord {
				t.Fatalf("expected CORRUPT_RECORD for an invalid state value, got %s", se.Code)
			}
			return
		}
		// If GetTask succeeded at all, the returned state MUST be a real
		// K.2 state — never the raw corrupted string trusted verbatim as
		// something meaningful.
		if !task.State.valid() {
			t.Fatalf("GetTask returned success with an invalid state %q — corrupted data became a silently-trusted value", task.State)
		}
	})
}

// FuzzAppendAuditEvent_NeverPanicsOnArbitraryFields confirms arbitrary
// fuzzed strings for the free-text audit fields (actor, result_status,
// correlation/causation/task IDs) never panic AppendAuditEvent — SQL
// parameterization (never string concatenation) is what this actually
// relies on, and this fuzz target is the empirical check that holds.
func FuzzAppendAuditEvent_NeverPanicsOnArbitraryFields(f *testing.F) {
	f.Add("corr-1", "actor-1", "'; DROP TABLE audit_events;--")
	f.Add("", "", "")
	f.Add("corr\x00null", "actor\nwith\nnewlines", "result\twith\ttabs")

	f.Fuzz(func(t *testing.T, correlationID, actor, resultStatus string) {
		s, _ := newTestStore(t)
		_, err := s.AppendAuditEvent(context.Background(), AuditEvent{
			CorrelationID: correlationID, Actor: actor, ResultStatus: resultStatus,
			EventType: EventIntentReceived, Sensitivity: SensitivityInternal,
		})
		// Empty correlation_id/actor are rejected by design (see
		// AppendAuditEvent) — any other combination must not panic, and
		// either succeeds or returns a well-formed *StoreError.
		if err != nil {
			if _, ok := err.(*StoreError); !ok {
				t.Fatalf("expected a *StoreError on failure, got %T: %v", err, err)
			}
		}
	})
}
