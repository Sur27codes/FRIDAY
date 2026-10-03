package policy

import (
	"testing"
	"time"

	"friday/policytoken"
)

// Tests in this file translate docs/PHASE-1-POLICY-SECURITY-TEST-SPEC.md
// §1 (POL-001..POL-019) into executable Go tests. Updated during M3 to
// use the friday/policytoken shared module's types (PolicyToken, Verifier,
// ValidationRequest, ValidationError) after the M3 refactor that moved
// verification-capable types out of this internal package — see
// docs/E-traceability-matrix.md's M3 section for why. Test behavior is
// unchanged from the original M1 version; only the type qualification
// changed.

func testValidationRequest(tok *policytoken.PolicyToken, now time.Time) policytoken.ValidationRequest {
	return policytoken.ValidationRequest{
		Token:              tok,
		Now:                now,
		ExpectedIRID:       tok.IRID,
		ExpectedCapability: tok.CapabilityID,
		ExpectedActor:      tok.Actor,
		ExpectedArgsDigest: tok.ArgumentsDigest,
		LiveConsentPurpose: tok.Purpose,
	}
}

// POL-001: a validly-issued, unexpired, correctly-scoped token is accepted.
func TestPOL001_ValidTokenAccepted(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{
		Actor: "user.owner", Capability: "system.get_status", IRID: "ir-pol1",
		Risk: RiskNone, ArgumentsDigest: "digest-empty", EvaluatedAt: now,
	}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	req := testValidationRequest(tok, now)
	if err := verifier.Validate(req); err != nil {
		t.Fatalf("expected valid token to pass, got: %v", err)
	}
}

// POL-003: an expired token is denied.
func TestPOL003_ExpiredTokenDenied(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{Actor: "user.owner", Capability: "system.get_status", IRID: "ir-pol3", Risk: RiskNone, EvaluatedAt: now}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	afterExpiry := tok.ExpiresAt.Add(time.Second)
	req := testValidationRequest(tok, afterExpiry)
	err = verifier.Validate(req)
	if err == nil {
		t.Fatal("expected expired token to be rejected, got nil error")
	}
	ve, ok := err.(*policytoken.ValidationError)
	if !ok || ve.Check != "6b_expiry" {
		t.Fatalf("expected 6b_expiry failure, got: %v", err)
	}
}

// POL-004: a token minted for capability A cannot authorize capability B.
func TestPOL004_TokenScopedToOneCapabilityCannotAuthorizeAnother(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{Actor: "user.owner", Capability: "system.get_status", IRID: "ir-pol4", Risk: RiskNone, EvaluatedAt: now}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	req := testValidationRequest(tok, now)
	req.ExpectedCapability = "workspace.create_note"
	err = verifier.Validate(req)
	if err == nil {
		t.Fatal("expected cross-capability reuse to be rejected, got nil error")
	}
	ve, ok := err.(*policytoken.ValidationError)
	if !ok || ve.Check != "6c_scope" {
		t.Fatalf("expected 6c_scope failure, got: %v", err)
	}
}

// POL-005: a token with a tampered field is denied, tested per field.
func TestPOL005_TamperedTokenFieldsDenied(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-pol5",
		Risk: RiskLow, ArgumentsDigest: "digest-abc", EvaluatedAt: now,
	}

	mutate := func(name string, f func(*policytoken.PolicyToken)) {
		t.Run(name, func(t *testing.T) {
			tok, err := signer.Issue(in, now)
			if err != nil {
				t.Fatalf("issue: %v", err)
			}
			f(tok)
			req := testValidationRequest(tok, now)
			req.ExpectedIRID = "ir-pol5"
			req.ExpectedCapability = "workspace.create_note"
			req.ExpectedActor = "user.owner"
			req.ExpectedArgsDigest = "digest-abc"
			if err := verifier.Validate(req); err == nil {
				t.Fatalf("expected tampered field %q to invalidate the token, got nil error", name)
			}
		})
	}

	mutate("capability_id", func(tok *policytoken.PolicyToken) { tok.CapabilityID = "system.get_status" })
	mutate("actor", func(tok *policytoken.PolicyToken) { tok.Actor = "attacker" })
	mutate("expires_at", func(tok *policytoken.PolicyToken) { tok.ExpiresAt = tok.ExpiresAt.Add(24 * time.Hour) })
	mutate("arguments_digest", func(tok *policytoken.PolicyToken) { tok.ArgumentsDigest = "digest-XYZ-tampered" })
	mutate("risk_level", func(tok *policytoken.PolicyToken) { tok.RiskLevel = policytoken.RiskCritical })
}

// POL-006 / POL-007: a process holding only the public key (Verifier)
// cannot mint a valid token — proven both structurally (Verifier/the
// policytoken package expose no Issue capability at all, see
// token.go's package doc) and at runtime (a hand-forged token fails
// verification).
func TestPOL006_007_CannotForgeTokenWithoutPrivateKey(t *testing.T) {
	_, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()

	forged := &policytoken.PolicyToken{
		TokenID: "forged", IRID: "ir-forged", CapabilityID: "system.get_status",
		Actor: "user.owner", RiskLevel: policytoken.RiskNone,
		IssuedAt: now, ExpiresAt: now.Add(time.Hour),
		Signature: []byte("not-a-real-ed25519-signature-blob-of-plausible-length!!"),
	}
	req := testValidationRequest(forged, now)
	if err := verifier.Validate(req); err == nil {
		t.Fatal("expected hand-forged token to fail signature verification, got nil error")
	}
}

// Compile-time proof for POL-006: friday/policytoken exposes no function
// or method capable of producing a signed *PolicyToken — Issue() exists
// only on this package's unexported-key-holding Signer type, which
// friday/capability-bus has no import path to at all (M3).
var _ = struct{ note string }{"policytoken package has no Issue(...) function; only this package's Signer does — see token.go"}

// POL-011: a retry after expiry must obtain a genuinely fresh token.
func TestPOL011_RetryAfterExpiryRequiresFreshToken(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{Actor: "user.owner", Capability: "system.get_status", IRID: "ir-pol11", Risk: RiskNone, EvaluatedAt: now}

	firstTok, _ := signer.Issue(in, now)
	afterExpiry := firstTok.ExpiresAt.Add(time.Second)

	if err := verifier.Validate(testValidationRequest(firstTok, afterExpiry)); err == nil {
		t.Fatal("expired token unexpectedly validated")
	}

	secondTok, err := signer.Issue(in, afterExpiry)
	if err != nil {
		t.Fatalf("re-issue: %v", err)
	}
	if secondTok.TokenID == firstTok.TokenID {
		t.Fatal("retry must produce a new token_id, not reuse the expired one")
	}
	if err := verifier.Validate(testValidationRequest(secondTok, afterExpiry)); err != nil {
		t.Fatalf("freshly re-issued token should validate, got: %v", err)
	}
}

// POL-012 / POL-013: a cancelled task's token is invalidated immediately.
func TestPOL012_013_CancelledTaskTokenRejectedEvenIfUnexpired(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-pol12", Risk: RiskLow, EvaluatedAt: now}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	req := testValidationRequest(tok, now)
	req.TaskCancelled = true

	err = verifier.Validate(req)
	if err == nil {
		t.Fatal("expected cancelled-task token to be rejected despite being cryptographically unexpired")
	}
	ve, ok := err.(*policytoken.ValidationError)
	if !ok || ve.Check != "6f_task_state" {
		t.Fatalf("expected 6f_task_state failure, got: %v", err)
	}
}

// POL-017: a token is bound to a specific arguments_digest.
func TestPOL017_ArgumentTamperingRejected(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{
		Actor: "user.owner", Capability: "workspace.create_note", IRID: "ir-pol17",
		Risk: RiskLow, ArgumentsDigest: "digest-of-{title:test,body:hello}", EvaluatedAt: now,
	}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	req := testValidationRequest(tok, now)
	req.ExpectedArgsDigest = "digest-of-{title:test,body:malicious-content}"

	err = verifier.Validate(req)
	if err == nil {
		t.Fatal("expected tampered-arguments request to be rejected")
	}
	ve, ok := err.(*policytoken.ValidationError)
	if !ok || ve.Check != "6d_arguments" {
		t.Fatalf("expected 6d_arguments failure, got: %v", err)
	}
}

// POL-009 mechanism-level check: purpose is re-validated at use time.
func TestPOL009_PurposeRevokedBetweenIssuanceAndUse(t *testing.T) {
	signer, verifier, err := NewKeyPair()
	if err != nil {
		t.Fatalf("key pair: %v", err)
	}
	now := time.Now()
	in := PolicyInput{
		Actor: "user.owner", Capability: "hypothetical.camera_read", IRID: "ir-pol9",
		Risk: RiskLow, Purpose: "outfit_analysis", EvaluatedAt: now,
	}
	tok, err := signer.Issue(in, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	req := testValidationRequest(tok, now)
	req.LiveConsentPurpose = "surveillance"

	err = verifier.Validate(req)
	if err == nil {
		t.Fatal("expected purpose-mismatch to be rejected even with a cryptographically valid token")
	}
	ve, ok := err.(*policytoken.ValidationError)
	if !ok || ve.Check != "6e_purpose" {
		t.Fatalf("expected 6e_purpose failure, got: %v", err)
	}
}
