// Package getstatus implements the system.get_status capability
// (PHASE-1-EXECUTION-SPEC.md §9, Capability 1). Deliberately narrow: it
// returns exactly the three documented fields (capability_status,
// resource_state, autonomy_state) and nothing else. It does NOT
// enumerate OS processes, inspect the filesystem, probe the network, or
// report Device Mesh/cloud status — none of that is part of the Phase-1
// Self Model, and none of it is added here "for completeness."
package getstatus

import "fmt"

type CapabilityStatusEntry struct {
	CapabilityID string
	Status       string // "available" | "degraded" | "unavailable"
	LastChecked  string // RFC3339
}

type ResourceState struct {
	CPU       string
	RAM       string
	CostToday string
	APIQuota  string
}

type AutonomyStateEntry struct {
	CapabilityID string
	Level        string // "L0".."L4"
}

// Snapshot is the deterministic output type — a plain struct, not a
// generic map, so what this capability can possibly return is fixed at
// compile time.
type Snapshot struct {
	CapabilityStatus []CapabilityStatusEntry
	ResourceState    ResourceState
	AutonomyState    []AutonomyStateEntry
}

// SelfModelSource is the minimal read interface this capability needs.
// The real Self Model store is M6 scope (persistence); this interface is
// the seam a durable implementation plugs into later without this
// capability's code changing. For M3, StaticSource below is the only
// implementation, and it is explicitly disclosed as a fixed stand-in, not
// a real operational snapshot.
type SelfModelSource interface {
	Snapshot() (Snapshot, error)
}

// StaticSource is an M3-local stand-in returning a fixed, deterministic
// snapshot reflecting exactly the two capabilities this Phase-1 registry
// contains — sufficient to prove the capability's dispatch and
// verification path end to end without a real Self Model store.
type StaticSource struct{}

func (StaticSource) Snapshot() (Snapshot, error) {
	return Snapshot{
		CapabilityStatus: []CapabilityStatusEntry{
			{CapabilityID: "system.get_status", Status: "available", LastChecked: "static"},
			{CapabilityID: "workspace.create_note", Status: "available", LastChecked: "static"},
		},
		ResourceState: ResourceState{CPU: "n/a", RAM: "n/a", CostToday: "0", APIQuota: "n/a"},
		AutonomyState: []AutonomyStateEntry{
			{CapabilityID: "system.get_status", Level: "L1"},
			{CapabilityID: "workspace.create_note", Level: "L1"},
		},
	}, nil
}

// Execute runs the capability. It performs no I/O beyond calling the
// injected source — no file, network, process, or shell access.
func Execute(source SelfModelSource) (Snapshot, error) {
	snap, err := source.Snapshot()
	if err != nil {
		return Snapshot{}, fmt.Errorf("reading self model snapshot: %w", err)
	}
	return snap, nil
}

// Verify implements this capability's declared verification_method
// (schema_conformance_against_live_self_model, registry.go): it
// re-reads the same source and confirms the previously-returned snapshot
// still matches — i.e., "verify" is a real re-check against the
// underlying store, not a no-op, per §387.
func Verify(source SelfModelSource, result Snapshot) (bool, error) {
	current, err := source.Snapshot()
	if err != nil {
		return false, fmt.Errorf("re-reading self model snapshot for verification: %w", err)
	}
	return snapshotsEqual(current, result), nil
}

func snapshotsEqual(a, b Snapshot) bool {
	if len(a.CapabilityStatus) != len(b.CapabilityStatus) || len(a.AutonomyState) != len(b.AutonomyState) {
		return false
	}
	for i := range a.CapabilityStatus {
		if a.CapabilityStatus[i] != b.CapabilityStatus[i] {
			return false
		}
	}
	for i := range a.AutonomyState {
		if a.AutonomyState[i] != b.AutonomyState[i] {
			return false
		}
	}
	return a.ResourceState == b.ResourceState
}
