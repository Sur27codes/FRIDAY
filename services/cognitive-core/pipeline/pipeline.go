// Package pipeline is the M5 orchestration layer: TextRequest -> Compile
// -> ir.Validate -> CreatePlan (M5 brief's target flow), stopping exactly
// there — it never calls the Policy Engine or Capability Bus, and holds
// no dependency on either module (see go.mod: this module module imports
// only friday/ir). This is the M5 equivalent of M3/M4's "in-process
// backdoor" search: production code in this package has exactly one path
// from TextRequest to a Plan, and that path always passes through
// ir.Validate — there is no second code path anywhere in this module that
// constructs an ir.ValidatedIR or a planner.Plan directly, skipping
// validation (M5 brief §14).
package pipeline

import (
	"friday/cognitive-core/intentcompiler"
	"friday/cognitive-core/planner"
	"friday/cognitive-core/textrequest"
	"friday/ir"
)

// Result carries whatever the pipeline managed to produce before it
// stopped (successfully at PLANNED, or with an error at an earlier
// stage). RawIR/ValidatedIR/Plan are nil unless that stage was actually
// reached and succeeded — never a partially-constructed or best-guess
// value.
type Result struct {
	RawIR       *ir.RawIR
	ValidatedIR *ir.ValidatedIR
	Plan        *planner.Plan
	State       planner.TaskState // "" if compilation itself never produced an IR document at all
}

// Run executes the full M5 flow for one TextRequest. taskID is supplied
// by the caller (the not-yet-built Runtime stands in as this milestone's
// test harness, matching M3/M4's DevSeed-style bootstrap pattern) rather
// than generated here, keeping Run a pure function of its inputs.
// cancelledBeforePlanning models M5 brief §18's two required cancellation
// checks (cancelled before planning, and cancelled after validation but
// before planning — both are the same check point in this single-step
// pipeline, since M5 has no intermediate suspend point between VALIDATED
// and PLANNED).
func Run(req textrequest.TextRequest, taskID string, cancelledBeforePlanning bool) (*Result, *PipelineError) {
	raw, cerr := intentcompiler.Compile(req)
	if cerr != nil {
		return &Result{}, compileErrToPipelineErr(cerr)
	}

	res := &Result{RawIR: &raw, State: planner.TaskCreated}

	validated, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		return res, validationErrToPipelineErr(verr)
	}
	res.ValidatedIR = validated
	res.State = planner.TaskValidated

	plan, perr := planner.CreatePlan(*validated, taskID, cancelledBeforePlanning)
	if perr != nil {
		if perr.Code == planner.ErrCancelled {
			res.State = planner.TaskCancelled
		}
		return res, planErrToPipelineErr(perr)
	}
	res.Plan = plan
	res.State = planner.TaskPlanned

	return res, nil
}

func compileErrToPipelineErr(e *intentcompiler.CompileError) *PipelineError {
	return &PipelineError{Stage: StageCompile, Code: ErrorCode(e.Code), Field: e.Field, Message: e.Message}
}

func validationErrToPipelineErr(e *ir.ValidationError) *PipelineError {
	return &PipelineError{
		Stage:   StageValidate,
		Code:    ErrIRValidationFailed,
		Field:   e.Field,
		Message: string(e.Stage) + "/" + string(e.Category) + ": " + e.Message,
	}
}

func planErrToPipelineErr(e *planner.PlanError) *PipelineError {
	return &PipelineError{Stage: StagePlan, Code: ErrorCode(e.Code), Message: e.Message}
}
