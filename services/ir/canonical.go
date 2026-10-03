package ir

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
)

// CanonicalArguments produces a deterministic byte representation of an
// argument map, suitable as input to a digest that downstream components
// (the M4 Capability Bus, ST §S.2.1's arguments_digest check) can
// independently recompute and expect to match. Determinism requirement
// (item 9): identical semantic arguments always produce identical bytes,
// regardless of map iteration/construction order; different arguments
// always produce different bytes (no accidental collision from ambiguous
// serialization).
//
// Go's encoding/json already sorts map[string]interface{} keys
// alphabetically when marshaling, but that behavior is relied upon
// implicitly by default in most Go code — this function makes the
// ordering explicit and tested (IR-019/IR-020) rather than depending on
// an implementation detail of the standard library that a future
// refactor could silently disturb.
func CanonicalArguments(args map[string]interface{}) ([]byte, error) {
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		kb, err := json.Marshal(k)
		if err != nil {
			return nil, fmt.Errorf("canonicalizing key %q: %w", k, err)
		}
		buf.Write(kb)
		buf.WriteByte(':')
		vb, err := json.Marshal(args[k])
		if err != nil {
			return nil, fmt.Errorf("canonicalizing value for key %q: %w", k, err)
		}
		buf.Write(vb)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// ArgumentsDigest returns the hex-encoded SHA-256 digest of the canonical
// argument bytes. This is the exact format services/policy-engine's
// PolicyInput.ArgumentsDigest and PolicyToken.ArgumentsDigest expect as a
// plain string (see ST §S.2.1) — both sides of the M1/M2 boundary must
// agree on this format for the M4 Capability Bus's check 6d to ever
// succeed on a legitimate request, which is why it is documented here
// explicitly rather than left as an implicit convention.
func ArgumentsDigest(args map[string]interface{}) (string, error) {
	canon, err := CanonicalArguments(args)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canon)
	return hex.EncodeToString(sum[:]), nil
}

// knownTopLevelKeys is the exhaustive set of JSON keys RawIR's schema
// defines. Used by DecodeStrict to detect and reject any extra top-level
// key — the concrete mechanism behind the "IR cannot embed a forged
// authorization token and become executable" security invariant (D-srs.md
// §8 of the M2 brief): there is no field named "policy_token",
// "authorization", "decision", or similar anywhere in J.2's schema, so any
// document containing one is rejected before any other stage runs, not
// merely ignored.
var knownTopLevelKeys = map[string]bool{
	"ir_version": true, "ir_id": true, "correlation_id": true, "causation_id": true,
	"created_at": true, "source": true, "goal": true, "entities": true,
	"recipient": true, "content": true, "constraints": true, "effects": true,
	"risk": true, "expected_outcome": true, "cancellation": true,
	"idempotency": true, "dependencies": true, "verification": true,
	"knowledge_state": true, "provenance": true,
}

// DecodeStrict parses raw JSON bytes into a RawIR, additionally recording
// any top-level key not present in J.2's documented schema. It does not
// itself reject anything — rejection is stage 1's job (validate.go) — it
// only makes the "extra key" fact observable to stage 1, since Go's
// standard json.Unmarshal silently ignores unknown fields by default,
// which would otherwise let a smuggled field pass through unnoticed.
func DecodeStrict(data []byte) (RawIR, error) {
	var raw RawIR
	if err := json.Unmarshal(data, &raw); err != nil {
		return RawIR{}, err
	}

	var generic map[string]json.RawMessage
	if err := json.Unmarshal(data, &generic); err != nil {
		return RawIR{}, err
	}
	for k := range generic {
		if !knownTopLevelKeys[k] {
			raw.UnknownFields = append(raw.UnknownFields, k)
		}
	}
	sort.Strings(raw.UnknownFields) // deterministic order for stable error messages/tests

	return raw, nil
}
