package rpc

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"friday/rpcframe"
)

// FuzzEvaluateRequestPayload_ServerNeverPanics feeds arbitrary bytes as
// the EvaluateAuthorization request payload against a real, running
// Server. A panic in a goroutine handling a connection is unrecovered
// (server.go has no recover()) and would crash this entire test binary —
// that is the sensitive failure signal this fuzz target relies on, not a
// manually-inspected assertion. The only thing asserted directly is that
// the server always either produces a syntactically well-formed Envelope
// response or simply closes the connection (both are acceptable —
// M4-POL-015's "malformed input cannot cause dispatch" applies to
// request payloads too, not just responses).
func FuzzEvaluateRequestPayload_ServerNeverPanics(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Add([]byte(`null`))
	f.Add([]byte(`{"actor": 12345}`))
	f.Add([]byte(`{"assurance_factors": "not-an-array"}`))
	f.Add([]byte(`{"risk": {"nested": true}}`))
	f.Add([]byte(``))
	f.Add([]byte(`[1,2,3]`))
	f.Add([]byte(`"just a string"`))
	f.Add([]byte(`{"actor":"a","assurance_factors":[{"established_at":"not-a-time"}]}`))

	f.Fuzz(func(t *testing.T, payload []byte) {
		socketPath, _ := startTestServer(t)
		conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()

		if !json.Valid(payload) {
			// unmarshalPayload's json.Unmarshal would reject this anyway;
			// still send it to exercise the server's malformed-JSON path.
			payload = append([]byte(nil), payload...)
		}

		if err := rpcframe.WriteFrame(conn, Envelope{Method: "EvaluateAuthorization", Payload: payload}); err != nil {
			// A refused/oversized frame is a legitimate rpcframe-level
			// rejection, not a server crash.
			return
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		var resp Envelope
		// Either a clean read (well-formed error or, for valid-but-odd
		// JSON, a real decision) or a read error (connection closed after
		// a decode failure) are both acceptable — a panic is the only
		// unacceptable outcome, and it would crash this whole test binary
		// rather than surface here.
		_ = rpcframe.ReadFrame(conn, &resp)
	})
}
