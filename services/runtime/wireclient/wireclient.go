// Package wireclient is the M7 Runtime's ONLY path to the Policy Engine
// and Capability Bus processes: a real Unix-socket RPC client speaking
// the wire protocol those two daemons already expose (M4). It
// deliberately duplicates the wire DTOs from policy-engine/internal/rpc
// and capability-bus/internal/rpc rather than importing them — Go's
// internal/ visibility rule structurally forbids a third module from
// importing either (see those packages' own doc comments; M4's
// services/integration test module already established this exact
// pattern for the same reason).
//
// This is the concrete mechanism behind M7 brief §4/§5: friday/runtime's
// go.mod has no dependency on friday/policy-engine, friday/policytoken,
// or friday/capability-bus at all (verified structurally via `go list
// -deps`, see the isolation test) — the compiled `friday` binary
// literally cannot construct a policy_token, sign anything, or call a
// capability adapter function directly. Every capability execution and
// every authorization decision crosses a real OS process boundary.
package wireclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"friday/rpcframe"
)

var ErrUnavailable = errors.New("rpc peer unavailable")

type rpcEnvelope struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// RPCError mirrors both services' RPCError shape.
type RPCError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string { return e.Code + ": " + e.Message }

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
		return fmt.Errorf("%w: dial %s: %v", ErrUnavailable, method, err)
	}
	defer conn.Close()
	if deadline, ok := dialCtx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	b, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal %s request: %w", method, err)
	}
	if err := rpcframe.WriteFrame(conn, rpcEnvelope{Method: method, Payload: b}); err != nil {
		return fmt.Errorf("%w: write %s: %v", ErrUnavailable, method, err)
	}
	var resp rpcEnvelope
	if err := rpcframe.ReadFrame(conn, &resp); err != nil {
		return fmt.Errorf("%w: read %s response: %v", ErrUnavailable, method, err)
	}
	if resp.Error != nil {
		return resp.Error
	}
	if out != nil && len(resp.Payload) > 0 {
		if err := json.Unmarshal(resp.Payload, out); err != nil {
			return fmt.Errorf("malformed %s response payload: %w", method, err)
		}
	}
	return nil
}

// ---- Policy Engine wire shapes (mirrors policy-engine/internal/rpc/protocol.go) ----

type PresentedFactorWire struct {
	Factor        string    `json:"factor"`
	EstablishedAt time.Time `json:"established_at"`
	Available     bool      `json:"available"`
}

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

type EvaluateRequest struct {
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

	AssuranceFactors []PresentedFactorWire `json:"assurance_factors"`

	AutonomyLevelConfigured int  `json:"autonomy_level_configured"`
	SimulatorVerified       bool `json:"simulator_verified"`
	TaskCancelled           bool `json:"task_cancelled"`
}

type EvaluateResponse struct {
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`

	Decision    string `json:"decision"`
	RequiredAAL string `json:"required_aal"`
	Reason      string `json:"reason"`

	Token *TokenWire `json:"token,omitempty"`
}

// PolicyClient talks to a real policyengined process. It holds no key
// material of any kind — see the package doc.
type PolicyClient struct {
	socketPath string
	timeout    time.Duration
}

func NewPolicyClient(socketPath string, timeout time.Duration) *PolicyClient {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &PolicyClient{socketPath: socketPath, timeout: timeout}
}

// healthResponse mirrors both daemons' identical Health payload shape
// (map[string]bool{"alive": ..., "ready": ...}).
type healthResponse struct {
	Alive bool `json:"alive"`
	Ready bool `json:"ready"`
}

// Health reports whether the real policyengined process is reachable and
// ready — used by the World Model's live service-health projection
// (M8). A dial/RPC failure is reported as unhealthy, never silently
// treated as healthy (fail closed, same discipline as every other client
// in this package).
func (c *PolicyClient) Health(ctx context.Context) (bool, error) {
	var resp healthResponse
	if err := call(ctx, c.socketPath, "Health", struct{}{}, &resp, 3*time.Second); err != nil {
		return false, err
	}
	return resp.Alive && resp.Ready, nil
}

func (c *PolicyClient) EvaluateAuthorization(ctx context.Context, req EvaluateRequest) (EvaluateResponse, error) {
	var resp EvaluateResponse
	err := call(ctx, c.socketPath, "EvaluateAuthorization", req, &resp, c.timeout)
	if err != nil {
		return EvaluateResponse{}, err
	}
	// M4-POL-016's structural-consistency rule, re-enforced at every
	// caller of this wire protocol, not just the one client that
	// originally established it — a malformed response never becomes
	// authorization here either.
	if resp.Decision == "ALLOW" && resp.Token == nil {
		return EvaluateResponse{}, fmt.Errorf("malformed response: decision=ALLOW but no token present")
	}
	if resp.Decision != "ALLOW" && resp.Token != nil {
		return EvaluateResponse{}, fmt.Errorf("malformed response: token present without decision=ALLOW")
	}
	return resp, nil
}

// ---- Capability Bus wire shapes (mirrors capability-bus/internal/rpc/protocol.go) ----

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

type DispatchRequest struct {
	Envelope EnvelopeWire `json:"envelope"`
}

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

type DevSeedIRRequest struct {
	IRID         string                 `json:"ir_id"`
	CapabilityID string                 `json:"capability_id"`
	Arguments    map[string]interface{} `json:"arguments"`
}

type DevSeedTaskRequest struct {
	TaskID string `json:"task_id"`
	State  string `json:"state"`
}

type DevSeedResponse struct {
	OK bool `json:"ok"`
}

// BusClient talks to a real capabilitybusd process.
type BusClient struct {
	socketPath string
	timeout    time.Duration
}

func NewBusClient(socketPath string, timeout time.Duration) *BusClient {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &BusClient{socketPath: socketPath, timeout: timeout}
}

// Health reports whether the real capabilitybusd process is reachable
// and ready — see PolicyClient.Health's identical doc comment.
func (c *BusClient) Health(ctx context.Context) (bool, error) {
	var resp healthResponse
	if err := call(ctx, c.socketPath, "Health", struct{}{}, &resp, 3*time.Second); err != nil {
		return false, err
	}
	return resp.Alive && resp.Ready, nil
}

// Dispatch is the ONLY production execution RPC this client exposes —
// there is no RunAnything/ExecuteShell method (M4 brief §10, still
// binding in M7).
func (c *BusClient) Dispatch(ctx context.Context, req DispatchRequest) (DispatchResponse, error) {
	var resp DispatchResponse
	err := call(ctx, c.socketPath, "Dispatch", req, &resp, c.timeout)
	return resp, err
}

// DevSeedIR/DevSeedTask are how the M7 Runtime actually keeps the
// Capability Bus's own in-memory IRStore/TaskStore (capability-bus's
// envelope-validation checks 2 and 4, built in M3/M4) in sync with what
// this Runtime has durably decided. Despite the "DevSeed" name inherited
// from M4 (when they were disclosed as a stand-in for "the not-yet-built
// Runtime/Planner" — see capability-bus's protocol.go doc comment), M7
// IS that Runtime: the Capability Bus's checks were built, tested, and
// accepted exactly as they are in M3/M4, and M7's scope does not include
// modifying capability-bus internals (M7 brief §2 — "integration," not
// re-architecture). The correct, disclosed reading is that these RPCs
// are the real production mechanism, not a shortcut this client happens
// to reuse — the orchestrator calls DevSeedIR once per task (mirroring
// the durable IR snapshot it just wrote to runtime-store) and
// DevSeedTask at the AUTHORIZED transition, immediately before Dispatch.
func (c *BusClient) DevSeedIR(ctx context.Context, req DevSeedIRRequest) error {
	var resp DevSeedResponse
	return call(ctx, c.socketPath, "DevSeedIR", req, &resp, 5*time.Second)
}

func (c *BusClient) DevSeedTask(ctx context.Context, req DevSeedTaskRequest) error {
	var resp DevSeedResponse
	return call(ctx, c.socketPath, "DevSeedTask", req, &resp, 5*time.Second)
}
