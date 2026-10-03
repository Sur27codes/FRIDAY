package ir

import "fmt"

// ErrorCategory is the structured validation-failure taxonomy requested
// for M2. Kept to exactly this list (no ad-hoc extra categories invented
// per-check) so error handling downstream can switch on a small, closed
// set.
type ErrorCategory string

const (
	CategoryInvalidSchema               ErrorCategory = "INVALID_SCHEMA"
	CategoryMissingField                ErrorCategory = "MISSING_FIELD"
	CategoryInvalidField                ErrorCategory = "INVALID_FIELD"
	CategoryUnknownCapability           ErrorCategory = "UNKNOWN_CAPABILITY"
	CategoryCapabilitySchemaMismatch    ErrorCategory = "CAPABILITY_SCHEMA_MISMATCH"
	CategorySecurityConstraintViolation ErrorCategory = "SECURITY_CONSTRAINT_VIOLATION"
	CategoryRiskMismatch                ErrorCategory = "RISK_MISMATCH"
	CategoryAuthRequirementMismatch     ErrorCategory = "AUTH_REQUIREMENT_MISMATCH"
	CategoryVerificationContractInvalid ErrorCategory = "VERIFICATION_CONTRACT_INVALID"
	CategoryIdempotencyInvalid          ErrorCategory = "IDEMPOTENCY_INVALID"
	CategoryCancellationInvalid         ErrorCategory = "CANCELLATION_INVALID"
)

// Stage identifies which of the 4 validation stages (J.2.1) produced the
// failure.
type Stage string

const (
	StageSyntax                  Stage = "SYNTAX_VALIDATION"
	StageSemantic                Stage = "SEMANTIC_VALIDATION"
	StageSecurityConsistency     Stage = "SECURITY_CONSISTENCY_CHECK" // J.2.1 stage 3, see validate.go's design note
	StageCapabilityCompatibility Stage = "CAPABILITY_COMPATIBILITY_CHECK"
)

// ValidationError is the single error type this package returns. Field is
// the dotted-path name of the offending field, kept generic (not the raw
// value) so error messages never leak potentially sensitive argument
// content (item 13's "do not leak secrets or sensitive payloads in error
// messages" — Message below must never interpolate a raw argument value,
// only field names and category-level reasons).
type ValidationError struct {
	Stage    Stage
	Category ErrorCategory
	Field    string
	Message  string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("[%s/%s] field=%q: %s", e.Stage, e.Category, e.Field, e.Message)
}

func newErr(stage Stage, cat ErrorCategory, field, msg string) *ValidationError {
	return &ValidationError{Stage: stage, Category: cat, Field: field, Message: msg}
}
