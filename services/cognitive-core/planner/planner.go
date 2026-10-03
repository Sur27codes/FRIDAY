package planner

import "friday/ir"

// approvedCapabilities is a redundant, explicit allow-list — defense in
// depth mirroring the established M3/M4 pattern of re-checking something
// an earlier layer already guaranteed (e.g. bus.go's dispatch switch
// default case). ir.ValidatedIR already guarantees goal.type is a
// registered Phase-1 capability (stage 2 of ir.Validate), so this check
// should be unreachable in practice; it exists so the Planner never
// silently trusts "the IR layer already checked this" as its ONLY line of
// defense against ever emitting a step for an unregistered capability
// (M5-SEC-010).
var approvedCapabilities = map[string]bool{
	"system.get_status":     true,
	"workspace.create_note": true,
}

// CreatePlan is the Planner's only entry point (M5 brief §15). It takes a
// ValidatedIR — never a RawIR; Go's type system makes it a compile error
// to pass unvalidated IR here, the same trust-transition discipline M2
// established (ir.ValidatedIR's only constructor is ir.Validate).
//
// Planner authority boundary (M5 brief §16): this function reads
// validated.Raw() fields to decide step ordering/dependencies/task
// metadata, and nothing else. It never authorizes execution, mints a
// token, or alters any security-relevant field (risk, minimum AAL,
// verification, filesystem scope) — those fields are not even present on
// Plan/Step; the Planner has no field to put a modified risk/AAL/
// verification value INTO, which is the type-system half of "cannot
// modify signed/security-sensitive capability contract fields"
// (M5-SEC-011). The only capability identifier the Planner ever writes
// into a Step comes verbatim from validated.Raw().Goal.Type, which
// ir.Validate already confirmed against the registry — the Planner
// introduces no new identifier of its own.
func CreatePlan(validated ir.ValidatedIR, taskID string, cancelled bool) (*Plan, *PlanError) {
	if cancelled {
		return nil, &PlanError{Code: ErrCancelled, Message: "task was cancelled before planning completed"}
	}

	raw := validated.Raw()
	capabilityID := raw.Goal.Type
	if !approvedCapabilities[capabilityID] {
		return nil, &PlanError{Code: ErrPlanFailed, Message: "validated IR names a capability outside the Planner's approved allow-list"}
	}

	return &Plan{
		TaskID: taskID,
		IRID:   raw.IRID,
		Goal:   raw.Goal.Description,
		Steps: []Step{
			{CapabilityID: capabilityID, Dependencies: nil},
		},
		State: TaskPlanned,
	}, nil
}
