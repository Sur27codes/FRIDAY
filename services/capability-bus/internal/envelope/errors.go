package envelope

import "fmt"

// Category is the structured failure taxonomy for envelope/dispatch
// failures, per the M3 brief §13. Kept to exactly this list.
type Category string

const (
	CategoryUnknownCapability            Category = "UNKNOWN_CAPABILITY"
	CategoryInvalidExecutionEnvelope     Category = "INVALID_EXECUTION_ENVELOPE"
	CategoryAuthorizationMissing         Category = "AUTHORIZATION_MISSING"
	CategoryAuthorizationInvalid         Category = "AUTHORIZATION_INVALID"
	CategoryAuthorizationExpired         Category = "AUTHORIZATION_EXPIRED"
	CategoryAuthorizationScopeMismatch   Category = "AUTHORIZATION_SCOPE_MISMATCH"
	CategoryArgumentDigestMismatch       Category = "ARGUMENT_DIGEST_MISMATCH"
	CategoryPurposeMismatch              Category = "PURPOSE_MISMATCH"
	CategoryCapabilityInputInvalid       Category = "CAPABILITY_INPUT_INVALID"
	CategoryCapabilityExecutionFailed    Category = "CAPABILITY_EXECUTION_FAILED"
	CategoryCapabilityVerificationFailed Category = "CAPABILITY_VERIFICATION_FAILED"
	CategoryWorkspaceBoundaryViolation   Category = "WORKSPACE_BOUNDARY_VIOLATION"
	CategoryAlreadyExists                Category = "ALREADY_EXISTS"
	CategoryCancelled                    Category = "CANCELLED"
)

// DispatchError is the single structured error type this module returns.
// Detail must never contain signing secrets, raw token contents, full
// filesystem paths beyond what's needed to identify the problem, or
// private argument content (M3 brief §13's "must not expose" list).
type DispatchError struct {
	Check    string
	Category Category
	Detail   string
}

func (e *DispatchError) Error() string {
	return fmt.Sprintf("[%s/%s] %s", e.Check, e.Category, e.Detail)
}

func newErr(check string, cat Category, detail string) *DispatchError {
	return &DispatchError{Check: check, Category: cat, Detail: detail}
}
