package policy

import (
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"time"

	"friday/policytoken"
)

// Signer holds the Policy Engine's Ed25519 private key. Only the Policy
// Engine process constructs a Signer with a real private key (ADR-021);
// no other module has an import path to this type at all —
// services/capability-bus imports friday/policytoken (verification only),
// never friday/policy-engine/internal/policy (Go's `internal/` rule
// forbids it structurally, in addition to this type simply not being
// exported from anywhere capability-bus can reach). This is the concrete
// mechanism behind "the Capability Bus must never hold the Policy
// Engine's private signing key" and "the Bus cannot mint authorization."
type Signer struct {
	priv ed25519.PrivateKey
}

// NewKeyPair generates a fresh Ed25519 key pair, returning a Signer
// (private, stays in this package) and a policytoken.Verifier (public,
// safe to hand to any component that only needs to verify).
func NewKeyPair() (Signer, policytoken.Verifier, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return Signer{}, policytoken.Verifier{}, fmt.Errorf("generating Ed25519 key pair: %w", err)
	}
	return Signer{priv: priv}, policytoken.NewVerifier(pub), nil
}

// Public returns the Verifier corresponding to this Signer's key.
func (s Signer) Public() policytoken.Verifier {
	return policytoken.NewVerifier(s.priv.Public().(ed25519.PublicKey))
}

const defaultTokenTTL = 15 * time.Second // TBD — benchmark required (ST §S.2.1)

// Issue mints a new, signed policytoken.PolicyToken. Only callable on a
// Signer — this is the type-system enforcement POL-006 exercises.
func (s Signer) Issue(in PolicyInput, now time.Time) (*policytoken.PolicyToken, error) {
	t := policytoken.PolicyToken{
		TokenID:         newTokenID(),
		IRID:            in.IRID,
		CapabilityID:    in.Capability,
		Actor:           in.Actor,
		RiskLevel:       policytoken.RiskLevel(in.Risk),
		Purpose:         in.Purpose,
		ArgumentsDigest: in.ArgumentsDigest,
		IssuedAt:        now,
		ExpiresAt:       now.Add(defaultTokenTTL),
	}
	payload, err := t.SigningPayload()
	if err != nil {
		return nil, fmt.Errorf("marshaling token for signing: %w", err)
	}
	t.Signature = ed25519.Sign(s.priv, payload)
	return &t, nil
}

func newTokenID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Errorf("failed to generate token id: %w", err))
	}
	return fmt.Sprintf("%x", b)
}
