// M4 unit-level tests for the Capability Bus's RPC boundary: the real
// Server and Client types talking over a real Unix domain socket within
// this test binary. Token minting uses the same ephemeral-test-keypair
// pattern as internal/bus/bus_test.go (this package has no import path to
// friday/policy-engine/internal/policy's real Signer — see that file's
// package doc) — the point here is to prove the RPC transport/dispatch
// wiring is correct, not to re-derive the envelope validation logic
// itself (already covered by internal/bus/bus_test.go).
//
// Genuine cross-process proof (two real separate OS processes) lives in
// services/integration.
package rpc

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"friday/capability-bus/internal/bus"
	"friday/capability-bus/internal/capabilities/createnote"
	"friday/capability-bus/internal/capabilities/getstatus"
	"friday/capability-bus/internal/envelope"
	"friday/capability-bus/internal/registry"
	"friday/capability-bus/internal/store"
	"friday/ir"
	"friday/policytoken"
	"friday/rpcframe"
)

type harness struct {
	t          *testing.T
	priv       ed25519.PrivateKey
	verifier   policytoken.Verifier
	irStore    *store.IRStore
	taskStore  *store.TaskStore
	socketPath string
}

func newTestSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "fcb-")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generating test keypair: %v", err)
	}
	sandbox, err := createnote.NewSandbox(t.TempDir())
	if err != nil {
		t.Fatalf("new sandbox: %v", err)
	}
	irStore := store.NewIRStore()
	taskStore := store.NewTaskStore()
	ctx := envelope.ValidationContext{
		Registry: registry.Phase1(), Verifier: policytoken.NewVerifier(pub),
		IRStore: irStore, TaskStore: taskStore,
	}
	b := bus.New(ctx, getstatus.StaticSource{}, sandbox)
	socketPath := newTestSocket(t)
	srv, err := Listen(socketPath, b, irStore, taskStore)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	go srv.Serve()
	return &harness{t: t, priv: priv, verifier: ctx.Verifier, irStore: irStore, taskStore: taskStore, socketPath: socketPath}
}

func (h *harness) signToken(tok policytoken.PolicyToken) *policytoken.PolicyToken {
	h.t.Helper()
	payload, err := tok.SigningPayload()
	if err != nil {
		h.t.Fatalf("signing payload: %v", err)
	}
	tok.Signature = ed25519.Sign(h.priv, payload)
	return &tok
}

func tokenToWireForTest(t *policytoken.PolicyToken) *TokenWire {
	return &TokenWire{
		TokenID: t.TokenID, IRID: t.IRID, CapabilityID: t.CapabilityID, Actor: t.Actor,
		RiskLevel: string(t.RiskLevel), Purpose: t.Purpose, ArgumentsDigest: t.ArgumentsDigest,
		IssuedAt: t.IssuedAt, ExpiresAt: t.ExpiresAt, Signature: t.Signature,
	}
}

// validDispatchRequest builds a well-formed DispatchRequest for the given,
// already-seeded (irID, capabilityID, args) triple, signed with the
// harness's test key — mirroring internal/bus/bus_test.go's
// validEnvelope, but producing the wire shape this RPC layer consumes.
func (h *harness) validDispatchRequest(taskID, irID, capabilityID, actor string, args map[string]interface{}, risk string) DispatchRequest {
	h.t.Helper()
	digest, err := ir.ArgumentsDigest(args)
	if err != nil {
		h.t.Fatalf("digest: %v", err)
	}
	now := time.Now()
	tok := h.signToken(policytoken.PolicyToken{
		TokenID: "tok-" + taskID, IRID: irID, CapabilityID: capabilityID, Actor: actor,
		RiskLevel: policytoken.RiskLevel(risk), ArgumentsDigest: digest,
		IssuedAt: now, ExpiresAt: now.Add(time.Minute),
	})
	verificationMethod := "schema_conformance_against_live_self_model"
	if capabilityID == "workspace.create_note" {
		verificationMethod = "post_write_existence_and_content_check"
	}
	return DispatchRequest{Envelope: EnvelopeWire{
		ExecutionID: "exec-" + taskID, RequestID: "req-" + taskID, CorrelationID: "corr-" + taskID,
		Actor: actor, TaskID: taskID, IRVersion: envelope.SupportedIRVersion, IRID: irID, Capability: capabilityID,
		ValidatedArguments: args, PolicyToken: tokenToWireForTest(tok), IdempotencyKey: "idem-" + taskID,
		ExpectedSuccessCondition: map[string]interface{}{"ok": true},
		VerificationMethod:       verificationMethod,
		Cancellable:              true, CancellationEffect: "none_yet_started",
	}}
}

func (h *harness) seed(t *testing.T, irID, capabilityID string, args map[string]interface{}, taskID string) {
	t.Helper()
	c := NewClient(h.socketPath, 2*time.Second)
	if err := c.DevSeedIR(context.Background(), DevSeedIRRequest{IRID: irID, CapabilityID: capabilityID, Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := c.DevSeedTask(context.Background(), DevSeedTaskRequest{TaskID: taskID, State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}
}

func TestServer_HealthCheck(t *testing.T) {
	h := newHarness(t)
	conn, err := net.DialTimeout("unix", h.socketPath, 2*time.Second)
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
	h := newHarness(t)
	conn, err := net.DialTimeout("unix", h.socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := rpcframe.WriteFrame(conn, Envelope{Method: "RunAnything"}); err != nil {
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

func TestServer_MalformedDispatchPayload_FailsClosed(t *testing.T) {
	h := newHarness(t)
	conn, err := net.DialTimeout("unix", h.socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := rpcframe.WriteFrame(conn, Envelope{Method: "Dispatch", Payload: json.RawMessage(`{"envelope": "not an object"}`)}); err != nil {
		t.Fatalf("write: %v", err)
	}
	var resp Envelope
	if err := rpcframe.ReadFrame(conn, &resp); err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp.Error == nil || resp.Error.Code != ErrExecutionEnvelopeInvalid {
		t.Fatalf("expected EXECUTION_ENVELOPE_INVALID for malformed payload, got %+v", resp.Error)
	}
}

func TestDispatch_GetStatus_HappyPath_ViaRealRPC(t *testing.T) {
	h := newHarness(t)
	h.seed(t, "ir-1", "system.get_status", map[string]interface{}{}, "task-1")
	req := h.validDispatchRequest("task-1", "ir-1", "system.get_status", "user.owner", map[string]interface{}{}, "none")

	c := NewClient(h.socketPath, 2*time.Second)
	resp, err := c.Dispatch(context.Background(), req)
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	if !resp.Outcome.Dispatched || !resp.Outcome.Executed || !resp.Outcome.Verified || !resp.Outcome.Success {
		t.Fatalf("expected full success, got %+v", resp.Outcome)
	}
	if len(resp.Outcome.GetStatusResult) == 0 {
		t.Fatalf("expected a get_status_result payload")
	}
}

func TestDispatch_CreateNote_HappyPath_ViaRealRPC(t *testing.T) {
	h := newHarness(t)
	args := map[string]interface{}{"title": "hello", "body": "world"}
	h.seed(t, "ir-2", "workspace.create_note", args, "task-2")
	req := h.validDispatchRequest("task-2", "ir-2", "workspace.create_note", "user.owner", args, "low")

	c := NewClient(h.socketPath, 2*time.Second)
	resp, err := c.Dispatch(context.Background(), req)
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	if !resp.Outcome.Dispatched || !resp.Outcome.Executed || !resp.Outcome.Verified || !resp.Outcome.Success {
		t.Fatalf("expected full success, got %+v", resp.Outcome)
	}
	if len(resp.Outcome.CreateNoteResult) == 0 {
		t.Fatalf("expected a create_note_result payload")
	}
}

func TestDispatch_ArgumentTamperingAfterTokenIssuance_DigestMismatch(t *testing.T) {
	h := newHarness(t)
	original := map[string]interface{}{"title": "original", "body": "safe"}
	h.seed(t, "ir-3", "workspace.create_note", original, "task-3")
	// Token is minted against the ORIGINAL arguments' digest.
	req := h.validDispatchRequest("task-3", "ir-3", "workspace.create_note", "user.owner", original, "low")

	// Simulate a compromised/buggy caller re-seeding the same ir_id with
	// DIFFERENT arguments before Dispatch actually runs — the Bus must
	// re-fetch by ir_id and detect the digest no longer matches the
	// token, never trust the caller's own ValidatedArguments field.
	tampered := map[string]interface{}{"title": "TAMPERED", "body": "malicious"}
	if err := NewClient(h.socketPath, 2*time.Second).DevSeedIR(context.Background(), DevSeedIRRequest{
		IRID: "ir-3", CapabilityID: "workspace.create_note", Arguments: tampered,
	}); err != nil {
		t.Fatalf("re-seed: %v", err)
	}

	c := NewClient(h.socketPath, 2*time.Second)
	resp, err := c.Dispatch(context.Background(), req)
	if err == nil {
		t.Fatalf("expected ARGUMENT_DIGEST_MISMATCH, got success: %+v", resp.Outcome)
	}
	rpcErr, ok := err.(*RPCError)
	if !ok {
		t.Fatalf("expected *RPCError, got %T: %v", err, err)
	}
	if rpcErr.Code != ErrArgumentDigestMismatch {
		t.Fatalf("expected ARGUMENT_DIGEST_MISMATCH, got %s", rpcErr.Code)
	}
}

func TestDispatch_UnknownCapability_Rejected(t *testing.T) {
	h := newHarness(t)
	h.seed(t, "ir-4", "system.get_status", map[string]interface{}{}, "task-4")
	req := h.validDispatchRequest("task-4", "ir-4", "system.get_status", "user.owner", map[string]interface{}{}, "none")
	req.Envelope.Capability = "system.delete_everything" // never registered

	c := NewClient(h.socketPath, 2*time.Second)
	_, err := c.Dispatch(context.Background(), req)
	if err == nil {
		t.Fatalf("expected CAPABILITY_UNKNOWN, got success")
	}
	rpcErr, ok := err.(*RPCError)
	if !ok || rpcErr.Code != ErrCapabilityUnknown {
		t.Fatalf("expected CAPABILITY_UNKNOWN, got %v", err)
	}
}

func TestDispatch_CancelledTask_Rejected(t *testing.T) {
	h := newHarness(t)
	h.seed(t, "ir-5", "system.get_status", map[string]interface{}{}, "task-5")
	req := h.validDispatchRequest("task-5", "ir-5", "system.get_status", "user.owner", map[string]interface{}{}, "none")

	c := NewClient(h.socketPath, 2*time.Second)
	if err := c.DevSeedTask(context.Background(), DevSeedTaskRequest{TaskID: "task-5", State: "CANCELLED"}); err != nil {
		t.Fatalf("DevSeedTask cancel: %v", err)
	}
	_, err := c.Dispatch(context.Background(), req)
	if err == nil {
		t.Fatalf("expected CANCELLED, got success")
	}
	rpcErr, ok := err.(*RPCError)
	if !ok || rpcErr.Code != ErrCancelled {
		t.Fatalf("expected CANCELLED, got %v", err)
	}
}

func TestClient_DialFailure_FailsClosed(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "fcb-nolisten-")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	nobodyHome := filepath.Join(dir, "nobody.sock")

	c := NewClient(nobodyHome, 500*time.Millisecond)
	_, err = c.Dispatch(context.Background(), DispatchRequest{})
	if err == nil {
		t.Fatalf("expected a dial error")
	}
}
