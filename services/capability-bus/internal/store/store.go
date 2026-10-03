// Package store provides the minimal, explicitly non-persistent stand-ins
// M3 needs to prove the Execution Envelope's 11-check validation order
// (PHASE-1-EXECUTION-SPEC.md §1.2), specifically checks 2 (task state)
// and 4 (re-fetching canonical arguments from the immutable IR store by
// ir_id rather than trusting the envelope).
//
// Real, durable versions of both (a Postgres-backed IR document store and
// a Postgres-backed task state machine) are M6 scope. M3 does NOT claim
// crash-safe or persistent behavior here — this package is in-memory
// only, exists to make the *validation logic* testable now, and must be
// replaced (not wrapped) at M6, not silently relied upon as if it were
// already durable. This is the M3-local limitation the M2/M3 idempotency
// brief items require disclosing rather than pretending is solved.
package store

import "sync"

// IRRecord is the minimal fact the Bus needs about a validated IR
// document: its canonical arguments (for digest re-derivation, check 4)
// and which capability it targets.
type IRRecord struct {
	CapabilityID string
	Arguments    map[string]interface{}
}

// IRStore is an in-memory, non-persistent stand-in for the immutable IR
// document store (O.4, M6). Safe for concurrent use.
type IRStore struct {
	mu      sync.RWMutex
	records map[string]IRRecord
}

func NewIRStore() *IRStore {
	return &IRStore{records: make(map[string]IRRecord)}
}

// Put records an IR document's canonical facts, simulating what would
// have happened when the (not-yet-built) Intent Compiler/Planner wrote
// the validated IR to durable storage.
func (s *IRStore) Put(irID string, rec IRRecord) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records[irID] = rec
}

// Get re-fetches the canonical facts for an ir_id — this is what
// PHASE-1-EXECUTION-SPEC.md §1.2 check 4 calls "re-fetched from the
// immutable IR store," never trusted from the caller-supplied envelope.
func (s *IRStore) Get(irID string) (IRRecord, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.records[irID]
	return rec, ok
}

// TaskState mirrors the subset of JK §K.2's state machine the Bus's
// envelope validation (check 2) and token validation (check 6f) need to
// observe.
type TaskState string

const (
	TaskAuthorized TaskState = "AUTHORIZED"
	TaskRunning    TaskState = "RUNNING"
	TaskCancelled  TaskState = "CANCELLED"
	TaskSucceeded  TaskState = "SUCCEEDED"
	TaskFailed     TaskState = "FAILED"
)

func (s TaskState) Terminal() bool {
	switch s {
	case TaskCancelled, TaskSucceeded, TaskFailed:
		return true
	}
	return false
}

// TaskStore is an in-memory, non-persistent stand-in for the Runtime's
// task state machine (JK §K.2, M6 for durable storage).
type TaskStore struct {
	mu     sync.RWMutex
	states map[string]TaskState
}

func NewTaskStore() *TaskStore {
	return &TaskStore{states: make(map[string]TaskState)}
}

func (s *TaskStore) Set(taskID string, state TaskState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.states[taskID] = state
}

func (s *TaskStore) Get(taskID string) (TaskState, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	st, ok := s.states[taskID]
	return st, ok
}
