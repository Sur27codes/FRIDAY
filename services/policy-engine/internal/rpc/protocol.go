// Package rpc implements the Policy Engine's ONE remote method,
// EvaluateAuthorization, over a Unix domain socket (ADR-021: "local gRPC
// (or Unix-domain-socket) contract" — M4 implements the Unix-domain-socket
// option, using JSON framing consistent with ADR-015's wire-format
// choice, rather than introducing a second wire format and a protobuf
// toolchain dependency neither is needed to satisfy any M4 requirement).
//
// Per the M4 brief §15, this is deliberately NOT a signing oracle: there
// is no SignToken(claims) method anywhere in this package. The only
// request shape is EvaluateRequest — a set of OBSERVED FACTS (actor,
// capability, risk, assurance factors as presented, purpose, cancellation
// state) — never a pre-decided decision, a pre-computed AAL, a granted
// scope, or an expiry. Every one of those is computed by the server from
// policy.Engine.Evaluate, unchanged from M1, never taken from the
// request.
package rpc

import (
	"encoding/json"
	"time"
)

// PresentedFactorWire mirrors policy.PresentedFactor for the wire —
// EstablishedAt is caller-observed (when the factor was collected), but
// the server's own clock (not any client-supplied "now") is what's used
// to judge freshness (see server.go) — a client cannot claim a factor is
// fresher than it actually is by lying about the server's evaluation
// time, because the server never accepts one.
type PresentedFactorWire struct {
	Factor        string    `json:"factor"`
	EstablishedAt time.Time `json:"established_at"`
	Available     bool      `json:"available"`
}

// EvaluateRequest is the only input shape this service accepts. Every
// field is an observed fact about the request being evaluated — there is
// no field for "decision", "granted_aal", "token", or "expiry": the
// server alone computes those (M4 brief §15's "the caller must not
// decide: granted scope, granted AAL, expiry beyond policy, issuer,
// authorization decision, risk downgrade").
type EvaluateRequest struct {
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`
	TaskID        string `json:"task_id"`
	IRID          string `json:"ir_id"`

	Actor string `json:"actor"`

	Capability        string `json:"capability_id"`
	CapabilityVersion string `json:"capability_version"`

	Purpose         string `json:"purpose"`
	Risk            string `json:"risk"` // policy.RiskLevel string value
	ArgumentsDigest string `json:"arguments_digest"`

	AssuranceFactors []PresentedFactorWire `json:"assurance_factors"`

	AutonomyLevelConfigured int  `json:"autonomy_level_configured"`
	SimulatorVerified       bool `json:"simulator_verified"`
	TaskCancelled           bool `json:"task_cancelled"`
}

// TokenWire mirrors policytoken.PolicyToken for the wire.
type TokenWire struct {
	TokenID         string    `json:"token_id"`
	IRID            string    `json:"ir_id"`
	CapabilityID    string    `json:"capability_id"`
	Actor           string    `json:"actor"`
	RiskLevel       string    `json:"risk_level"`
	Purpose         string    `json:"purpose"`
	ArgumentsDigest string    `json:"arguments_digest"`
	IssuedAt        time.Time `json:"issued_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	Signature       []byte    `json:"signature"`
}

// EvaluateResponse is the only output shape. Token is present if and
// only if Decision == "ALLOW" — a client MUST treat any other
// combination (ALLOW with a nil token, or a non-ALLOW decision with a
// non-nil token) as a malformed response, per M4-POL-016, and fail
// closed rather than guess which field to trust.
type EvaluateResponse struct {
	RequestID     string `json:"request_id"`
	CorrelationID string `json:"correlation_id"`

	Decision    string `json:"decision"`
	RequiredAAL string `json:"required_aal"`
	Reason      string `json:"reason"`

	Token *TokenWire `json:"token,omitempty"`
}

// ErrorCode is the structured RPC-level error taxonomy (M4 brief §19).
// Distinct from EvaluateResponse.Decision == "DENY", which is a valid,
// well-formed policy decision — ErrorCode is for failures of the RPC
// call itself (transport, malformed request, service unavailable), which
// callers must also treat as non-authorization (fail closed), just via a
// different code path than an explicit DENY.
type ErrorCode string

const (
	ErrPolicyUnavailable          ErrorCode = "POLICY_UNAVAILABLE"
	ErrAuthenticationInsufficient ErrorCode = "AUTHENTICATION_INSUFFICIENT"
	ErrExecutionEnvelopeInvalid   ErrorCode = "EXECUTION_ENVELOPE_INVALID" // malformed request
)

// RPCError is returned over the wire for request-level failures (never
// for an ordinary policy DENY, which is a normal EvaluateResponse).
type RPCError struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

func (e *RPCError) Error() string { return string(e.Code) + ": " + e.Message }

// Envelope is the generic request/response wrapper written over
// rpcframe — Method distinguishes the (currently single) RPC method so
// the wire format can add methods later (e.g., a future Health check,
// M4 §18) without changing the framing layer.
type Envelope struct {
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}
