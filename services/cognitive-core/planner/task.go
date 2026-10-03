// Package planner implements the smallest Phase-1 planner: a single
// ValidatedIR always produces, at most, a one-step plan naming exactly the
// capability the IR already named (M5 brief §15). This package builds no
// general DAG engine, no multi-agent planning, and no loops/branching/
// parallel execution — Phase-1's two approved capabilities each require
// exactly one action, so a one-node plan is structurally sufficient, and
// nothing here is designed to need more once M6/M7 exist (the Plan/Task
// shape itself already generalizes to a real DAG later without a
// breaking change: Steps is a slice, Dependencies exists per-step, even
// though Phase 1 only ever populates one empty-dependency step).
//
// Task states implemented here are exactly the M5-relevant prefix of the
// K.2 state machine (docs/JK-friday-ir-and-runtime-architecture.md §K.2):
// CREATED -> VALIDATED -> PLANNED. RUNNING/VERIFYING/SUCCEEDED and the
// rest of K.2 belong to the not-yet-built Runtime (M6/M7) — this package
// does not claim, simulate, or partially implement them.
package planner

// TaskState mirrors the CREATED/VALIDATED/PLANNED prefix of K.2's state
// machine exactly — same names, so a future Runtime package can adopt
// this type (or a superset of it) without a translation layer.
type TaskState string

const (
	TaskCreated   TaskState = "CREATED"
	TaskValidated TaskState = "VALIDATED"
	TaskPlanned   TaskState = "PLANNED"
	TaskCancelled TaskState = "CANCELLED"
)

// Step is one planned action. Dependencies is always empty in Phase 1
// (single-step plans only, M5 brief §15) but exists now so a future
// multi-step plan does not require a breaking type change.
type Step struct {
	CapabilityID string
	Dependencies []string
}

// Plan is the Planner's output (M5 brief §15). Planner authority ends
// here: nothing in this package or type ever grants execution authority
// — see planner.go's package-level authority-boundary note.
type Plan struct {
	TaskID string
	IRID   string
	Goal   string
	Steps  []Step
	State  TaskState
}
