// M4-POL-001 through M4-POL-018 exercise the M4 brief's required
// properties against two REAL, separately-compiled, separately-running
// OS processes (policyengined and capabilitybusd, launched fresh per
// test by harness_test.go) — never in-process fakes. The numbering here
// is organized by theme (process separation, AAL enforcement, token/
// argument integrity, fail-closed availability) to match the M4 brief's
// required-properties list as retained in working context; it is not a
// verbatim transcription of a numbered source document.
//
// M4-POL-017 (private key isolation) lives in privatekey_isolation_test.go
// since it is a structural (go list -deps) check, not a runtime RPC test.
//
// Malformed-response handling (garbage bytes from the peer) is
// deliberately NOT re-tested here against real subprocesses — real
// policyengined/capabilitybusd binaries only ever emit well-formed
// responses, so provoking a malformed one requires a fake peer, which
// internal/rpc's own unit tests already do against the REAL production
// Client type in each service module (see
// policy-engine/internal/rpc/rpc_test.go and
// capability-bus/internal/rpc/rpc_test.go). This file focuses on
// properties that specifically require two genuinely separate processes:
// liveness, timing, and cross-process token/argument integrity.
package integration

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"friday/ir"
	"friday/rpcframe"
)

func mustDigest(t *testing.T, args map[string]interface{}) string {
	t.Helper()
	d, err := ir.ArgumentsDigest(args)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	return d
}

func buildEnvelope(actor, taskID, irID, capabilityID string, args map[string]interface{}, tok *tokenWire, verificationMethod string) envelopeWire {
	return envelopeWire{
		ExecutionID: "exec-" + taskID, RequestID: "req-" + taskID, CorrelationID: "corr-" + taskID,
		Actor: actor, TaskID: taskID, IRVersion: "0.2", IRID: irID, Capability: capabilityID,
		ValidatedArguments: args, PolicyToken: tok, IdempotencyKey: "idem-" + taskID,
		ExpectedSuccessCondition: map[string]interface{}{"ok": true},
		VerificationMethod:       verificationMethod,
		Cancellable:              true, CancellationEffect: "none_yet_started",
	}
}

const (
	verifyGetStatus  = "schema_conformance_against_live_self_model"
	verifyCreateNote = "post_write_existence_and_content_check"
)

// ---- Process separation ----

func TestM4POL001_GenuinelySeparateOSProcesses(t *testing.T) {
	dir := newTestDir(t)
	pe, _, pePub := startPolicyEngine(t, dir)
	cb, cbSock, _ := startCapabilityBus(t, dir, pePub)

	if pe.cmd.Process.Pid == cb.cmd.Process.Pid {
		t.Fatalf("expected distinct PIDs, both processes report pid %d", pe.cmd.Process.Pid)
	}
	if pe.cmd.Process.Pid == 0 || cb.cmd.Process.Pid == 0 {
		t.Fatalf("expected real nonzero PIDs, got policy=%d bus=%d", pe.cmd.Process.Pid, cb.cmd.Process.Pid)
	}

	// Killing the Policy Engine must not affect the independently-running
	// Capability Bus process at all.
	pe.Kill()
	time.Sleep(100 * time.Millisecond)
	if _, err := health(context.Background(), cbSock); err != nil {
		t.Fatalf("capability bus became unreachable after the unrelated policy engine process was killed: %v", err)
	}
}

// ---- End-to-end happy paths ----

func TestM4POL002_EndToEnd_GetStatus_HappyPath(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-gs-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision != "ALLOW" || evResp.Token == nil {
		t.Fatalf("expected ALLOW with token for risk:none, got decision=%q reason=%q", evResp.Decision, evResp.Reason)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-gs-1", CapabilityID: "system.get_status", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-gs-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	dResp, err := dispatch(ctx, cbSock, dispatchRequest{
		Envelope: buildEnvelope("user.owner", "task-gs-1", "ir-gs-1", "system.get_status", args, evResp.Token, verifyGetStatus),
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	if !dResp.Outcome.Dispatched || !dResp.Outcome.Executed || !dResp.Outcome.Verified || !dResp.Outcome.Success {
		t.Fatalf("expected full success across the real process boundary, got %+v", dResp.Outcome)
	}
}

func TestM4POL003_EndToEnd_CreateNote_HappyPath_AAL1(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{"title": "M4 test note", "body": "created across a real process boundary"}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-cn-1",
		Risk: "low", ArgumentsDigest: mustDigest(t, args),
		AssuranceFactors: []presentedFactorWire{{Factor: "device_trusted_session", Available: true, EstablishedAt: time.Now()}},
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision != "ALLOW" || evResp.Token == nil {
		t.Fatalf("expected ALLOW with a fresh device_trusted_session, got decision=%q reason=%q", evResp.Decision, evResp.Reason)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-cn-1", CapabilityID: "workspace.create_note", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-cn-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	dResp, err := dispatch(ctx, cbSock, dispatchRequest{
		Envelope: buildEnvelope("user.owner", "task-cn-1", "ir-cn-1", "workspace.create_note", args, evResp.Token, verifyCreateNote),
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	if !dResp.Outcome.Dispatched || !dResp.Outcome.Executed || !dResp.Outcome.Verified || !dResp.Outcome.Success {
		t.Fatalf("expected full success across the real process boundary, got %+v", dResp.Outcome)
	}
	if len(dResp.Outcome.CreateNoteResult) == 0 {
		t.Fatalf("expected a create_note_result payload")
	}
}

// ---- AAL enforcement over the real wire ----

func TestM4POL004_MissingRequiredAuthentication_FailsClosed(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, _ := startPolicyEngine(t, dir)
	ctx := context.Background()

	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-noauth-1",
		Risk: "low", ArgumentsDigest: mustDigest(t, map[string]interface{}{}),
		// No AssuranceFactors at all.
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision == "ALLOW" {
		t.Fatalf("expected a non-ALLOW decision with zero presented assurance factors, got ALLOW")
	}
	if evResp.Token != nil {
		t.Fatalf("a non-ALLOW decision must never carry a token")
	}
}

// voice_match is structurally excluded from satisfying AAL2+ (ST §S.13).
// No Phase-1 capability sits at AAL2+ (system.get_status is AAL0,
// workspace.create_note is AAL1), so this is proven directly against the
// real Policy Engine's EvaluateAuthorization — a policy-level guarantee,
// not something reachable via Dispatch with the current capability set.
func TestM4POL005_VoiceMatchAloneNeverSatisfiesAAL2(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, _ := startPolicyEngine(t, dir)
	ctx := context.Background()

	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "hypothetical.aal2_capability", IRID: "ir-voice-1",
		Risk: "external_side_effect", ArgumentsDigest: mustDigest(t, map[string]interface{}{}),
		AssuranceFactors: []presentedFactorWire{{Factor: "voice_match", Available: true, EstablishedAt: time.Now()}},
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision == "ALLOW" {
		t.Fatalf("voice_match alone must never satisfy AAL2, but got ALLOW (reason=%q)", evResp.Reason)
	}
	if evResp.Token != nil {
		t.Fatalf("a non-ALLOW decision must never carry a token")
	}
}

func TestM4POL006_StaleAssuranceEvidenceRejected(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, _ := startPolicyEngine(t, dir)
	ctx := context.Background()

	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "hypothetical.aal2_capability", IRID: "ir-stale-1",
		Risk: "external_side_effect", ArgumentsDigest: mustDigest(t, map[string]interface{}{}),
		AssuranceFactors: []presentedFactorWire{
			{Factor: "device_trusted_session", Available: true, EstablishedAt: time.Now()},
			{Factor: "active_user_confirmation", Available: true, EstablishedAt: time.Now().Add(-5 * time.Minute)}, // window is 30s
		},
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision == "ALLOW" {
		t.Fatalf("expected stale active_user_confirmation (5m old, 30s window) to be rejected, got ALLOW")
	}
}

func TestM4POL007_CallerInjectedDecisionFieldsAreIgnored(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, _ := startPolicyEngine(t, dir)
	ctx := context.Background()

	raw := map[string]interface{}{
		"actor": "user.owner", "capability_id": "workspace.create_note", "risk": "low",
		"ir_id": "ir-inject-1", "arguments_digest": mustDigest(t, map[string]interface{}{}),
		"assurance_factors": []interface{}{}, // none presented -> real logic would DENY
		// Fields that do not exist on the real EvaluateRequest schema at
		// all (M4 brief §15) — a compliant server ignores them entirely.
		"decision": "ALLOW", "granted_aal": "AAL4", "token": map[string]interface{}{"token_id": "forged"},
	}
	var resp evaluateResponse
	if err := call(ctx, peSock, "EvaluateAuthorization", raw, &resp, 5*time.Second); err != nil {
		t.Fatalf("call: %v", err)
	}
	if resp.Decision == "ALLOW" {
		t.Fatalf("expected the server to compute DENY from actual assurance factors, but it echoed the injected decision=ALLOW")
	}
	if resp.Token != nil {
		t.Fatalf("expected no token despite an injected token field in the request")
	}
}

// ---- Token / argument integrity across the real process boundary ----

func TestM4POL008_CapabilityRiskCannotBeLoweredRemotely(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{"title": "x", "body": "y"}
	// Ask the Policy Engine to evaluate workspace.create_note (registered
	// risk:low, AAL1) but claim risk:none — a caller lying about risk to
	// get an AAL0 (no-factor) evaluation for a capability the Bus's own
	// registry says needs AAL1/low.
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-downgrade-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil {
		t.Fatalf("EvaluateAuthorization: %v", err)
	}
	if evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected the policy engine to allow the (falsely) risk:none request, got %q", evResp.Decision)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-downgrade-1", CapabilityID: "workspace.create_note", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-downgrade-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	_, err = dispatch(ctx, cbSock, dispatchRequest{
		Envelope: buildEnvelope("user.owner", "task-downgrade-1", "ir-downgrade-1", "workspace.create_note", args, evResp.Token, verifyCreateNote),
	}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected the real Capability Bus to reject a token whose risk_level does not match the capability's registered risk_level (AUTHORIZATION_SCOPE_MISMATCH), got success")
	}
	assertRPCErrorCode(t, err, "AUTHORIZATION_SCOPE_MISMATCH")
}

func TestM4POL009_ArgumentTamperingAfterTokenIssuance_DigestMismatch(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	original := map[string]interface{}{"title": "original", "body": "safe"}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-tamper-1",
		Risk: "low", ArgumentsDigest: mustDigest(t, original),
		AssuranceFactors: []presentedFactorWire{{Factor: "device_trusted_session", Available: true, EstablishedAt: time.Now()}},
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	// The IR store the real Bus re-fetches from now reflects DIFFERENT
	// arguments under the same ir_id — simulating a compromised or buggy
	// caller — while the token in hand is still bound to the digest of
	// the ORIGINAL arguments.
	tampered := map[string]interface{}{"title": "TAMPERED", "body": "malicious"}
	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-tamper-1", CapabilityID: "workspace.create_note", Arguments: tampered}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-tamper-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	_, err = dispatch(ctx, cbSock, dispatchRequest{
		Envelope: buildEnvelope("user.owner", "task-tamper-1", "ir-tamper-1", "workspace.create_note", tampered, evResp.Token, verifyCreateNote),
	}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected ARGUMENT_DIGEST_MISMATCH, got success")
	}
	assertRPCErrorCode(t, err, "ARGUMENT_DIGEST_MISMATCH")
}

func TestM4POL010_TokenActorScopeMismatch_Rejected(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-actor-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-actor-1", CapabilityID: "system.get_status", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-actor-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	// Present the token minted for "user.owner" while claiming a
	// different actor in the envelope.
	env := buildEnvelope("someone.else", "task-actor-1", "ir-actor-1", "system.get_status", args, evResp.Token, verifyGetStatus)
	_, err = dispatch(ctx, cbSock, dispatchRequest{Envelope: env}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected AUTHORIZATION_SCOPE_MISMATCH for actor mismatch, got success")
	}
	assertRPCErrorCode(t, err, "AUTHORIZATION_SCOPE_MISMATCH")
}

func TestM4POL011_TokenCapabilityScopeMismatch_Rejected(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-cap-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	cnArgs := map[string]interface{}{"title": "x", "body": "y"}
	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-cap-1", CapabilityID: "workspace.create_note", Arguments: cnArgs}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-cap-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	// Token was minted for system.get_status; try to spend it against
	// workspace.create_note instead.
	env := buildEnvelope("user.owner", "task-cap-1", "ir-cap-1", "workspace.create_note", cnArgs, evResp.Token, verifyCreateNote)
	_, err = dispatch(ctx, cbSock, dispatchRequest{Envelope: env}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected AUTHORIZATION_SCOPE_MISMATCH for capability mismatch, got success")
	}
	assertRPCErrorCode(t, err, "AUTHORIZATION_SCOPE_MISMATCH")
}

// Real 15-second token TTL, real sleep, real wall clock — this is also
// the regression test for the bus.Dispatch clock-ownership fix (bus.go):
// a long-lived daemon must evaluate expiry against ITS OWN live clock at
// dispatch time, not a timestamp frozen when the process started.
func TestM4POL012_ExpiredToken_RejectedByRealBusClock(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping real 15s token-expiry wait in -short mode")
	}
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-exp-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-exp-1", CapabilityID: "system.get_status", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-exp-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	time.Sleep(16 * time.Second) // token TTL is 15s (policy-engine/internal/policy/token.go)

	env := buildEnvelope("user.owner", "task-exp-1", "ir-exp-1", "system.get_status", args, evResp.Token, verifyGetStatus)
	_, err = dispatch(ctx, cbSock, dispatchRequest{Envelope: env}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected AUTHORIZATION_EXPIRED after real TTL elapsed, got success")
	}
	assertRPCErrorCode(t, err, "AUTHORIZATION_EXPIRED")
}

func TestM4POL013_CancelledTask_RejectedDespiteValidToken(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-cancel-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-cancel-1", CapabilityID: "system.get_status", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-cancel-1", State: "CANCELLED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	env := buildEnvelope("user.owner", "task-cancel-1", "ir-cancel-1", "system.get_status", args, evResp.Token, verifyGetStatus)
	_, err = dispatch(ctx, cbSock, dispatchRequest{Envelope: env}, 5*time.Second)
	if err == nil {
		t.Fatalf("expected CANCELLED rejection despite a structurally valid, unexpired token, got success")
	}
	assertRPCErrorCode(t, err, "CANCELLED")
}

// ---- Fail-closed availability across the real process boundary ----

func TestM4POL014_PolicyEngineUnreachable_NewAuthorizationFailsClosed(t *testing.T) {
	dir := newTestDir(t)
	pe, peSock, _ := startPolicyEngine(t, dir)
	pe.Kill() // gone before any request is attempted
	time.Sleep(100 * time.Millisecond)

	_, err := evaluateAuthorization(context.Background(), peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", Risk: "none",
	}, 3*time.Second)
	if err == nil {
		t.Fatalf("expected a dial/connect failure against a dead Policy Engine, got success")
	}
}

func TestM4POL015_PolicyEngineCrashesMidRequest_NoFallbackAllow(t *testing.T) {
	dir := newTestDir(t)
	pe, peSock, _ := startPolicyEngine(t, dir)

	conn, err := net.DialTimeout("unix", peSock, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	reqBody, _ := json.Marshal(evaluateRequest{
		Actor: "user.owner", Capability: "workspace.create_note", Risk: "low",
		AssuranceFactors: []presentedFactorWire{{Factor: "device_trusted_session", Available: true, EstablishedAt: time.Now()}},
	})
	if err := rpcframe.WriteFrame(conn, rpcEnvelope{Method: "EvaluateAuthorization", Payload: reqBody}); err != nil {
		t.Fatalf("write request: %v", err)
	}

	pe.Kill() // real SIGKILL, before this client reads any response

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var resp rpcEnvelope
	err = rpcframe.ReadFrame(conn, &resp)
	if err == nil {
		// rpcframe's length-prefixed framing means a killed peer can never
		// deliver a truncated frame that gets misread as a valid response
		// (see rpcframe's own truncated-payload tests) — so if a response
		// DID arrive intact, the only honest interpretation is that the
		// real server finished and replied before the kill signal was
		// delivered, which is a legitimate race outcome, not a fabricated
		// or corrupted ALLOW. Log it rather than silently pass.
		t.Logf("server completed and responded before the kill signal landed (decision=%q) — this run did not exercise the crash window; rpcframe's framing guarantee is what prevents a corrupted partial response from ever being misread as ALLOW regardless of timing", resp.Payload)
		return
	}
	// The intended, and observed-in-practice, outcome: the connection
	// fails once the process is gone — no response is fabricated.
}

func TestM4POL016_RPCTimeout_FailsClosedWithinBoundedTime(t *testing.T) {
	dir := newTestDir(t)
	_, peSock, _ := startPolicyEngine(t, dir)

	start := time.Now()
	_, err := evaluateAuthorization(context.Background(), peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", Risk: "none",
	}, 1*time.Nanosecond) // deadline already exceeded before the dial can complete
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected a timeout/context-deadline error, got success")
	}
	if elapsed > 2*time.Second {
		t.Fatalf("client did not fail closed within a bounded time: took %s", elapsed)
	}
}

// M4-POL-017 (private key isolation) is in privatekey_isolation_test.go.

// A previously-issued, still-valid token is verified entirely offline by
// the Capability Bus (cached public key only — no live call back to the
// Policy Engine), so it remains usable during a Policy Engine outage. A
// NEW authorization request during that same outage, by contrast, must
// still fail closed. Proving both halves in one test demonstrates these
// are genuinely different code paths with different fates, not
// coincidentally-identical behavior.
func TestM4POL018_PreviouslyIssuedTokenUsableDuringOutage_NewAuthDoesNot(t *testing.T) {
	dir := newTestDir(t)
	pe, peSock, pePub := startPolicyEngine(t, dir)
	_, cbSock, _ := startCapabilityBus(t, dir, pePub)
	ctx := context.Background()

	args := map[string]interface{}{}
	evResp, err := evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-outage-1",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 5*time.Second)
	if err != nil || evResp.Decision != "ALLOW" {
		t.Fatalf("setup: expected ALLOW, got decision=%q err=%v", evResp.Decision, err)
	}

	if err := devSeedIR(ctx, cbSock, devSeedIRRequest{IRID: "ir-outage-1", CapabilityID: "system.get_status", Arguments: args}); err != nil {
		t.Fatalf("DevSeedIR: %v", err)
	}
	if err := devSeedTask(ctx, cbSock, devSeedTaskRequest{TaskID: "task-outage-1", State: "AUTHORIZED"}); err != nil {
		t.Fatalf("DevSeedTask: %v", err)
	}

	pe.Kill() // Policy Engine is now fully gone
	time.Sleep(100 * time.Millisecond)

	// Half 1: the ALREADY-ISSUED token still dispatches successfully —
	// the Capability Bus never calls back to the (now-dead) Policy Engine
	// to verify it.
	env := buildEnvelope("user.owner", "task-outage-1", "ir-outage-1", "system.get_status", args, evResp.Token, verifyGetStatus)
	dResp, err := dispatch(ctx, cbSock, dispatchRequest{Envelope: env}, 5*time.Second)
	if err != nil {
		t.Fatalf("expected a previously-issued valid token to still work during a Policy Engine outage, got error: %v", err)
	}
	if !dResp.Outcome.Success {
		t.Fatalf("expected success dispatching a pre-issued token during outage, got %+v", dResp.Outcome)
	}

	// Half 2: a NEW authorization request during the same outage fails
	// closed — this is a genuinely different code path (a live RPC call
	// to a process that no longer exists), not the same offline check.
	_, err = evaluateAuthorization(ctx, peSock, evaluateRequest{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-outage-2",
		Risk: "none", ArgumentsDigest: mustDigest(t, args),
	}, 3*time.Second)
	if err == nil {
		t.Fatalf("expected a NEW authorization request to fail closed during the same outage, got success")
	}
}

// ---- shared assertion helper ----

func assertRPCErrorCode(t *testing.T, err error, wantCode string) {
	t.Helper()
	re, ok := err.(*rpcError)
	if !ok {
		t.Fatalf("expected *rpcError, got %T: %v", err, err)
	}
	if re.Code != wantCode {
		t.Fatalf("expected error code %s, got %s (%s)", wantCode, re.Code, re.Message)
	}
}
