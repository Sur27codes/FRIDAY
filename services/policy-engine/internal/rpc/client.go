package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"friday/rpcframe"
)

// ErrPolicyUnavailableSentinel is wrapped into every client-side failure
// that means "no live decision could be obtained" (dial failure, write
// failure, read failure/timeout) — callers can test for it with
// errors.Is to distinguish "the Policy Engine is unreachable" from other
// error shapes (e.g., a malformed-response error), while both still
// resolve to the same fail-closed handling.
var ErrPolicyUnavailableSentinel = errors.New("policy engine unavailable")

// Client dials the Policy Engine's Unix socket. It holds no key material
// of any kind — it is safe for any process (including, structurally,
// the Capability Bus, though the Bus in this architecture never actually
// calls the Policy Engine at dispatch time — only the Runtime/test
// harness standing in for M5's Planner does, per PHASE-1-EXECUTION-SPEC.md
// §11's flow).
type Client struct {
	socketPath string
	timeout    time.Duration
}

func NewClient(socketPath string, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 5 * time.Second // TBD — benchmark required; a safe default for tests/dev
	}
	return &Client{socketPath: socketPath, timeout: timeout}
}

// EvaluateAuthorization performs exactly one RPC call. It is the ONLY
// method this client exposes for obtaining authorization — there is no
// SignToken-style call (M4 brief §15).
//
// Every failure mode fails closed: a dial error, a timeout, a transport
// error, an RPC-level error (RPCError), or a structurally malformed
// response (ALLOW without a token, or a token without ALLOW) all return a
// non-nil error and a response whose Decision the caller MUST NOT treat
// as authorization. There is no code path in this function that
// synthesizes a permissive result from a failure.
func (c *Client) EvaluateAuthorization(ctx context.Context, req EvaluateRequest) (EvaluateResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", c.socketPath)
	if err != nil {
		// Policy Engine unreachable — M4-POL-003's fail-closed case.
		return EvaluateResponse{}, fmt.Errorf("%w: dialing policy engine: %v", ErrPolicyUnavailableSentinel, err)
	}
	defer conn.Close()

	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}

	payload, err := marshalForSend(req)
	if err != nil {
		return EvaluateResponse{}, fmt.Errorf("marshaling request: %w", err)
	}
	if err := rpcframe.WriteFrame(conn, Envelope{Method: "EvaluateAuthorization", Payload: payload}); err != nil {
		return EvaluateResponse{}, fmt.Errorf("%w: writing request: %v", ErrPolicyUnavailableSentinel, err)
	}

	var respEnv Envelope
	if err := rpcframe.ReadFrame(conn, &respEnv); err != nil {
		// Includes the context-deadline-exceeded case (RPC timeout) and
		// a mid-response connection drop (server crash) — both fail
		// closed identically, per M4 brief §12.
		return EvaluateResponse{}, fmt.Errorf("%w: reading response: %v", ErrPolicyUnavailableSentinel, err)
	}
	if respEnv.Error != nil {
		return EvaluateResponse{}, respEnv.Error
	}

	var resp EvaluateResponse
	if err := unmarshalPayload(respEnv.Payload, &resp); err != nil {
		return EvaluateResponse{}, fmt.Errorf("malformed response payload: %w", err)
	}

	// Structural consistency check — M4-POL-016: a malformed policy
	// response must never become authorization. "ALLOW with no token" and
	// "non-ALLOW with a token" are both internally inconsistent and are
	// rejected here, before the caller ever sees a Token field it might
	// be tempted to trust despite an inconsistent Decision.
	if resp.Decision == "ALLOW" && resp.Token == nil {
		return EvaluateResponse{}, fmt.Errorf("malformed response: decision=ALLOW but no token present")
	}
	if resp.Decision != "ALLOW" && resp.Token != nil {
		return EvaluateResponse{}, fmt.Errorf("malformed response: token present without decision=ALLOW")
	}

	return resp, nil
}

func marshalForSend(v interface{}) ([]byte, error) {
	return json.Marshal(v)
}
