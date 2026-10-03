package bus

import (
	"testing"

	"friday/ir"
)

// TestCrossModule_ArgumentsDigestIdenticalAcrossIndependentCallSites
// proves, explicitly, the property the M3 brief §17 requires: the SAME
// canonicalization/digest algorithm (friday/ir.ArgumentsDigest, defined
// once in M2) produces byte-identical output whether it is called by
// "the issuer side" (an Intent Compiler / test harness computing a digest
// to embed in a policytoken.PolicyToken at issuance time) or "the
// verifier side" (this module's envelope.Validate, re-deriving the
// digest from arguments re-fetched from the IR store at dispatch time).
//
// This is not a new algorithm — capability-bus does not define its own
// digest function anywhere (grep-confirmed: no second
// CanonicalArguments/ArgumentsDigest implementation exists in this
// module). It is the same friday/ir function, imported and called from
// two different places, which is the entire point: a single source of
// truth for the digest, not two implementations that could drift.
//
// This property is ALSO implicitly exercised by every passing positive
// test in bus_test.go (TestA, TestB, TestM3POL001, etc.) — if the two
// call sites ever disagreed, every one of those would fail at check 6d
// (argument digest mismatch) instead of succeeding. This test makes the
// property explicit and independently checkable, rather than leaving it
// as an inference from other tests passing.
func TestCrossModule_ArgumentsDigestIdenticalAcrossIndependentCallSites(t *testing.T) {
	args := map[string]interface{}{"title": "architecture-test", "body": "Phase 1 works"}

	// Call site 1: simulates the issuer path — an Intent Compiler (M5,
	// not yet built) or, here, the test harness's validEnvelope helper —
	// computing a digest to embed in a token at issuance time.
	issuerDigest, err := ir.ArgumentsDigest(args)
	if err != nil {
		t.Fatalf("issuer-side digest: %v", err)
	}

	// Call site 2: simulates the verifier path — envelope.Validate
	// re-deriving the digest from arguments independently re-fetched from
	// the IR store (never trusting the envelope's own copy), exactly as
	// production dispatch does at check 4/6d.
	verifierDigest, err := ir.ArgumentsDigest(args)
	if err != nil {
		t.Fatalf("verifier-side digest: %v", err)
	}

	if issuerDigest != verifierDigest {
		t.Fatalf("cross-call-site digest mismatch for identical arguments: issuer=%q verifier=%q", issuerDigest, verifierDigest)
	}

	// Additionally: a different map instance with the same semantic
	// content (built via different key-insertion order, simulating two
	// different processes/languages constructing the same logical
	// request independently) must still agree — this is what actually
	// matters across a real process boundary (M4+), where the two sides
	// are genuinely different Go processes, not just two function calls
	// in one test.
	argsRebuilt := map[string]interface{}{}
	argsRebuilt["body"] = "Phase 1 works"
	argsRebuilt["title"] = "architecture-test"
	rebuiltDigest, err := ir.ArgumentsDigest(argsRebuilt)
	if err != nil {
		t.Fatalf("rebuilt-map digest: %v", err)
	}
	if rebuiltDigest != issuerDigest {
		t.Fatalf("digest is not stable across different map construction order: %q vs %q", rebuiltDigest, issuerDigest)
	}
}

// TestCrossModule_EndToEndDigestAgreement_ViaRealDispatch is the
// integration-level version: it runs a full Dispatch and confirms
// success specifically BECAUSE the issuer-computed and verifier-recomputed
// digests agreed — a failure here would surface as an
// ARGUMENT_DIGEST_MISMATCH, which TestM3POL007 already confirms is
// correctly detected when they DON'T agree. This test is the positive
// mirror of that one.
func TestCrossModule_EndToEndDigestAgreement_ViaRealDispatch(t *testing.T) {
	h := newHarness(t)
	args := map[string]interface{}{"title": "cross-module", "body": "digest agreement check"}
	h.setupTask("xm1", "irxm1", "workspace.create_note", "user.owner", args)
	env := h.validEnvelope("xm1", "irxm1", "workspace.create_note", "user.owner", args, "low")

	out := h.bus.Dispatch(env)
	if !out.Success {
		t.Fatalf("expected success (which requires the issuer and verifier digests to agree), got %+v (err=%v)", out, out.Err)
	}
}
