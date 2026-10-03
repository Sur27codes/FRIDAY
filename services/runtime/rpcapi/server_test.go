package rpcapi

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"friday/rpcframe"
)

// fakeHealthChecker lets tests control Health() without a real daemon.
type fakeHealthChecker struct {
	ok  bool
	err error
}

func (f fakeHealthChecker) Health(ctx context.Context) (bool, error) { return f.ok, f.err }

// newTestServer builds a Server whose orchestrator field is left nil —
// safe for every test below, since each one exercises a code path that
// returns via writeError BEFORE ever touching s.orch (decode failure,
// unsupported version, missing field, oversized text, or an
// authority-shaped extra field). A real orchestrator is exercised
// separately by the real-process Swift integration suite
// (RuntimeClientIntegrationTests) per docs/PHASE-2-TEST-STRATEGY.md §34.
func newTestServer(policyOK, busOK bool) *Server {
	return &Server{
		policyCheck: fakeHealthChecker{ok: policyOK},
		busCheck:    fakeHealthChecker{ok: busOK},
		actor:       "test.actor",
		sem:         make(chan struct{}, MaxConcurrentRequests),
	}
}

func roundTrip(t *testing.T, s *Server, req Envelope) Envelope {
	t.Helper()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	done := make(chan struct{})
	go func() { s.handleConn(serverConn); close(done) }()

	// net.Pipe() is a fully synchronous, unbuffered connection — a write
	// blocks until the other side is actively reading. A fast-reject
	// path (e.g. the concurrency-bound test) responds and closes the
	// connection WITHOUT ever reading the client's request frame at
	// all, which is legitimate real behavior — over a real Unix socket
	// this doesn't deadlock either side. Writing the request from its
	// own goroutine avoids blocking this helper on that scenario; a
	// resulting "closed pipe" write error in that specific case is
	// expected (the server hung up before reading), not a bug, so it is
	// intentionally not treated as fatal here — only the response this
	// helper actually cares about is asserted on by callers.
	go func() { _ = rpcframe.WriteFrame(clientConn, req) }()

	var resp Envelope
	if err := rpcframe.ReadFrame(clientConn, &resp); err != nil {
		t.Fatalf("read response: %v", err)
	}
	<-done
	return resp
}

func TestHealth_ReadyOnlyWhenBothDependenciesHealthy(t *testing.T) {
	cases := []struct{ policyOK, busOK, wantReady bool }{
		{true, true, true},
		{true, false, false},
		{false, true, false},
		{false, false, false},
	}
	for _, c := range cases {
		s := newTestServer(c.policyOK, c.busOK)
		resp := roundTrip(t, s, Envelope{Method: "Health"})
		if resp.Error != nil {
			t.Fatalf("unexpected error: %+v", resp.Error)
		}
		var health HealthResponseWire
		mustUnmarshal(t, resp.Payload, &health)
		if !health.Alive {
			t.Fatalf("expected Alive=true (the handler ran at all)")
		}
		if health.Ready != c.wantReady {
			t.Fatalf("policyOK=%v busOK=%v: got ready=%v want=%v", c.policyOK, c.busOK, health.Ready, c.wantReady)
		}
	}
}

func TestUnknownMethod_Rejected(t *testing.T) {
	s := newTestServer(true, true)
	resp := roundTrip(t, s, Envelope{Method: "Dispatch"}) // the real Capability Bus method name — must not be recognized here at all
	if resp.Error == nil || resp.Error.Code != ErrUnknownMethod {
		t.Fatalf("expected ErrUnknownMethod, got %+v", resp.Error)
	}
}

func TestSubmitTextRequest_UnsupportedProtocolVersion_Rejected(t *testing.T) {
	s := newTestServer(true, true)
	resp := roundTrip(t, s, submitEnvelope(t, `{"protocol_version":99,"request_id":"r1","text":"check system status"}`))
	if resp.Error == nil || resp.Error.Code != ErrUnsupportedProtocolVersion {
		t.Fatalf("expected ErrUnsupportedProtocolVersion, got %+v", resp.Error)
	}
}

func TestSubmitTextRequest_MissingRequiredFields_Rejected(t *testing.T) {
	s := newTestServer(true, true)
	for _, body := range []string{
		`{"protocol_version":1,"text":"check system status"}`, // missing request_id
		`{"protocol_version":1,"request_id":"r1"}`,            // missing text
		`{}`, // missing everything, including protocol_version
	} {
		resp := roundTrip(t, s, submitEnvelope(t, body))
		if resp.Error == nil {
			t.Fatalf("body %q: expected a rejection, got a response", body)
		}
	}
}

func TestSubmitTextRequest_OversizedText_Rejected(t *testing.T) {
	s := newTestServer(true, true)
	huge := make([]byte, MaxTextRequestBytes+1)
	for i := range huge {
		huge[i] = 'a'
	}
	payload, _ := marshalStruct(SubmitTextRequestWire{ProtocolVersion: 1, RequestID: "r1", Text: string(huge)})
	resp := roundTrip(t, s, Envelope{Method: "SubmitTextRequest", Payload: payload})
	if resp.Error == nil || resp.Error.Code != ErrRequestTooLarge {
		t.Fatalf("expected ErrRequestTooLarge, got %+v", resp.Error)
	}
}

// TestSubmitTextRequest_AuthorityInjection_Rejected is P2-M2's most
// important protocol-level test (instruction §24/§16): a payload
// containing an authority-shaped field alongside otherwise-valid fields
// must be rejected outright by strict decoding, not silently stripped —
// there must be no code path where "aal":4/"authorized":true/
// "skip_policy":true ever reaches anything resembling a decision.
func TestSubmitTextRequest_AuthorityInjection_Rejected(t *testing.T) {
	s := newTestServer(true, true)
	malicious := []string{
		`{"protocol_version":1,"request_id":"r1","text":"create a note called x with y","aal":4}`,
		`{"protocol_version":1,"request_id":"r1","text":"create a note called x with y","authorized":true}`,
		`{"protocol_version":1,"request_id":"r1","text":"do something","capability":"shell.exec"}`,
		`{"protocol_version":1,"request_id":"r1","text":"do something","skip_policy":true}`,
		`{"protocol_version":1,"request_id":"r1","text":"do something","verification":"passed"}`,
	}
	for _, body := range malicious {
		resp := roundTrip(t, s, submitEnvelope(t, body))
		if resp.Error == nil {
			t.Fatalf("body %q: expected rejection of the authority-shaped field, got a response: %+v", body, resp)
		}
		if resp.Error.Code != ErrInvalidRequest {
			t.Fatalf("body %q: expected ErrInvalidRequest, got %+v", body, resp.Error)
		}
	}
}

func TestConcurrencyBound_ExcessRequestsRejectedNotQueuedForever(t *testing.T) {
	s := newTestServer(true, true)
	// Fill the semaphore manually to simulate MaxConcurrentRequests
	// in-flight requests, then confirm one more is rejected immediately
	// rather than the handler blocking indefinitely.
	for i := 0; i < MaxConcurrentRequests; i++ {
		s.sem <- struct{}{}
	}
	defer func() {
		for i := 0; i < MaxConcurrentRequests; i++ {
			<-s.sem
		}
	}()
	resp := roundTrip(t, s, Envelope{Method: "Health"})
	if resp.Error == nil || resp.Error.Code != ErrRuntimeUnavailable {
		t.Fatalf("expected ErrRuntimeUnavailable once the concurrency bound is exhausted, got %+v", resp)
	}
}

func TestMalformedFrame_DoesNotPanic(t *testing.T) {
	s := newTestServer(true, true)
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	done := make(chan struct{})
	go func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("handleConn panicked on malformed input: %v", r)
			}
			close(done)
		}()
		s.handleConn(serverConn)
	}()
	// Write a length prefix claiming far more data than actually follows,
	// then close — this must be treated as a read error, never a panic.
	clientConn.Write([]byte{0x00, 0x00, 0x10, 0x00}) // claims 4096 bytes
	clientConn.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("handleConn did not return after a malformed/truncated frame")
	}
}

// --- test helpers ---

func submitEnvelope(t *testing.T, jsonBody string) Envelope {
	t.Helper()
	return Envelope{Method: "SubmitTextRequest", Payload: []byte(jsonBody)}
}

func marshalStruct(v interface{}) ([]byte, error) {
	return json.Marshal(v)
}

func mustUnmarshal(t *testing.T, raw []byte, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("unmarshal: %v (raw=%s)", err, string(raw))
	}
}
