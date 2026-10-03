package pipeline

import "fmt"

// Stage names which of the three pipeline steps produced a failure.
type Stage string

const (
	StageCompile  Stage = "COMPILE"
	StageValidate Stage = "VALIDATE"
	StagePlan     Stage = "PLAN"
)

// ErrorCode is the M5 brief §25 error taxonomy, in full — this is the one
// place all nine categories are unified into a single closed set,
// regardless of which sub-package (intentcompiler, ir, planner) actually
// produced the underlying failure.
type ErrorCode string

const (
	ErrInvalidTextRequest  ErrorCode = "INVALID_TEXT_REQUEST"
	ErrUnsupportedIntent   ErrorCode = "UNSUPPORTED_INTENT"
	ErrAmbiguousIntent     ErrorCode = "AMBIGUOUS_INTENT"
	ErrMissingArgument     ErrorCode = "MISSING_ARGUMENT"
	ErrInvalidArgument     ErrorCode = "INVALID_ARGUMENT"
	ErrIRCompilationFailed ErrorCode = "IR_COMPILATION_FAILED"
	ErrIRValidationFailed  ErrorCode = "IR_VALIDATION_FAILED"
	ErrPlanFailed          ErrorCode = "PLAN_FAILED"
	ErrCancelled           ErrorCode = "CANCELLED"
)

// PipelineError never carries raw user text or raw argument values in
// Message beyond what the underlying stage error already scoped to field
// names/category reasons (mirroring ir.ValidationError's and
// intentcompiler.CompileError's discipline) — safe to surface to a
// caller/UI without a redaction pass.
type PipelineError struct {
	Stage   Stage
	Code    ErrorCode
	Field   string
	Message string
}

func (e *PipelineError) Error() string {
	if e.Field != "" {
		return fmt.Sprintf("[%s/%s] field=%q: %s", e.Stage, e.Code, e.Field, e.Message)
	}
	return fmt.Sprintf("[%s/%s] %s", e.Stage, e.Code, e.Message)
}
