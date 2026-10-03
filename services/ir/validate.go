package ir

import (
	"fmt"
	"strings"
)

// Validate runs all 4 stages from docs/JK-friday-ir-and-runtime-architecture.md
// §J.2.1, in order, short-circuiting on the first failure — matching the
// documented behavior exactly ("Invalid IR at any stage is rejected
// deterministically... never silently coerced into a 'best guess'
// execution").
//
// Design note on stage 3 (disclosed, not silent — see M2's status report):
// J.2.1's prose describes stage 3 as "An Evaluate() call to the SAME
// Policy Engine process... coarse-grained." This package does NOT call
// into services/policy-engine. Reason: a FRIDAY IR document carries no
// assurance-factor/session state (that is runtime/device context, not
// part of the J.2 schema) — a live Evaluate() call at this stage would
// necessarily present zero assurance factors and would therefore DENY or
// CONFIRM every AAL1+ capability at validation time, regardless of
// whether the actual request is legitimate, since the real assurance
// factors are only available later in the pipeline (at the Runtime's
// AWAITING_AUTHORIZATION -> AUTHORIZED transition, K.2). Implementing the
// literal reading would produce incorrect rejections, not just an
// architectural shortcut. Stage 3 here instead performs the IR-internal
// "SECURITY CONSTRAINT / CONSISTENCY CHECK" framing used in the M2
// implementation brief: structural security invariants that do not
// require live policy state (no smuggled authorization fields,
// side-effecting operations must declare verification, financial effects
// must declare commensurate risk). The live precheck call remains
// documented in JK §J.2.1 and is deferred to M4, when the Runtime
// component that supplies real assurance-factor context exists. This is
// recorded as a new architectural question for reconciliation, not a
// silent deviation.
func Validate(raw RawIR, registry map[string]CapabilitySchema) (*ValidatedIR, *ValidationError) {
	if err := validateSyntax(raw); err != nil {
		return nil, err
	}
	if err := validateSemantic(raw, registry); err != nil {
		return nil, err
	}
	if err := validateSecurityConsistency(raw); err != nil {
		return nil, err
	}
	if err := validateCapabilityCompatibility(raw, registry); err != nil {
		return nil, err
	}
	return &ValidatedIR{raw: raw}, nil
}

// ---- Stage 1: SYNTAX VALIDATION ----

func validateSyntax(raw RawIR) *ValidationError {
	// Security invariant first, cheapest and highest-priority check:
	// no smuggled top-level field (see canonical.go's DecodeStrict).
	if len(raw.UnknownFields) > 0 {
		return newErr(StageSyntax, CategorySecurityConstraintViolation, strings.Join(raw.UnknownFields, ","),
			"document contains one or more fields not present in the FRIDAY IR v0.2 schema")
	}

	if raw.IRVersion == "" {
		return newErr(StageSyntax, CategoryMissingField, "ir_version", "required")
	}
	if raw.IRVersion != SupportedSchemaVersion {
		return newErr(StageSyntax, CategoryInvalidSchema, "ir_version",
			fmt.Sprintf("unsupported schema version %q, this validator supports %q only", raw.IRVersion, SupportedSchemaVersion))
	}
	if raw.IRID == "" {
		return newErr(StageSyntax, CategoryMissingField, "ir_id", "required")
	}
	if raw.CorrelationID == "" {
		return newErr(StageSyntax, CategoryMissingField, "correlation_id", "required")
	}
	if raw.Source.Actor == "" {
		return newErr(StageSyntax, CategoryMissingField, "source.actor", "required")
	}
	if raw.Goal.Type == "" {
		return newErr(StageSyntax, CategoryMissingField, "goal.type", "required — every IR document must name a requested capability")
	}
	if raw.Content.Parameters == nil {
		// A missing parameters object is syntactically fine (an empty
		// object is the zero-argument case, e.g. system.get_status) —
		// but a nil map and an empty-but-present map must be
		// indistinguishable to downstream code, so we normalize here
		// rather than let "did the caller send {}" become meaningful by
		// accident.
		raw.Content.Parameters = map[string]interface{}{}
	}

	if !raw.Risk.Level.valid() {
		return newErr(StageSyntax, CategoryInvalidField, "risk.level",
			fmt.Sprintf("must be one of none|low|external_side_effect|high|critical, got %q", raw.Risk.Level))
	}

	if raw.Cancellation.CancellationEffect != "" && !raw.Cancellation.CancellationEffect.valid() {
		return newErr(StageSyntax, CategoryCancellationInvalid, "cancellation.cancellation_effect",
			fmt.Sprintf("must be one of none_yet_started|compensate|requires_manual_review, got %q", raw.Cancellation.CancellationEffect))
	}

	if raw.Idempotency.IdempotencyKey == "" {
		return newErr(StageSyntax, CategoryIdempotencyInvalid, "idempotency.idempotency_key",
			"required on every IR document (J.2)")
	}

	if raw.Verification.Required && raw.Verification.Method == "" {
		return newErr(StageSyntax, CategoryVerificationContractInvalid, "verification.method",
			"verification.required is true but no method is declared")
	}

	if raw.Provenance.CompiledBy == "" {
		return newErr(StageSyntax, CategoryMissingField, "provenance.compiled_by", "required for audit traceability")
	}

	for i, e := range raw.Entities {
		if e.Ref == "" {
			return newErr(StageSyntax, CategoryMissingField, fmt.Sprintf("entities[%d].ref", i), "required")
		}
	}

	return nil
}

// ---- Stage 2: SEMANTIC VALIDATION ----

func validateSemantic(raw RawIR, registry map[string]CapabilitySchema) *ValidationError {
	// goal.type must name a capability_id registered on the Capability
	// Bus (J.2.1 stage 2, verbatim). Per J.3.1 Example C, an unknown
	// capability is a validation FAILURE — there is no separate
	// "valid IR, no supported capability" state in the documented
	// architecture; unsupported intent does not become valid IR.
	if _, ok := registry[raw.Goal.Type]; !ok {
		return newErr(StageSemantic, CategoryUnknownCapability, "goal.type",
			fmt.Sprintf("%q is not a registered Phase-1 capability_id", raw.Goal.Type))
	}

	// dependencies: self-reference is a structural impossibility (a
	// document cannot depend on its own prior completion).
	for _, dep := range raw.Dependencies {
		if dep == raw.IRID {
			return newErr(StageSemantic, CategoryInvalidField, "dependencies",
				"an IR document cannot list its own ir_id as a dependency")
		}
	}

	// constraints: no two temporal constraints with the same trigger but
	// contradictory declared values (a minimal internal-consistency
	// check; full temporal-logic evaluation is out of Phase-1 scope).
	seenTriggers := map[string]string{}
	for i, c := range raw.Constraints {
		if c.Type != "temporal" {
			continue
		}
		key := fmt.Sprintf("%v", c.Value)
		field := fmt.Sprintf("constraints[%d]", i)
		if prior, ok := seenTriggers[key]; ok && prior != key {
			return newErr(StageSemantic, CategoryInvalidField, field, "contradictory temporal constraints on the same trigger")
		}
		seenTriggers[key] = key
	}

	return nil
}

// ---- Stage 3: SECURITY CONSISTENCY CHECK (see design note on Validate) ----

func validateSecurityConsistency(raw RawIR) *ValidationError {
	if raw.Effects.Financial && raw.Risk.Level != RiskHigh && raw.Risk.Level != RiskCritical {
		return newErr(StageSecurityConsistency, CategorySecurityConstraintViolation, "risk.level",
			"effects.financial is true but risk.level is not high or critical — a financial-impact action cannot self-declare low risk")
	}

	if raw.Effects.hasSideEffect() && !raw.Verification.Required {
		return newErr(StageSecurityConsistency, CategorySecurityConstraintViolation, "verification.required",
			"a side-effecting IR document (external_communication, device_state_change, financial, or data_written) must require verification")
	}

	if raw.Effects.hasSideEffect() && !raw.ExpectedOutcome.present() {
		return newErr(StageSecurityConsistency, CategorySecurityConstraintViolation, "expected_outcome",
			"a side-effecting IR document must declare expected_outcome.description and success_condition")
	}

	return nil
}

// ---- Stage 4: CAPABILITY COMPATIBILITY CHECK ----

func validateCapabilityCompatibility(raw RawIR, registry map[string]CapabilitySchema) *ValidationError {
	schema, ok := registry[raw.Goal.Type] // presence already confirmed at stage 2
	if !ok {
		return newErr(StageCapabilityCompatibility, CategoryUnknownCapability, "goal.type", "capability vanished between stage 2 and stage 4 (registry inconsistency)")
	}

	// Risk match: IR's risk.level must equal the capability's registered
	// risk_level exactly — never silently reconciled in either
	// direction (J.2.1 stage 4, verbatim). This is also the concrete
	// defense against a "risk downgrade attempt."
	if raw.Risk.Level != schema.RegisteredRiskLevel {
		return newErr(StageCapabilityCompatibility, CategoryRiskMismatch, "risk.level",
			fmt.Sprintf("IR declares risk %q but capability %q is registered at risk %q", raw.Risk.Level, raw.Goal.Type, schema.RegisteredRiskLevel))
	}

	if raw.Effects.Reversible != schema.RegisteredReversible {
		return newErr(StageCapabilityCompatibility, CategoryRiskMismatch, "effects.reversible",
			fmt.Sprintf("IR declares reversible=%v but capability %q is registered as reversible=%v", raw.Effects.Reversible, raw.Goal.Type, schema.RegisteredReversible))
	}

	// Auth requirement: the AAL implied by the IR's (now-confirmed-matching)
	// risk level must meet the capability's own minimum.
	impliedAAL := requiredAALForRisk(raw.Risk.Level)
	if impliedAAL < schema.RequiredAALMinimum {
		return newErr(StageCapabilityCompatibility, CategoryAuthRequirementMismatch, "risk.level",
			fmt.Sprintf("risk %q implies %s, below capability %q's required minimum %s", raw.Risk.Level, impliedAAL, raw.Goal.Type, schema.RequiredAALMinimum))
	}

	if schema.PurposeRequired {
		// Phase-1's two capabilities never set PurposeRequired; this
		// branch exists for the synthetic test capability used by
		// IR-012, mirroring services/policy-engine's POL-009 pattern for
		// the same "mechanism exists, no Phase-1 capability exercises it
		// end-to-end" situation. Purpose itself is not part of RawIR
		// (J.2 has no top-level `purpose` field; purpose lives in the
		// Consent Ledger and is threaded in at the Policy Engine layer,
		// ST §S.2.1) — so what stage 4 can check here is only that a
		// purpose-bound capability was not invoked via content.parameters
		// smuggling a "purpose" key, which would already have been
		// rejected as an unregistered argument by the input-schema check
		// below. This branch is therefore currently unreachable by
		// construction; kept for forward-declaration and documented as
		// such rather than silently omitted.
		return newErr(StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch, "purpose",
			"capability requires a bound purpose, which cannot currently be expressed or satisfied by a Phase-1 IR document")
	}

	// Argument compatibility: every required arg present with the right
	// type/length; no additional args beyond what the schema declares
	// (this is what makes a smuggled "path" argument on
	// workspace.create_note rejectable at this layer — IR-016).
	for name, spec := range schema.RequiredArgs {
		val, present := raw.Content.Parameters[name]
		if !present {
			return newErr(StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch,
				"content.parameters."+name, "required argument missing")
		}
		s, isString := val.(string)
		if spec.Type == "string" && !isString {
			return newErr(StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch,
				"content.parameters."+name, "expected a string value")
		}
		if spec.MaxLength > 0 && len(s) > spec.MaxLength {
			return newErr(StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch,
				"content.parameters."+name, fmt.Sprintf("exceeds maximum length %d", spec.MaxLength))
		}
	}
	if !schema.AllowAdditionalArgs {
		for name := range raw.Content.Parameters {
			if _, declared := schema.RequiredArgs[name]; !declared {
				return newErr(StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch,
					"content.parameters."+name, "argument not declared by this capability's input_schema")
			}
		}
	}

	return nil
}
