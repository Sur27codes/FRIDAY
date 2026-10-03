// Package policytoken is the shared, non-internal contract between the
// Policy Engine (which mints tokens) and any component that must verify
// them (the Capability Bus, from M3 onward). It exists specifically
// because Go's `internal/` visibility rule prevents a separate module
// (services/capability-bus) from importing types defined under
// services/policy-engine/internal/policy — and pre-M4 there is no gRPC
// boundary yet to carry the token over instead. See
// docs/E-traceability-matrix.md's M3 section for the full disclosure of
// why this module was introduced during M3, not anticipated in the
// original M1 layout.
//
// This package intentionally contains NO signing capability. There is no
// Signer type, no NewKeyPair, no Issue function here — only Ed25519
// verification. Minting a token requires services/policy-engine's
// internal Signer, which this package's importers (including
// capability-bus) have no import path to at all. That is the concrete
// mechanism behind "the Capability Bus must never hold the Policy
// Engine's private signing key" (ST §S.2.1) and "the Bus cannot mint
// authorization" (M3 brief §5) — not a convention, a compile-time fact.
package policytoken

import (
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"time"
)

// RiskLevel mirrors FRIDAY IR's risk.level field and
// services/policy-engine's equivalent type. Duplicated deliberately, same
// rationale as services/ir's copy (module independence over a shared
// import) — the values must match by string content for signature
// verification to succeed across modules, which is tested explicitly
// (see the cross-module digest test added in M3).
type RiskLevel string

const (
	RiskNone               RiskLevel = "none"
	RiskLow                RiskLevel = "low"
	RiskExternalSideEffect RiskLevel = "external_side_effect"
	RiskHigh               RiskLevel = "high"
	RiskCritical           RiskLevel = "critical"
)

// PolicyToken is the signed authorization artifact (ST §S.2.1). Field-for-
// field identical to services/policy-engine/internal/policy's type — this
// is now the single source of truth for its shape; policy-engine's Signer
// constructs values of this exact type.
type PolicyToken struct {
	TokenID         string    `json:"token_id"`
	IRID            string    `json:"ir_id"`
	CapabilityID    string    `json:"capability_id"`
	Actor           string    `json:"actor"`
	RiskLevel       RiskLevel `json:"risk_level"`
	Purpose         string    `json:"purpose"`
	ArgumentsDigest string    `json:"arguments_digest"`
	IssuedAt        time.Time `json:"issued_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	Signature       []byte    `json:"signature"`
}

// SigningPayload returns the canonical byte representation that is signed
// and verified — exported (unlike M1's original unexported
// signingPayload) because both the Signer (in policy-engine) and Verifier
// (here) must compute the identical payload independently.
func (t PolicyToken) SigningPayload() ([]byte, error) {
	unsigned := t
	unsigned.Signature = nil
	return json.Marshal(unsigned)
}

// Verifier holds only an Ed25519 public key. There is no way to obtain a
// Verifier that also lets you sign — construct one with NewVerifier from
// a public key you already have (e.g., read from the local
// key-distribution file at process startup, ST §S.2.1).
type Verifier struct {
	pub ed25519.PublicKey
}

// NewVerifier constructs a Verifier from a raw Ed25519 public key.
func NewVerifier(pub ed25519.PublicKey) Verifier {
	return Verifier{pub: pub}
}

// PublicKeyBytes returns the raw Ed25519 public key bytes — safe to
// expose and serialize (that is the entire point of a public key), used
// by the Policy Engine daemon (M4) to publish its key to the local
// key-distribution file the Capability Bus daemon reads at its own
// startup (ST §S.2.1). This is the only piece of key material this
// package ever writes to a byte slice a caller could persist — there is
// no equivalent accessor for private key material anywhere in this
// module, because this module never holds any.
func (v Verifier) PublicKeyBytes() []byte {
	out := make([]byte, len(v.pub))
	copy(out, v.pub)
	return out
}

// ValidationRequest carries everything Verifier.Validate needs to run all
// 6 checks from ST §S.2.1 / the M3 brief's expanded list. Identical shape
// to M1's original type.
type ValidationRequest struct {
	Token              *PolicyToken
	Now                time.Time
	ExpectedIRID       string
	ExpectedCapability string
	ExpectedActor      string
	ExpectedArgsDigest string
	LiveConsentPurpose string
	TaskCancelled      bool
}

// ValidationError distinguishes each check so callers can assert on
// exactly which one failed.
type ValidationError struct {
	Check  string
	Reason string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("policy token validation failed at check %q: %s", e.Check, e.Reason)
}

// Validate runs all 6 checks from ST §S.2.1, in order, short-circuiting on
// the first failure — byte-for-byte the same logic M1 originally had,
// relocated here so a second module can call it.
func (v Verifier) Validate(req ValidationRequest) error {
	if req.Token == nil {
		return &ValidationError{Check: "presence", Reason: "no token presented"}
	}

	payload, err := req.Token.SigningPayload()
	if err != nil {
		return &ValidationError{Check: "6a_signature", Reason: "cannot reconstruct signing payload: " + err.Error()}
	}
	if !ed25519.Verify(v.pub, payload, req.Token.Signature) {
		return &ValidationError{Check: "6a_signature", Reason: "signature invalid"}
	}

	if !req.Now.Before(req.Token.ExpiresAt) {
		return &ValidationError{Check: "6b_expiry", Reason: "token expired"}
	}

	if req.Token.IRID != req.ExpectedIRID {
		return &ValidationError{Check: "6c_scope", Reason: "ir_id mismatch"}
	}
	if req.Token.CapabilityID != req.ExpectedCapability {
		return &ValidationError{Check: "6c_scope", Reason: "capability_id mismatch"}
	}
	if req.Token.Actor != req.ExpectedActor {
		return &ValidationError{Check: "6c_scope", Reason: "actor mismatch"}
	}

	if req.Token.ArgumentsDigest != req.ExpectedArgsDigest {
		return &ValidationError{Check: "6d_arguments", Reason: "arguments_digest mismatch"}
	}

	if req.Token.Purpose != "" && req.Token.Purpose != req.LiveConsentPurpose {
		return &ValidationError{Check: "6e_purpose", Reason: "purpose revoked or changed since issuance"}
	}

	if req.TaskCancelled {
		return &ValidationError{Check: "6f_task_state", Reason: "owning task is cancelled"}
	}

	return nil
}
