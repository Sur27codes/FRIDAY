// Package registry is the Capability Bus's fixed, compile-time capability
// table. Per PHASE-1-SCOPE-LOCK.md §3 and the M3 brief §4: exactly two
// entries, no dynamic registration from runtime/untrusted input, no
// plugin loading. Adding a third capability requires a code change and a
// scope-lock amendment, not a runtime API call — there is deliberately no
// Register(contract) function exposed for external callers to invoke.
package registry

import (
	"time"

	"friday/capability-bus/internal/contract"
)

// Registry is an immutable, closed set of capabilities. Its zero value is
// not useful; construct with Phase1().
type Registry struct {
	entries map[string]contract.Contract
}

// Get returns the contract for a capability_id, or false if it is not one
// of the registered Phase-1 capabilities. There is no fallback, no
// wildcard, and no partial match — an unknown ID fails deterministically.
func (r Registry) Get(capabilityID string) (contract.Contract, bool) {
	c, ok := r.entries[capabilityID]
	return c, ok
}

// Phase1 returns the fixed, exactly-two-entry registry approved by
// PHASE-1-SCOPE-LOCK.md §3, matching PHASE-1-EXECUTION-SPEC.md §9's
// contracts field-for-field.
func Phase1() Registry {
	return Registry{entries: map[string]contract.Contract{
		"system.get_status": {
			CapabilityID:        "system.get_status",
			Version:             "1.0.0",
			Description:         "Return the current Self Model snapshot: capability availability, resource state, autonomy configuration.",
			InputSchema:         map[string]contract.ArgSchema{}, // no arguments
			AllowAdditionalArgs: false,
			RequiredPermission:  "none beyond AAL0 — risk:none read of the system's own operational state",
			RequiredPurpose:     "",
			MinimumAAL:          contract.AAL0,
			RiskLevel:           contract.RiskNone,
			Reversible:          true,
			DataRead:            []string{"self_model"},
			DataWritten:         nil,
			Timeout:             2 * time.Second, // provisional — TBD, benchmark required
			RetrySemantics:      contract.Idempotent,
			VerificationMethod:  "schema_conformance_against_live_self_model",
			DataClassification:  "INTERNAL",
		},
		"workspace.create_note": {
			CapabilityID: "workspace.create_note",
			Version:      "1.0.0",
			Description:  "Create a small text note in a sandboxed, dedicated FRIDAY workspace directory (not arbitrary filesystem access).",
			InputSchema: map[string]contract.ArgSchema{
				"title": {Type: "string", MaxLength: 200, Required: true},
				"body":  {Type: "string", MaxLength: 10000, Required: true},
			},
			AllowAdditionalArgs: false,
			RequiredPermission:  "AAL1 — trusted-device-session sufficient; low-risk local action",
			RequiredPurpose:     "",
			MinimumAAL:          contract.AAL1,
			RiskLevel:           contract.RiskLow,
			Reversible:          true,
			DataRead:            nil,
			DataWritten:         []string{"workspace_notes"},
			Timeout:             5 * time.Second, // provisional — TBD, benchmark required
			RetrySemantics:      contract.ConditionallyIdempotent,
			VerificationMethod:  "post_write_existence_and_content_check",
			DataClassification:  "PERSONAL",
		},
	}}
}
