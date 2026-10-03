// Package worldmodel implements the M8 closure milestone's minimal
// Phase-1 World Model (FR-WORLD-001; schema:
// docs/L-world-user-self-policy-models.md §L.2.1, "Schema (Phase 1
// minimal)": entity{id, type, attributes, last_observed, confidence,
// source}).
//
// This is deliberately NOT the future spatial/scene-graph World Model —
// no cameras, rooms, physical-object tracking, or probabilistic belief
// state (§L.2.2/§L.2.3, both explicitly later-tier). Phase 1's World
// Model represents exactly the operational entities named in the M8
// closure brief: the FRIDAY runtime itself, the Policy Engine, the
// Capability Bus, the approved workspace, the two registered
// capabilities, and the current task.
//
// Structural authority guarantee (M8 brief §8/WORLD-003/WORLD-006): this
// package exposes no function that accepts arbitrary caller-supplied
// entity state and stores it as authoritative. Snapshot is a pure,
// read-only PROJECTION computed fresh on every call from the same
// sources of truth the rest of the system already trusts (the durable
// task store, and a live health probe of the real Policy Engine/
// Capability Bus sockets) — there is no persistent World Model table
// this package writes to, so there is nothing for user text (which never
// reaches this package's API at all — no function here takes a raw_text
// or TextRequest parameter) to corrupt, and nothing here can be stale in
// a way that silently drifts from the real durable/live state, because
// it is never copied in the first place.
package worldmodel

import (
	"context"
	"time"

	"friday/runtime-store/store"
	"friday/runtime/wireclient"
)

type EntityType string

const (
	EntityService     EntityType = "service"
	EntityApplication EntityType = "application"
	EntityProject     EntityType = "project" // the approved workspace
	EntityPerson      EntityType = "person"  // the actor
)

// Source mirrors L.2.1's entity.source enum exactly — restricted here to
// the two values Phase 1 can honestly produce. `user_statement` is
// deliberately never used by this package: nothing here treats a user's
// claim about the world as authoritative fact (WORLD-003).
type Source string

const (
	SourceObservation Source = "observation" // this process's own live state or a live health probe
	SourceInference   Source = "inference"   // derived from a durable record this process itself wrote (e.g. task state)
)

// Entity mirrors L.2.1's schema exactly (id/type/attributes/
// last_observed/confidence/source).
type Entity struct {
	ID           string
	Type         EntityType
	Attributes   map[string]interface{}
	LastObserved time.Time
	Confidence   float64
	Source       Source
}

// Snapshot is the World Model's only read API: a fresh, point-in-time
// projection. Config identifies the static facts about THIS deployment
// (never user-suppliable — set once at daemon startup from CLI flags,
// the same values cmd/friday/main.go already uses to construct the
// Orchestrator).
type Config struct {
	WorkspaceRoot string
	PolicyClient  *wireclient.PolicyClient
	BusClient     *wireclient.BusClient
}

// Snapshot returns the current World Model view. taskID is optional
// ("" if there is no current task in scope, e.g. a query issued outside
// any request).
func Snapshot(ctx context.Context, cfg Config, st *store.Store, taskID string) []Entity {
	now := time.Now().UTC()
	entities := []Entity{
		{
			ID: "friday-runtime", Type: EntityService,
			Attributes:   map[string]interface{}{"role": "orchestrator"},
			LastObserved: now, Confidence: 1.0, Source: SourceObservation,
		},
		{
			ID: "capability.system.get_status", Type: EntityApplication,
			Attributes:   map[string]interface{}{"registered": true},
			LastObserved: now, Confidence: 1.0, Source: SourceObservation,
		},
		{
			ID: "capability.workspace.create_note", Type: EntityApplication,
			Attributes:   map[string]interface{}{"registered": true},
			LastObserved: now, Confidence: 1.0, Source: SourceObservation,
		},
		{
			ID: "approved-workspace", Type: EntityProject,
			Attributes:   map[string]interface{}{"root": cfg.WorkspaceRoot},
			LastObserved: now, Confidence: 1.0, Source: SourceObservation,
		},
	}

	entities = append(entities, healthEntity(ctx, "policy-engine", cfg.PolicyClient))
	entities = append(entities, healthEntity(ctx, "capability-bus", cfg.BusClient))

	if taskID != "" {
		if e, ok := taskEntity(ctx, st, taskID); ok {
			entities = append(entities, e)
		}
	}

	return entities
}

type healthChecker interface {
	Health(ctx context.Context) (bool, error)
}

func healthEntity(ctx context.Context, id string, checker healthChecker) Entity {
	now := time.Now().UTC()
	healthCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	alive, err := checker.Health(healthCtx)
	if err != nil || !alive {
		// Fail closed on the World Model's own honesty guarantee too:
		// an unreachable/erroring process is represented as observed-down,
		// never silently omitted or assumed healthy (WORLD-005 — unknown
		// state remains represented as such, never fabricated as good).
		return Entity{
			ID: id, Type: EntityService, Attributes: map[string]interface{}{"healthy": false},
			LastObserved: now, Confidence: 1.0, Source: SourceObservation,
		}
	}
	return Entity{
		ID: id, Type: EntityService, Attributes: map[string]interface{}{"healthy": true},
		LastObserved: now, Confidence: 1.0, Source: SourceObservation,
	}
}

func taskEntity(ctx context.Context, st *store.Store, taskID string) (Entity, bool) {
	task, err := st.GetTask(ctx, taskID)
	if err != nil {
		return Entity{}, false
	}
	return Entity{
		ID: task.TaskID, Type: EntityApplication,
		Attributes: map[string]interface{}{
			"capability_id": task.CapabilityID,
			"state":         string(task.State), // durable runtime truth, never a caller-supplied guess (WORLD-004)
		},
		LastObserved: task.UpdatedAt, Confidence: 1.0, Source: SourceInference,
	}, true
}
