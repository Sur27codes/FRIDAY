package store

import (
	"context"
	"path/filepath"
	"testing"
)

func newTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s, path
}

func mustCreateTask(t *testing.T, s *Store, taskID string) Task {
	t.Helper()
	task := Task{
		TaskID: taskID, CorrelationID: "corr-" + taskID, Actor: "user.owner",
		CapabilityID: "system.get_status", IRID: "ir-" + taskID, IdempotencyKey: "idem-" + taskID,
	}
	if err := s.CreateTask(context.Background(), task); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	return task
}

func mustTransition(t *testing.T, s *Store, taskID string, to TaskState) {
	t.Helper()
	if err := s.TransitionTask(context.Background(), taskID, to); err != nil {
		t.Fatalf("TransitionTask(%s, %s): %v", taskID, to, err)
	}
}
