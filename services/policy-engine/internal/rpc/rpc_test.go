// M4 unit-level tests for the Policy Engine's RPC boundary: the real
// Server and Client types talking over a real Unix domain socket within
// this test binary. These prove the wire-transport-level behaviors (fail
// closed on dial failure/timeout/malformed response, structural
// consistency enforcement, unknown-method/malformed-frame handling)
// against the actual production Client/Server code — not a
// reimplementation.
//
// Genuine cross-process proof (two real separate OS processes,
// policyengined and capabilitybusd, launched as subprocesses) lives in
// services/integration, which cannot import this internal package (Go's
// internal/ visibility rule) and instead speaks the wire protocol
// directly — see that module's package doc for why that split is
// intentional, not an oversight.
package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"friday/policy-engine/internal/policy"
	"friday/policytoken"
	"friday/rpcframe"
)

func newTestSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "fpe-")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

func startTestServer(t *testing.T) (socketPath string, engine *policy.Engine) {
	t.Helper()
	signer, _, err := policy.NewKeyPair()
	if err != nil {
		t.Fatalf("new key pair: %v", err)
	}
	engine = policy.NewEngine(signer)
	socketPath = newTestSocket(t)
	srv, err := Listen(socketPath, engine)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	go srv.Serve()
	return socketPath, engine
}

func TestServer_HealthCheck(t *testing.T) {
	socketPath, _ := startTestServer(t)
	c := NewClient(socketPath, 2*time.Second)
	// Health isn't exposed on Client (only EvaluateAuthorization is, per
	// M4 brief §15's "no signing-oracle, minimal surface" rule) — dial
	// directly to exercise it, matching what a real ops health-check tool
	// would do without pulling in the full EvaluateAuthorization contract.
	_ = c
	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := rpcframe.WriteFrame(conn, Envelope{Method: "Health"}); err != nil {
		t.Fatalf("write: %v", err)
	}
	var resp Envelope
	if err := rpcframe.ReadFrame(conn, &resp); err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error)
	}
	var body map[string]bool
	if err := json.Unmarshal(resp.Payload, &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !body["alive"] || !body["ready"] {
		t.Fatalf("expected alive+ready, got %+v", body)
	}
}

func TestServer_UnknownMethod_ReturnsStructuredError(t *testing.T) {
	socketPath, _ := startTestServer(t)
	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := rpcframe.WriteFrame(conn, Envelope{Method: "SignToken"}); err != nil {
		t.Fatalf("write: %v", err)
	}
	var resp Envelope
	if err := rpcframe.ReadFrame(conn, &resp); err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp.Error == nil || resp.Error.Code != ErrExecutionEnvelopeInvalid {
		t.Fatalf("expected EXECUTION_ENVELOPE_INVALID for unknown method, got %+v", resp.Error)
	}
}

func TestServer_MalformedRequestFrame_NoResponseWritten(t *testing.T) {
	socketPath, _ := startTestServer(t)
	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	// A length prefix claiming a frame that is never actually sent —
	// server.go's handleConn reads this, fails, logs, and returns without
	// writing anything (see server.go); the connection should just close
	// from the server's side.
	if _, err := conn.Write([]byte{0, 0, 0, 50}); err != nil {
		t.Fatalf("write partial frame: %v", err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 16)
	n, readErr := conn.Read(buf)
	if readErr == nil {
		t.Fatalf("expected the server to close without responding, got %d bytes", n)
	}
}

func TestClient_DialFailure_FailsClosed(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "fpe-nolisten-")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	nobodyHome := filepath.Join(dir, "nobody.sock")

	c := NewClient(nobodyHome, 500*time.Millisecond)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{Actor: "a", Capability: "workspace.create_note", Risk: "low"})
	if err == nil {
		t.Fatalf("expected a dial error, got success: %+v", resp)
	}
	if !errors.Is(err, ErrPolicyUnavailableSentinel) {
		t.Fatalf("expected ErrPolicyUnavailableSentinel, got: %v", err)
	}
	if resp.Decision != "" || resp.Token != nil {
		t.Fatalf("a failed call must never carry a decision or token: %+v", resp)
	}
}

// fakeServer is a minimal, deliberately non-compliant Envelope responder
// used only to prove the Client rejects malformed/inconsistent responses
// from whatever is on the other end of the socket — it does not run any
// policy logic, on purpose: the point is to test the CLIENT's own
// defenses, independent of whether the real Server would ever actually
// produce such a response.
func startFakeServer(t *testing.T, handle func(conn net.Conn, req Envelope)) string {
	t.Helper()
	socketPath := newTestSocket(t)
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var req Envelope
				if err := rpcframe.ReadFrame(conn, &req); err != nil {
					return
				}
				handle(conn, req)
			}()
		}
	}()
	return socketPath
}

func TestClient_MalformedResponsePayload_FailsClosed(t *testing.T) {
	socketPath := startFakeServer(t, func(conn net.Conn, req Envelope) {
		// Valid frame, valid outer Envelope, but Payload is not a valid
		// EvaluateResponse shape at all.
		_ = rpcframe.WriteFrame(conn, Envelope{Method: req.Method, Payload: json.RawMessage(`[1,2,3]`)})
	})
	c := NewClient(socketPath, 2*time.Second)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{Actor: "a", Capability: "workspace.create_note", Risk: "low"})
	if err == nil {
		t.Fatalf("expected malformed-response error, got success: %+v", resp)
	}
	if resp.Decision != "" || resp.Token != nil {
		t.Fatalf("a failed call must never carry a decision or token: %+v", resp)
	}
}

func TestClient_AllowWithoutToken_RejectedAsMalformed(t *testing.T) {
	socketPath := startFakeServer(t, func(conn net.Conn, req Envelope) {
		b, _ := json.Marshal(EvaluateResponse{Decision: "ALLOW", RequiredAAL: "AAL1", Reason: "fake"})
		_ = rpcframe.WriteFrame(conn, Envelope{Method: req.Method, Payload: b})
	})
	c := NewClient(socketPath, 2*time.Second)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{Actor: "a", Capability: "workspace.create_note", Risk: "low"})
	if err == nil {
		t.Fatalf("expected M4-POL-016 structural-consistency rejection, got success: %+v", resp)
	}
}

func TestClient_TokenWithoutAllow_RejectedAsMalformed(t *testing.T) {
	socketPath := startFakeServer(t, func(conn net.Conn, req Envelope) {
		b, _ := json.Marshal(EvaluateResponse{
			Decision: "DENY", RequiredAAL: "AAL1", Reason: "fake",
			Token: &TokenWire{TokenID: "t1", CapabilityID: "workspace.create_note"},
		})
		_ = rpcframe.WriteFrame(conn, Envelope{Method: req.Method, Payload: b})
	})
	c := NewClient(socketPath, 2*time.Second)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{Actor: "a", Capability: "workspace.create_note", Risk: "low"})
	if err == nil {
		t.Fatalf("expected M4-POL-016 structural-consistency rejection, got success: %+v", resp)
	}
}

func TestClient_Timeout_FailsClosed(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	socketPath := startFakeServer(t, func(conn net.Conn, req Envelope) {
		<-release // never respond within the client's timeout
	})
	c := NewClient(socketPath, 300*time.Millisecond)
	start := time.Now()
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{Actor: "a", Capability: "workspace.create_note", Risk: "low"})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("expected a timeout error, got success: %+v", resp)
	}
	if !errors.Is(err, ErrPolicyUnavailableSentinel) {
		t.Fatalf("expected ErrPolicyUnavailableSentinel, got: %v", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("client did not fail closed within a bounded time: took %s", elapsed)
	}
	if resp.Decision != "" || resp.Token != nil {
		t.Fatalf("a timed-out call must never carry a decision or token: %+v", resp)
	}
}

// ---- Real Server + real Client, end to end within one process (the
// cross-process equivalent lives in services/integration) ----

func TestEndToEnd_RealServerRealClient_DenyWithoutAssuranceFactors(t *testing.T) {
	socketPath, _ := startTestServer(t)
	c := NewClient(socketPath, 2*time.Second)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", Risk: "low",
	})
	if err != nil {
		t.Fatalf("unexpected transport error: %v", err)
	}
	if resp.Decision != "DENY" {
		t.Fatalf("expected DENY with no assurance factors presented, got %q (reason=%q)", resp.Decision, resp.Reason)
	}
	if resp.Token != nil {
		t.Fatalf("a DENY must never carry a token")
	}
}

func TestEndToEnd_RealServerRealClient_AllowWithDeviceTrustedSession(t *testing.T) {
	socketPath, engine := startTestServer(t)
	c := NewClient(socketPath, 2*time.Second)
	resp, err := c.EvaluateAuthorization(context.Background(), EvaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-1", Risk: "low",
		ArgumentsDigest: "deadbeef",
		AssuranceFactors: []PresentedFactorWire{
			{Factor: "device_trusted_session", Available: true, EstablishedAt: time.Now()},
		},
	})
	if err != nil {
		t.Fatalf("unexpected transport error: %v", err)
	}
	if resp.Decision != "ALLOW" {
		t.Fatalf("expected ALLOW, got %q (reason=%q)", resp.Decision, resp.Reason)
	}
	if resp.Token == nil {
		t.Fatalf("ALLOW must carry a token")
	}
	if resp.Token.CapabilityID != "workspace.create_note" || resp.Token.IRID != "ir-1" {
		t.Fatalf("token scope does not match the request: %+v", resp.Token)
	}
	// The token must actually verify against this same engine's public key
	// — proving the server's live signing path (not a stub) produced it,
	// using the exact same Verifier.Validate a real Capability Bus would
	// run (M3/policytoken), not a hand-rolled signature check here.
	fullTok := &policytoken.PolicyToken{
		TokenID: resp.Token.TokenID, IRID: resp.Token.IRID, CapabilityID: resp.Token.CapabilityID,
		Actor: resp.Token.Actor, RiskLevel: policytoken.RiskLevel(resp.Token.RiskLevel),
		Purpose: resp.Token.Purpose, ArgumentsDigest: resp.Token.ArgumentsDigest,
		IssuedAt: resp.Token.IssuedAt, ExpiresAt: resp.Token.ExpiresAt, Signature: resp.Token.Signature,
	}
	verr := engine.Verifier().Validate(policytoken.ValidationRequest{
		Token: fullTok, Now: time.Now(),
		ExpectedIRID: "ir-1", ExpectedCapability: "workspace.create_note", ExpectedActor: "user.owner",
		ExpectedArgsDigest: "deadbeef",
	})
	if verr != nil {
		t.Fatalf("token issued by the real server did not verify against the real engine's public key: %v", verr)
	}
}
