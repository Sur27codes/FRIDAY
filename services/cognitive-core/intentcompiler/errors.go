package intentcompiler

import "fmt"

// ErrorCode is the Intent Compiler's structured error taxonomy (M5 brief
// §25). Kept to exactly this list, mirroring services/ir's closed-category
// discipline (errors.go) — no ad-hoc extra categories invented per-check.
type ErrorCode string

const (
	ErrInvalidTextRequest  ErrorCode = "INVALID_TEXT_REQUEST"
	ErrUnsupportedIntent   ErrorCode = "UNSUPPORTED_INTENT"
	ErrAmbiguousIntent     ErrorCode = "AMBIGUOUS_INTENT"
	ErrMissingArgument     ErrorCode = "MISSING_ARGUMENT"
	ErrInvalidArgument     ErrorCode = "INVALID_ARGUMENT"
	ErrIRCompilationFailed ErrorCode = "IR_COMPILATION_FAILED" // internal failure building RawIR, distinct from a classified rejection above
)

// CompileError is the single error type Compile returns. Message never
// echoes raw_text content back verbatim into a field name or reason string
// beyond what is necessary to name which structural piece was missing —
// mirroring services/ir's ValidationError discipline of never leaking raw
// argument content into error text.
type CompileError struct {
	Code    ErrorCode
	Field   string // optional: which structural piece (e.g. "title", "body")
	Message string
}

func (e *CompileError) Error() string {
	if e.Field != "" {
		return fmt.Sprintf("[%s] field=%q: %s", e.Code, e.Field, e.Message)
	}
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}
