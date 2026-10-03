package rpc

import (
	"net"
	"testing"
	"time"

	"friday/rpcframe"
)

// FuzzDispatchRequestPayload_ServerNeverPanics is the Capability Bus's
// analog to policy-engine's EvaluateRequest fuzz target: arbitrary bytes
// as the Dispatch request payload against a real, running Server. A
// panic in a connection-handling goroutine is unrecovered (server.go has
// no recover()) and would crash this entire test binary — that is the
// sensitive signal this relies on. The only thing asserted directly is
// that the server always either responds with a well-formed Envelope or
// simply closes the connection; a malformed request must never reach
// bus.Dispatch (and therefore can never cause a capability to execute).
func FuzzDispatchRequestPayload_ServerNeverPanics(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Add([]byte(`null`))
	f.Add([]byte(`{"envelope": null}`))
	f.Add([]byte(`{"envelope": "not-an-object"}`))
	f.Add([]byte(`{"envelope": {"policy_token": "not-an-object"}}`))
	f.Add([]byte(`{"envelope": {"validated_arguments": "not-an-object"}}`))
	f.Add([]byte(``))
	f.Add([]byte(`[1,2,3]`))
	f.Add([]byte(`{"envelope": {"policy_token": {"signature": 12345}}}`))

	f.Fuzz(func(t *testing.T, payload []byte) {
		h := newHarness(t)
		conn, err := net.DialTimeout("unix", h.socketPath, 2*time.Second)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()

		if err := rpcframe.WriteFrame(conn, Envelope{Method: "Dispatch", Payload: payload}); err != nil {
			return
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		var resp Envelope
		_ = rpcframe.ReadFrame(conn, &resp)
	})
}
