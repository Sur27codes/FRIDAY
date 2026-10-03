// Package rpc implements the Capability Bus's Unix-socket RPC surface:
// Dispatch (the only production execution path) plus two clearly-marked
// Phase-1-only bootstrap methods, DevSeedIR and DevSeedTask, which exist
// solely because M5 (Planner/Runtime) and M6 (persistent IR/task store)
// don't exist yet — see the doc comment on those types for why this is
// disclosed as temporary, not a production interface.
//
// There is deliberately no RunAnything, ExecuteShell, InvokeRawFunction,
// or DispatchWithoutAuthorization method (M4 brief §10) — Dispatch is the
// only way to reach a capability, and it always runs the full envelope
// validation (11 checks, including live token verification) internally;
// the transport layer adds no separate, weaker path.
package rpc

import (
	"encoding/json"
	"time"
)

// TokenWire mirrors policytoken.PolicyToken for the wire.
type TokenWire struct {
	TokenID         string    `json:"token_id"`
	IRID            string    `json:"ir_id"`
	CapabilityID    string    `json:"capability_id"`
	Actor           string    `json:"actor"`
	RiskLevel       string    `json:"risk_level"`
	Purpose         string    `json:"purpose"`
	ArgumentsDigest string    `json:"arguments_digest"`
	IssuedAt        time.Time `json:"issued_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	Signature       []byte    `json:"signature"`
}

// EnvelopeWire mirrors envelope.Envelope for the wire.
type EnvelopeWire struct {
	ExecutionID   string `json:"execution_id"`
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`
	Actor         string `json:"actor"`
	GoalID        string `json:"goal_id"`
	TaskID        string `json:"task_id"`
	IRVersion     string `json:"ir_version"`
	IRID          string `json:"ir_id"`
	Capability    string `json:"capability_id"`

	ValidatedArguments map[string]interface{} `json:"validated_arguments"`

	PolicyToken *TokenWire `json:"policy_token"`

	Purpose string `json:"purpose"`
	Risk    string `json:"risk"`

	IdempotencyKey string `json:"idempotency_key"`
	SafeToRetry    bool   `json:"safe_to_retry"`

	ExpectedOutcomeDescription string      `json:"expected_outcome_description"`
	ExpectedSuccessCondition   interface{} `json:"expected_success_condition"`

	VerificationMethod string `json:"verification_method"`

	Cancellable        bool   `json:"cancellable"`
	CancellationEffect string `json:"cancellation_effect"`
}

// DispatchRequest is the only production request shape that can cause a
// capability to execute.
type DispatchRequest struct {
	Envelope EnvelopeWire `json:"envelope"`
}

// OutcomeWire mirrors bus.Outcome for the wire (result fields only — no
// internal error type leaked; DispatchResponse.Error carries structured
// failure detail separately, see errors.go).
type OutcomeWire struct {
	Dispatched bool `json:"dispatched"`
	Executed   bool `json:"executed"`
	Verified   bool `json:"verified"`
	Success    bool `json:"success"`

	GetStatusResult  json.RawMessage `json:"get_status_result,omitempty"`
	CreateNoteResult json.RawMessage `json:"create_note_result,omitempty"`
}

type DispatchResponse struct {
	Outcome OutcomeWire `json:"outcome"`
}

// DevSeedIRRequest and DevSeedTaskRequest are Phase-1/M4-only bootstrap
// methods. In the target architecture (M5+), the Runtime/Planner writes
// IR records and task-state transitions directly to durable storage
// (M6) — no RPC call from an external harness is involved, and these two
// methods will be removed once that exists. They are exposed now, on
// this same socket but under clearly distinct method names (never
// reachable via "Dispatch"), purely so M4's process-boundary proof is
// testable end to end without M5/M6 already existing. They perform no
// capability execution and grant no authorization — they only seed the
// Bus process's own in-memory store.IRStore/store.TaskStore (identical
// to what M3's tests did in-process).
type DevSeedIRRequest struct {
	IRID         string                 `json:"ir_id"`
	CapabilityID string                 `json:"capability_id"`
	Arguments    map[string]interface{} `json:"arguments"`
}

type DevSeedTaskRequest struct {
	TaskID string `json:"task_id"`
	State  string `json:"state"` // "AUTHORIZED" | "CANCELLED" | ...
}

type DevSeedResponse struct {
	OK bool `json:"ok"`
}

// ErrorCode mirrors the M4 brief §19's structured RPC error taxonomy,
// extended with the Bus-specific categories already defined in M3's
// envelope.Category (mapped 1:1, not reinvented — see server.go).
type ErrorCode string

const (
	ErrCapabilityUnknown          ErrorCode = "CAPABILITY_UNKNOWN"
	ErrExecutionEnvelopeInvalid   ErrorCode = "EXECUTION_ENVELOPE_INVALID"
	ErrAuthorizationInvalid       ErrorCode = "AUTHORIZATION_INVALID"
	ErrAuthorizationExpired       ErrorCode = "AUTHORIZATION_EXPIRED"
	ErrAuthorizationScopeMismatch ErrorCode = "AUTHORIZATION_SCOPE_MISMATCH"
	ErrArgumentDigestMismatch     ErrorCode = "ARGUMENT_DIGEST_MISMATCH"
	ErrPurposeMismatch            ErrorCode = "PURPOSE_MISMATCH"
	ErrCapabilityInputInvalid     ErrorCode = "CAPABILITY_INPUT_INVALID"
	ErrCapabilityExecutionFailed  ErrorCode = "CAPABILITY_EXECUTION_FAILED"
	ErrVerificationFailed         ErrorCode = "VERIFICATION_FAILED"
	ErrCancelled                  ErrorCode = "CANCELLED"
	ErrAuthorizationMissing       ErrorCode = "AUTHORIZATION_MISSING"
)

type RPCError struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

func (e *RPCError) Error() string { return string(e.Code) + ": " + e.Message }

type Envelope struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}
