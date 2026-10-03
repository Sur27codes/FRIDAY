package rpcapi

import (
	"encoding/json"
	"os"
	"testing"
)

// Cross-language golden vectors (P2-M2 instruction §44): the exact same
// three JSON files under testdata/ are read by both this Go test and
// FridayCompanionKitTests' RuntimeClientTests.swift, protecting the
// Swift<->Go wire boundary from accidental drift — if either side's
// struct/type definitions silently change shape, one of the two golden
// tests breaks immediately, rather than the drift only surfacing as a
// confusing runtime failure much later.

func TestGolden_SubmitTextRequest_DecodesToExactExpectedStruct(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_submit_text_request.json")
	if err != nil {
		t.Fatalf("reading golden fixture: %v", err)
	}
	var got SubmitTextRequestWire
	dec := json.NewDecoder(bytesReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&got); err != nil {
		t.Fatalf("decoding golden fixture: %v", err)
	}
	want := SubmitTextRequestWire{
		ProtocolVersion: 1, RequestID: "golden-req-001", CorrelationID: "golden-corr-001",
		Text: "check system status",
	}
	if got != want {
		t.Fatalf("golden request mismatch:\ngot:  %+v\nwant: %+v", got, want)
	}

	// The same fixture must also be independently admitted by the real
	// validation path this milestone's security rests on.
	if _, rpcErr := decodeAndValidateSubmitTextRequest(raw); rpcErr != nil {
		t.Fatalf("golden fixture unexpectedly rejected: %+v", rpcErr)
	}
}

func TestGolden_SubmitTextResponse_EncodesToExactExpectedJSON(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_submit_text_response.json")
	if err != nil {
		t.Fatalf("reading golden fixture: %v", err)
	}
	resp := SubmitTextRequestResponseWire{
		ProtocolVersion: 1, RequestID: "golden-req-001", CorrelationID: "golden-corr-001",
		TaskID: "golden-task-001", Outcome: "SUCCESS", Text: "System status retrieved successfully.",
	}
	encoded, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("encoding: %v", err)
	}
	var gotMap, wantMap map[string]interface{}
	if err := json.Unmarshal(encoded, &gotMap); err != nil {
		t.Fatalf("re-decoding own encoding: %v", err)
	}
	if err := json.Unmarshal(raw, &wantMap); err != nil {
		t.Fatalf("decoding golden fixture: %v", err)
	}
	if len(gotMap) != len(wantMap) {
		t.Fatalf("field count mismatch: got %d fields %+v, want %d fields %+v", len(gotMap), gotMap, len(wantMap), wantMap)
	}
	for k, wantV := range wantMap {
		if gotV, ok := gotMap[k]; !ok || gotV != wantV {
			t.Fatalf("field %q mismatch: got %v, want %v", k, gotV, wantV)
		}
	}
}

func TestGolden_HealthResponse_MatchesRealDaemonShape(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_health_response.json")
	if err != nil {
		t.Fatalf("reading golden fixture: %v", err)
	}
	var got HealthResponseWire
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decoding golden fixture: %v", err)
	}
	if !got.Alive || !got.Ready {
		t.Fatalf("expected the golden fixture to represent a fully healthy daemon, got %+v", got)
	}
}
