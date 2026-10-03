package planner

import (
	"reflect"
	"testing"

	"friday/ir"
)

func validatedIR(t *testing.T, capabilityID string, args map[string]interface{}) ir.ValidatedIR {
	t.Helper()
	schema := ir.Phase1Registry()[capabilityID]
	digest, err := ir.ArgumentsDigest(args)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	raw := ir.RawIR{
		IRVersion: ir.SupportedSchemaVersion, IRID: "ir-1", CorrelationID: "corr-1",
		Source:       ir.Source{Actor: "user.owner", InputModality: "text"},
		Goal:         ir.Goal{Type: capabilityID, Description: "test"},
		Content:      ir.Content{Parameters: args},
		Effects:      ir.Effects{Reversible: schema.RegisteredReversible},
		Risk:         ir.Risk{Level: schema.RegisteredRiskLevel},
		Cancellation: ir.Cancellation{Cancellable: true, CancellationEffect: ir.CancellationNoneYetStarted},
		Idempotency:  ir.Idempotency{IdempotencyKey: "idem-1:" + digest},
		Verification: ir.Verification{Required: true, Method: "test_method"},
		Provenance:   ir.Provenance{CompiledBy: "test"},
	}
	validated, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		t.Fatalf("setup: unexpected validation error: %v", verr)
	}
	return *validated
}

func TestPlanner_GetStatus_OneStepPlan(t *testing.T) {
	v := validatedIR(t, "system.get_status", map[string]interface{}{})
	plan, perr := CreatePlan(v, "task-1", false)
	if perr != nil {
		t.Fatalf("unexpected error: %v", perr)
	}
	if plan.State != TaskPlanned {
		t.Fatalf("expected TaskPlanned, got %s", plan.State)
	}
	if len(plan.Steps) != 1 || plan.Steps[0].CapabilityID != "system.get_status" {
		t.Fatalf("expected one step for system.get_status, got %+v", plan.Steps)
	}
	if len(plan.Steps[0].Dependencies) != 0 {
		t.Fatalf("expected no dependencies in a Phase-1 single-step plan")
	}
}

func TestPlanner_CreateNote_OneStepPlan(t *testing.T) {
	v := validatedIR(t, "workspace.create_note", map[string]interface{}{"title": "x", "body": "y"})
	plan, perr := CreatePlan(v, "task-2", false)
	if perr != nil {
		t.Fatalf("unexpected error: %v", perr)
	}
	if len(plan.Steps) != 1 || plan.Steps[0].CapabilityID != "workspace.create_note" {
		t.Fatalf("expected one step for workspace.create_note, got %+v", plan.Steps)
	}
}

// M5 brief §18: cancelled after validation but before planning -> planning stops.
func TestPlanner_Cancelled_NoPlanProduced(t *testing.T) {
	v := validatedIR(t, "system.get_status", map[string]interface{}{})
	plan, perr := CreatePlan(v, "task-3", true)
	if plan != nil {
		t.Fatalf("expected no plan when cancelled, got %+v", plan)
	}
	if perr == nil || perr.Code != ErrCancelled {
		t.Fatalf("expected CANCELLED, got %+v", perr)
	}
}

// M5-SEC-011: the Planner cannot modify signed/security-sensitive
// capability contract fields — proven structurally: Plan and Step have no
// field for risk, AAL, verification, or filesystem scope at all. This
// test asserts the exact exported field set of both types so that any
// future accidental addition of such a field fails loudly here rather
// than silently widening the Planner's authority.
func TestM5SEC011_PlanAndStepHaveNoSecurityFields(t *testing.T) {
	wantPlanFields := map[string]bool{"TaskID": true, "IRID": true, "Goal": true, "Steps": true, "State": true}
	planType := reflect.TypeOf(Plan{})
	if planType.NumField() != len(wantPlanFields) {
		t.Fatalf("Plan has %d fields, want exactly %d: %v", planType.NumField(), len(wantPlanFields), wantPlanFields)
	}
	for i := 0; i < planType.NumField(); i++ {
		name := planType.Field(i).Name
		if !wantPlanFields[name] {
			t.Fatalf("Plan has unexpected field %q — Planner authority must not gain a new field here without deliberate review", name)
		}
	}

	wantStepFields := map[string]bool{"CapabilityID": true, "Dependencies": true}
	stepType := reflect.TypeOf(Step{})
	if stepType.NumField() != len(wantStepFields) {
		t.Fatalf("Step has %d fields, want exactly %d: %v", stepType.NumField(), len(wantStepFields), wantStepFields)
	}
	for i := 0; i < stepType.NumField(); i++ {
		name := stepType.Field(i).Name
		if !wantStepFields[name] {
			t.Fatalf("Step has unexpected field %q — Planner authority must not gain a new field here without deliberate review", name)
		}
	}
}

// M5-SEC-010 (structural half — see pipeline package for the integration-
// level confirmation): ir.Validate is the only way to construct an
// ir.ValidatedIR (its raw field is unexported to package ir), so this
// package cannot even compile a call to CreatePlan with a hand-built
// unregistered-capability ValidatedIR. approvedCapabilities in planner.go
// is therefore genuinely unreachable defense-in-depth, not the only
// guard — documented here rather than asserted by a runtime test that
// cannot actually be constructed.
func TestM5SEC010_NoConstructorForUnvalidatedIR_DocumentedNotAsserted(t *testing.T) {
	// Intentionally empty: this test exists to anchor the doc comment
	// above at a location `go test -v` reports, not to execute a runtime
	// check that Go's type system already makes impossible to set up.
}
