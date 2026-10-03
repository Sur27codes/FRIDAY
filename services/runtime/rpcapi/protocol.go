// Package rpcapi implements friday-daemon's ONE local, versioned wire
// contract for the native macOS Companion (P2-M2, docs/PHASE-2-SCOPE-LOCK.md
// §5, docs/PHASE-2-ARCHITECTURE.md §5). Same framing as
// friday/policy-engine/internal/rpc and friday/capability-bus/internal/rpc
// (rpcframe: 4-byte length prefix + JSON, one request/response per
// connection) and the same Envelope{Method, Payload, Error} shape — reused
// for consistency, not reinvented (docs/PHASE-2-ARCHITECTURE.md §5's
// "extend the existing Unix-socket JSON-RPC pattern").
//
// This package holds NO business logic and NO authority-bearing fields.
// SubmitTextRequestWire carries exactly protocol_version/request_id/
// correlation_id/text — deliberately nothing resembling an authorization
// decision, an AAL/assurance claim, a capability selection, or a risk
// override (P2-M2 instruction §7: "the client request... Do NOT allow the
// Companion to send authoritative values"). Strict decoding
// (DisallowUnknownFields, see server.go) means a payload that ALSO
// includes such a field is rejected outright, not silently ignored.
package rpcapi

import "encoding/json"

// CurrentProtocolVersion is the only version this daemon accepts.
// Deliberately no compatibility-negotiation machinery yet (§17: "do not
// design elaborate compatibility negotiation yet. Just make future
// evolution possible.") — a request naming any other version is
// rejected deterministically with ErrUnsupportedProtocolVersion.
const CurrentProtocolVersion = 1

// MaxTextRequestBytes bounds the `text` field specifically, reusing the
// exact same bound `textrequest.MaxRawTextBytes` already establishes for
// Phase-1 text input (M5-INTENT-008) — not a new, second limit that could
// drift from the one the Intent Compiler itself enforces.
const MaxTextRequestBytes = 20000

// Envelope is the generic request/response wrapper written over
// rpcframe — mirrors rpc.Envelope in policy-engine/capability-bus exactly
// (Method distinguishes the RPC method; Error is populated only for
// transport/request-level failures, never for an ordinary non-success
// Outcome, which is a well-formed SubmitTextRequestResponseWire).
type Envelope struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// ErrorCode is the structured RPC-level error taxonomy for failures of
// the RPC call itself (transport, malformed/oversized/unsupported
// request) — distinct from an ordinary non-SUCCESS response.Outcome,
// which travels inside a well-formed SubmitTextRequestResponseWire (P2-M2
// instruction §38 — reusing the EXISTING response.Outcome taxonomy for
// "the request was understood but the answer isn't success," and adding
// only the small set of codes below for "the request itself couldn't be
// understood/served at all").
type ErrorCode string

const (
	ErrInvalidRequest             ErrorCode = "INVALID_REQUEST"
	ErrUnsupportedProtocolVersion ErrorCode = "UNSUPPORTED_PROTOCOL_VERSION"
	ErrRequestTooLarge            ErrorCode = "REQUEST_TOO_LARGE"
	ErrUnknownMethod              ErrorCode = "UNKNOWN_METHOD"
	ErrRuntimeUnavailable         ErrorCode = "RUNTIME_UNAVAILABLE"
	ErrInternalSafeError          ErrorCode = "INTERNAL_SAFE_ERROR"
)

// RPCError is returned over the wire for request-level failures — never
// for an ordinary denied/failed/unsupported outcome, which is a normal
// SubmitTextRequestResponseWire with a non-SUCCESS Outcome. Message is
// deliberately generic/safe (§9, §36: no stack traces, no internal
// configuration, no secrets ever cross this boundary).
type RPCError struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

func (e *RPCError) Error() string { return string(e.Code) + ": " + e.Message }

// HealthResponseWire mirrors the exact shape policy-engine/capability-bus
// already use for Health (`{"alive":true,"ready":true}`) — Ready here
// additionally reflects the daemon's real, live-checked dependency
// contract (Policy Engine reachable+ready, Capability Bus reachable+ready,
// runtime store opened) — never merely "the socket is listening" (§11).
type HealthResponseWire struct {
	Alive bool `json:"alive"`
	Ready bool `json:"ready"`
}

// SubmitTextRequestWire is the ENTIRE client-supplied input for a text
// request. Every field here is either protocol bookkeeping (version) or
// an identifier the server does not trust as evidence of anything
// (request_id/correlation_id are echoed back for correlation only, exactly
// as a client-supplied nonce would be — they carry no authority). `Text`
// is untrusted natural-language input, handled downstream exactly as
// friday/cognitive-core/textrequest.TextRequest.RawText already is —
// never executed as a command, template, or code.
//
// Deliberately absent, per P2-M2 instruction §7: authorized, an
// authorization token, a policy decision, a granted scope, a requested
// capability as an execution instruction, a risk override, an AAL/minimum-
// AAL override, a trusted-authentication-result claim, private signing
// material, a verification result, or a final task state. Strict decoding
// (server.go) rejects a payload containing any such extra field rather
// than silently dropping it.
type SubmitTextRequestWire struct {
	ProtocolVersion int    `json:"protocol_version"`
	RequestID       string `json:"request_id"`
	CorrelationID   string `json:"correlation_id"`
	Text            string `json:"text"`
}

// SubmitTextRequestResponseWire is the ENTIRE server response — a direct,
// field-for-field mirror of the existing, already-verification-gated
// friday/runtime/response.Response (Outcome, TaskID, Text), plus the
// request's own echoed identifiers. Nothing here is computed independently
// of that existing type — this package never manufactures a SUCCESS
// outcome itself (P2-M2 instruction §10).
type SubmitTextRequestResponseWire struct {
	ProtocolVersion int    `json:"protocol_version"`
	RequestID       string `json:"request_id"`
	CorrelationID   string `json:"correlation_id"`
	TaskID          string `json:"task_id"`
	Outcome         string `json:"outcome"`
	Text            string `json:"text"`
}
