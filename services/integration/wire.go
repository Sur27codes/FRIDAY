// Package integration proves M4's core claim — Policy Engine and
// Capability Bus are genuinely separate OS processes connected only by
// the documented RPC contract — by launching the real, compiled
// policyengined and capabilitybusd binaries as real subprocesses
// (harness.go) and driving them exactly as the not-yet-built M5 Runtime
// eventually will: over a Unix domain socket, speaking only the wire
// JSON shapes, with no shared Go code path into either process's
// internals.
//
// This file deliberately duplicates the wire DTOs already defined in
// policy-engine/internal/rpc/protocol.go and capability-bus/internal/rpc/protocol.go
// rather than importing them. That is not an oversight: both are
// `internal/` packages, and Go's internal-visibility rule structurally
// forbids a third module from importing them — which is exactly the
// mechanism (see those packages' own doc comments) that keeps
// capability-bus from ever reaching policy-engine's private Signer. A
// true black-box test of the wire contract has no legal way to reuse
// that code, and arguably shouldn't: it should look exactly like what an
// external, independently-written Runtime process would have to write
// from the docs alone. friday/rpcframe, friday/ir, and friday/policytoken
// are the three modules deliberately NOT under internal/, and are the
// only ones this module imports.
package integration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"friday/rpcframe"
)

var errUnavailable = errors.New("rpc peer unavailable")

type rpcEnvelope struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return e.Code + ": " + e.Message }

// call is the one place this file touches the network. timeout<=0 means
// "no artificial timeout beyond ctx" — used by the deliberately-tiny
// timeout tests, which pass a timeout so small the OS deadline is
// exceeded before or during the write itself.
func call(ctx context.Context, socketPath, method string, req interface{}, out interface{}, timeout time.Duration) error {
	dialCtx := ctx
	var cancel context.CancelFunc
	if timeout > 0 {
		dialCtx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	var d net.Dialer
	conn, err := d.DialContext(dialCtx, "unix", socketPath)
	if err != nil {
		return fmt.Errorf("%w: dial: %v", errUnavailable, err)
	}
	defer conn.Close()
	if deadline, ok := dialCtx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	b, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	if err := rpcframe.WriteFrame(conn, rpcEnvelope{Method: method, Payload: b}); err != nil {
		return fmt.Errorf("%w: write: %v", errUnavailable, err)
	}
	var resp rpcEnvelope
	if err := rpcframe.ReadFrame(conn, &resp); err != nil {
		return fmt.Errorf("%w: read: %v", errUnavailable, err)
	}
	if resp.Error != nil {
		return resp.Error
	}
	if out != nil && len(resp.Payload) > 0 {
		if err := json.Unmarshal(resp.Payload, out); err != nil {
			return fmt.Errorf("malformed response payload: %w", err)
		}
	}
	return nil
}

// ---- Policy Engine wire shapes (mirrors policy-engine/internal/rpc/protocol.go) ----

type presentedFactorWire struct {
	Factor        string    `json:"factor"`
	EstablishedAt time.Time `json:"established_at"`
	Available     bool      `json:"available"`
}

type tokenWire struct {
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

type evaluateRequest struct {
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`
	TaskID        string `json:"task_id"`
	IRID          string `json:"ir_id"`

	Actor string `json:"actor"`

	Capability        string `json:"capability_id"`
	CapabilityVersion string `json:"capability_version"`

	Purpose         string `json:"purpose"`
	Risk            string `json:"risk"`
	ArgumentsDigest string `json:"arguments_digest"`

	AssuranceFactors []presentedFactorWire `json:"assurance_factors"`

	AutonomyLevelConfigured int  `json:"autonomy_level_configured"`
	SimulatorVerified       bool `json:"simulator_verified"`
	TaskCancelled           bool `json:"task_cancelled"`
}

type evaluateResponse struct {
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`

	Decision    string `json:"decision"`
	RequiredAAL string `json:"required_aal"`
	Reason      string `json:"reason"`

	Token *tokenWire `json:"token,omitempty"`
}

func evaluateAuthorization(ctx context.Context, socketPath string, req evaluateRequest, timeout time.Duration) (evaluateResponse, error) {
	var resp evaluateResponse
	err := call(ctx, socketPath, "EvaluateAuthorization", req, &resp, timeout)
	return resp, err
}

// ---- Capability Bus wire shapes (mirrors capability-bus/internal/rpc/protocol.go) ----

type envelopeWire struct {
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

	PolicyToken *tokenWire `json:"policy_token"`

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

type dispatchRequest struct {
	Envelope envelopeWire `json:"envelope"`
}

type outcomeWire struct {
	Dispatched bool `json:"dispatched"`
	Executed   bool `json:"executed"`
	Verified   bool `json:"verified"`
	Success    bool `json:"success"`

	GetStatusResult  json.RawMessage `json:"get_status_result,omitempty"`
	CreateNoteResult json.RawMessage `json:"create_note_result,omitempty"`
}

type dispatchResponse struct {
	Outcome outcomeWire `json:"outcome"`
}

type devSeedIRRequest struct {
	IRID         string                 `json:"ir_id"`
	CapabilityID string                 `json:"capability_id"`
	Arguments    map[string]interface{} `json:"arguments"`
}

type devSeedTaskRequest struct {
	TaskID string `json:"task_id"`
	State  string `json:"state"`
}

type devSeedResponse struct {
	OK bool `json:"ok"`
}

func dispatch(ctx context.Context, socketPath string, req dispatchRequest, timeout time.Duration) (dispatchResponse, error) {
	var resp dispatchResponse
	err := call(ctx, socketPath, "Dispatch", req, &resp, timeout)
	return resp, err
}

func devSeedIR(ctx context.Context, socketPath string, req devSeedIRRequest) error {
	var resp devSeedResponse
	return call(ctx, socketPath, "DevSeedIR", req, &resp, 5*time.Second)
}

func devSeedTask(ctx context.Context, socketPath string, req devSeedTaskRequest) error {
	var resp devSeedResponse
	return call(ctx, socketPath, "DevSeedTask", req, &resp, 5*time.Second)
}

func health(ctx context.Context, socketPath string) (map[string]bool, error) {
	var resp map[string]bool
	err := call(ctx, socketPath, "Health", struct{}{}, &resp, 3*time.Second)
	return resp, err
}
