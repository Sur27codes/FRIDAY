package ir

// CapabilitySchema is the minimal subset of R.1's full Capability Bus
// contract that stage-4 validation needs. This is NOT the Capability Bus
// itself (that is M3) — it is a read-only reference table the validator
// consults to check IR compatibility. Per PHASE-1-SCOPE-LOCK.md, exactly
// two entries exist. Adding a third is out of scope for M2 (and for
// Phase 1 generally) without a scope-lock amendment.
type CapabilitySchema struct {
	CapabilityID        string
	RequiredArgs        map[string]ArgSpec
	AllowAdditionalArgs bool // false for both Phase-1 capabilities: strict
	// schemas with no unlisted fields, which is
	// what makes IR-016 (path-traversal-style
	// create_note arguments) rejectable at the
	// schema layer rather than relying on the
	// adapter alone (defense in depth — the
	// adapter's own sandboxing, PHASE-1-EXECUTION-SPEC.md
	// §9, remains the primary control; this is
	// a second, independent layer).
	RegisteredRiskLevel  RiskLevel
	RegisteredReversible bool
	RequiredAALMinimum   AAL
	PurposeRequired      bool
	VerificationRequired bool
}

type ArgSpec struct {
	Type      string // "string" — the only type Phase-1's two capabilities need
	MaxLength int
}

// Phase1Registry is the production registry: exactly the two approved
// Phase-1 capabilities (PHASE-1-SCOPE-LOCK.md §3), matching
// PHASE-1-EXECUTION-SPEC.md §9's contracts field-for-field.
func Phase1Registry() map[string]CapabilitySchema {
	return map[string]CapabilitySchema{
		"system.get_status": {
			CapabilityID:         "system.get_status",
			RequiredArgs:         map[string]ArgSpec{}, // no arguments — pure query
			AllowAdditionalArgs:  false,
			RegisteredRiskLevel:  RiskNone,
			RegisteredReversible: true,
			RequiredAALMinimum:   AAL0,
			PurposeRequired:      false,
			VerificationRequired: true, // §387: even a read has a real verification step
		},
		"workspace.create_note": {
			CapabilityID: "workspace.create_note",
			RequiredArgs: map[string]ArgSpec{
				"title": {Type: "string", MaxLength: 200},
				"body":  {Type: "string", MaxLength: 10000},
			},
			AllowAdditionalArgs:  false,
			RegisteredRiskLevel:  RiskLow,
			RegisteredReversible: true,
			RequiredAALMinimum:   AAL1,
			PurposeRequired:      false,
			VerificationRequired: true,
		},
	}
}
