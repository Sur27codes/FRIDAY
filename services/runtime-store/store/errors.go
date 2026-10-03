package store

import "fmt"

// ErrorCode is M6 brief §26's structured storage-error taxonomy, in full.
type ErrorCode string

const (
	ErrPersistenceUnavailable ErrorCode = "PERSISTENCE_UNAVAILABLE"
	ErrPersistenceConflict    ErrorCode = "PERSISTENCE_CONFLICT"
	ErrInvalidStateTransition ErrorCode = "INVALID_STATE_TRANSITION"
	ErrRecordNotFound         ErrorCode = "RECORD_NOT_FOUND"
	ErrDuplicateIdempotency   ErrorCode = "DUPLICATE_IDEMPOTENCY_KEY"
	ErrIdempotencyMismatch    ErrorCode = "IDEMPOTENCY_MISMATCH"
	ErrAuditAppendFailed      ErrorCode = "AUDIT_APPEND_FAILED"
	ErrCorruptRecord          ErrorCode = "CORRUPT_RECORD"
	ErrMigrationRequired      ErrorCode = "MIGRATION_REQUIRED"
	ErrCancelled              ErrorCode = "CANCELLED"
)

// StoreError never wraps a raw SQL error message into a string a caller
// might display verbatim (M6 brief §26: "do not leak raw SQL/internal
// paths") — Detail is a short, safe, human-authored reason; the
// underlying driver error, if any, is available via Unwrap for logging
// only.
type StoreError struct {
	Code   ErrorCode
	Detail string
	cause  error
}

func (e *StoreError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Detail)
}

func (e *StoreError) Unwrap() error { return e.cause }

func newStoreErr(code ErrorCode, detail string, cause error) *StoreError {
	return &StoreError{Code: code, Detail: detail, cause: cause}
}
