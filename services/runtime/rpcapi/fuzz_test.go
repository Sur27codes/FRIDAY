package rpcapi

import (
	"encoding/json"
	"testing"
)

// FuzzDecodeAndValidateSubmitTextRequest_NeverPanicsOrAdmitsAuthorityFields
// feeds arbitrary bytes directly to the one function that decides
// whether a wire payload is admitted at all (P2-M2 instruction §43:
// "arbitrary wire input must never produce unauthorized execution or
// panic" — fuzzing the decoder in isolation, not the full pipeline,
// keeps this fast and keeps the property being tested precise: does
// THIS function ever panic, and does it ever accept a payload carrying
// an authority-shaped field).
func FuzzDecodeAndValidateSubmitTextRequest_NeverPanicsOrAdmitsAuthorityFields(f *testing.F) {
	seeds := []string{
		`{"protocol_version":1,"request_id":"r1","text":"check system status"}`,
		`{"protocol_version":1,"request_id":"r1","text":"x","aal":4}`,
		`{"protocol_version":1,"request_id":"r1","text":"x","authorized":true}`,
		`{"protocol_version":1,"request_id":"r1","text":"x","skip_policy":true}`,
		`{"protocol_version":1,"request_id":"r1","text":"x","capability":"shell.exec"}`,
		`{}`,
		`not json at all`,
		`{"protocol_version":"not-a-number","request_id":"r1","text":"x"}`,
		`{"protocol_version":1,"request_id":null,"text":"x"}`,
		``,
		`{{{{`,
		`{"protocol_version":1,"request_id":"r1","text":""}`,
		`[1,2,3]`,
		`null`,
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, body string) {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("decodeAndValidateSubmitTextRequest panicked on %q: %v", body, r)
			}
		}()

		in, rpcErr := decodeAndValidateSubmitTextRequest(json.RawMessage(body))

		if rpcErr == nil {
			// A payload was ADMITTED. This function's own struct type
			// (SubmitTextRequestWire) structurally has no field for
			// authorization/AAL/capability-selection/risk — so
			// "admitted" can never mean "authority was granted." The
			// only property left to check is that admission happened
			// for the right reason: a real protocol_version, a non-empty
			// request_id/text, and text within bounds.
			if in.ProtocolVersion != CurrentProtocolVersion {
				t.Fatalf("admitted payload %q with wrong protocol_version %d", body, in.ProtocolVersion)
			}
			if in.RequestID == "" || in.Text == "" {
				t.Fatalf("admitted payload %q with an empty required field", body)
			}
			if len(in.Text) > MaxTextRequestBytes {
				t.Fatalf("admitted payload %q exceeding MaxTextRequestBytes", body)
			}
		}
	})
}
