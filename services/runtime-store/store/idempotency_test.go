package store

import (
	"context"
	"sync"
	"testing"
)

func TestM6IDEM001_SameKeySameDigest_ReturnsExistingRecord(t *testing.T) {
	s, _ := newTestStore(t)
	rec1, created1, err := s.RegisterIdempotency(context.Background(), "key1", "task1", "workspace.create_note", "digestA")
	if err != nil {
		t.Fatalf("first register: %v", err)
	}
	if !created1 {
		t.Fatalf("expected the first registration to report created=true")
	}
	rec2, created2, err := s.RegisterIdempotency(context.Background(), "key1", "task1", "workspace.create_note", "digestA")
	if err != nil {
		t.Fatalf("second register (same key+digest): %v", err)
	}
	if created2 {
		t.Fatalf("expected the second registration to report created=false (existing record)")
	}
	if rec1.IdempotencyKey != rec2.IdempotencyKey || rec1.TaskID != rec2.TaskID {
		t.Fatalf("expected identical existing record, got %+v vs %+v", rec1, rec2)
	}
}

func TestM6IDEM002_SameKeyDifferentDigest_Rejected(t *testing.T) {
	s, _ := newTestStore(t)
	if _, _, err := s.RegisterIdempotency(context.Background(), "key2", "task1", "workspace.create_note", "digestA"); err != nil {
		t.Fatalf("first register: %v", err)
	}
	_, _, err := s.RegisterIdempotency(context.Background(), "key2", "task2", "workspace.create_note", "digestB")
	if err == nil {
		t.Fatalf("expected IDEMPOTENCY_MISMATCH for a different digest under the same key")
	}
	se, ok := err.(*StoreError)
	if !ok || se.Code != ErrIdempotencyMismatch {
		t.Fatalf("expected IDEMPOTENCY_MISMATCH, got %v", err)
	}
}

func TestM6IDEM002b_SameKeyDifferentCapability_Rejected(t *testing.T) {
	s, _ := newTestStore(t)
	if _, _, err := s.RegisterIdempotency(context.Background(), "key2b", "task1", "system.get_status", "digestA"); err != nil {
		t.Fatalf("first register: %v", err)
	}
	_, _, err := s.RegisterIdempotency(context.Background(), "key2b", "task2", "workspace.create_note", "digestA")
	if err == nil {
		t.Fatalf("expected IDEMPOTENCY_MISMATCH for a different capability under the same key")
	}
}

func TestM6IDEM003_IdempotencySurvivesStoreReopen(t *testing.T) {
	s, path := newTestStore(t)
	if _, _, err := s.RegisterIdempotency(context.Background(), "key3", "task1", "workspace.create_note", "digestA"); err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := s.CompleteIdempotency(context.Background(), "key3"); err != nil {
		t.Fatalf("complete: %v", err)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	rec, err := reopened.GetIdempotency(context.Background(), "key3")
	if err != nil {
		t.Fatalf("GetIdempotency after reopen: %v", err)
	}
	if rec.Status != IdempotencyCompleted {
		t.Fatalf("expected COMPLETED status to survive reopen, got %s", rec.Status)
	}
	if rec.CompletedAt == nil {
		t.Fatalf("expected completed_at to survive reopen")
	}
}

func TestM6IDEM004_ConcurrentDuplicateRegistration_Deterministic(t *testing.T) {
	s, _ := newTestStore(t)
	const n = 8
	var wg sync.WaitGroup
	createdCount := make(chan bool, n)
	errCount := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, created, err := s.RegisterIdempotency(context.Background(), "key4", "task1", "workspace.create_note", "digestA")
			createdCount <- created
			errCount <- err
		}()
	}
	wg.Wait()
	close(createdCount)
	close(errCount)

	trueCount := 0
	for c := range createdCount {
		if c {
			trueCount++
		}
	}
	for err := range errCount {
		if err != nil {
			t.Fatalf("expected all concurrent same-key-same-digest registrations to succeed deterministically, got error: %v", err)
		}
	}
	if trueCount != 1 {
		t.Fatalf("expected exactly one goroutine to report created=true, got %d", trueCount)
	}
}

// M6-IDEM-005: a successful create_note task cannot be blindly duplicated
// after restart — modeled here as: the idempotency record for a
// COMPLETED create_note operation, once reopened, still rejects a
// same-key-different-arguments attempt (proving restart doesn't reset
// the mismatch guard), and a same-key-same-arguments attempt after
// restart still returns the existing (not a fresh) record.
func TestM6IDEM005_CompletedCreateNoteNotBlindlyDuplicatedAfterRestart(t *testing.T) {
	s, path := newTestStore(t)
	if _, _, err := s.RegisterIdempotency(context.Background(), "key5", "task1", "workspace.create_note", "digestA"); err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := s.CompleteIdempotency(context.Background(), "key5"); err != nil {
		t.Fatalf("complete: %v", err)
	}
	s.Close()

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	// Same key, same arguments -> existing record, not a fresh duplicate.
	_, created, err := reopened.RegisterIdempotency(context.Background(), "key5", "task2", "workspace.create_note", "digestA")
	if err != nil {
		t.Fatalf("re-register same key/digest after restart: %v", err)
	}
	if created {
		t.Fatalf("expected the existing COMPLETED record to be returned, not a fresh one, after restart")
	}

	// Same key, different arguments -> still rejected after restart.
	_, _, err = reopened.RegisterIdempotency(context.Background(), "key5", "task3", "workspace.create_note", "digestDIFFERENT")
	if err == nil {
		t.Fatalf("expected IDEMPOTENCY_MISMATCH to still be enforced after restart")
	}
}

// P2-M4R: reproduces the exact real production bug directly at the
// store layer — RegisterIdempotency succeeds (PENDING row written), but
// the caller's CreateTask never runs (e.g. it failed validation, exactly
// as orchestrator.go's CreateTask does when CorrelationID is empty), so
// no row for that task_id is ever written to `tasks`. Before the P2-M4R
// fix, this row was permanently stuck: RepairOrphanedIdempotencyRecords
// is the mechanism that clears it.
func TestP2M4R_RepairOrphanedIdempotencyRecords_ClearsOnlyTrueOrphans(t *testing.T) {
	s, _ := newTestStore(t)
	ctx := context.Background()

	// A genuine, completed task+idempotency pair — must survive repair.
	if _, _, err := s.RegisterIdempotency(ctx, "key-real", "task-real", "system.get_status", "digestA"); err != nil {
		t.Fatalf("register real: %v", err)
	}
	if err := s.CreateTask(ctx, Task{
		TaskID: "task-real", CorrelationID: "corr-real", Actor: "user.owner",
		CapabilityID: "system.get_status", IRID: "ir-real", IdempotencyKey: "key-real",
	}); err != nil {
		t.Fatalf("create real task: %v", err)
	}
	if err := s.CompleteIdempotency(ctx, "key-real"); err != nil {
		t.Fatalf("complete real: %v", err)
	}

	// A still-genuinely-pending task (task row DOES exist, just not
	// finished yet) — must ALSO survive repair; only a MISSING task row
	// makes a PENDING record an orphan.
	if _, _, err := s.RegisterIdempotency(ctx, "key-inflight", "task-inflight", "system.get_status", "digestB"); err != nil {
		t.Fatalf("register inflight: %v", err)
	}
	if err := s.CreateTask(ctx, Task{
		TaskID: "task-inflight", CorrelationID: "corr-inflight", Actor: "user.owner",
		CapabilityID: "system.get_status", IRID: "ir-inflight", IdempotencyKey: "key-inflight",
	}); err != nil {
		t.Fatalf("create inflight task: %v", err)
	}
	// Deliberately NOT completed — simulates a task genuinely still running.

	// The actual orphan: RegisterIdempotency succeeded, but CreateTask
	// was never even attempted (or failed) — no `tasks` row exists for
	// "task-orphan" at all.
	if _, _, err := s.RegisterIdempotency(ctx, "key-orphan", "task-orphan", "system.get_status", "digestC"); err != nil {
		t.Fatalf("register orphan: %v", err)
	}

	repaired, err := s.RepairOrphanedIdempotencyRecords(ctx)
	if err != nil {
		t.Fatalf("repair: %v", err)
	}
	if repaired != 1 {
		t.Fatalf("expected exactly 1 orphaned record repaired, got %d", repaired)
	}

	if _, err := s.GetIdempotency(ctx, "key-real"); err != nil {
		t.Fatalf("real completed record must survive repair: %v", err)
	}
	if _, err := s.GetIdempotency(ctx, "key-inflight"); err != nil {
		t.Fatalf("genuinely in-flight record (task row exists) must survive repair: %v", err)
	}
	if _, err := s.GetIdempotency(ctx, "key-orphan"); err == nil {
		t.Fatalf("orphaned record (no task row) must be removed by repair")
	}

	// After repair, the same idempotency key can be registered fresh —
	// proving a repaired record no longer permanently blocks new requests
	// for the same capability+arguments (the actual real-world symptom:
	// every later "check system status" request returning DUPLICATE_REQUEST
	// forever).
	_, created, err := s.RegisterIdempotency(ctx, "key-orphan", "task-orphan-retry", "system.get_status", "digestC")
	if err != nil {
		t.Fatalf("re-register after repair: %v", err)
	}
	if !created {
		t.Fatalf("expected a fresh registration after the orphan was repaired, not a duplicate")
	}
}
