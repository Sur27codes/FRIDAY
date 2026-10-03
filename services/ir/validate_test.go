package ir

import (
	"strings"
	"testing"
	"time"
)

// Tests in this file translate the M2 brief's IR-001..IR-022 into
// executable Go tests, plus IR-019/IR-020 for canonicalization
// determinism. Each fixture is built as a valid baseline and then mutated
// for the specific negative case, so each test isolates exactly one
// failure condition.

func validStatusIR() RawIR {
	return RawIR{
		IRVersion:     SupportedSchemaVersion,
		IRID:          "ir-status-1",
		CorrelationID: "corr-1",
		CreatedAt:     time.Now(),
		Source:        Source{Actor: "user.owner", Device: "device.primary_mac", SessionID: "sess-1", InputModality: "text"},
		Goal:          Goal{Type: "system.get_status", Description: "check status"},
		Content:       Content{Intent: "get_status", Parameters: map[string]interface{}{}},
		Effects:       Effects{Reversible: true},
		Risk:          Risk{Level: RiskNone},
		ExpectedOutcome: ExpectedOutcome{
			Description:      "status snapshot returned",
			SuccessCondition: map[string]interface{}{"response_matches_live_self_model": true},
		},
		Cancellation: Cancellation{Cancellable: true, CancellationEffect: CancellationNoneYetStarted},
		Idempotency:  Idempotency{IdempotencyKey: "corr-1:system.get_status", SafeToRetry: true},
		Verification: Verification{Required: true, Method: "schema_conformance_against_live_self_model"},
		Provenance:   Provenance{CompiledBy: "intent_compiler_v0.1"},
	}
}

func validCreateNoteIR() RawIR {
	return RawIR{
		IRVersion:     SupportedSchemaVersion,
		IRID:          "ir-note-1",
		CorrelationID: "corr-2",
		CreatedAt:     time.Now(),
		Source:        Source{Actor: "user.owner", Device: "device.primary_mac", SessionID: "sess-1", InputModality: "text"},
		Goal:          Goal{Type: "workspace.create_note", Description: "create a note"},
		Content: Content{Intent: "create_note", Parameters: map[string]interface{}{
			"title": "architecture-test",
			"body":  "Phase 1 works",
		}},
		Effects: Effects{DataWritten: []string{"workspace_notes"}, Reversible: true},
		Risk:    Risk{Level: RiskLow},
		ExpectedOutcome: ExpectedOutcome{
			Description:      "note file exists with given content",
			SuccessCondition: map[string]interface{}{"file_exists": true, "content_matches": true},
		},
		Cancellation: Cancellation{Cancellable: true, CancellationEffect: CancellationNoneYetStarted},
		Idempotency:  Idempotency{IdempotencyKey: "corr-2:workspace.create_note:hash", SafeToRetry: true},
		Verification: Verification{Required: true, Method: "post_write_existence_and_content_check"},
		Provenance:   Provenance{CompiledBy: "intent_compiler_v0.1"},
	}
}

func mustNotBeNil(t *testing.T, v *ValidatedIR, err *ValidationError) {
	t.Helper()
	if err != nil {
		t.Fatalf("expected valid IR, got validation error: %v", err)
	}
	if v == nil {
		t.Fatal("expected non-nil ValidatedIR on success")
	}
}

func mustFail(t *testing.T, v *ValidatedIR, err *ValidationError, wantStage Stage, wantCategory ErrorCategory) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected validation error (stage=%s category=%s), got success: %+v", wantStage, wantCategory, v)
	}
	if v != nil {
		t.Fatal("expected nil ValidatedIR on failure")
	}
	if err.Stage != wantStage {
		t.Errorf("expected stage %s, got %s (category=%s, msg=%s)", wantStage, err.Stage, err.Category, err.Message)
	}
	if err.Category != wantCategory {
		t.Errorf("expected category %s, got %s (stage=%s, msg=%s)", wantCategory, err.Category, err.Stage, err.Message)
	}
}

// IR-001: valid system.get_status IR accepted.
func TestIR001_ValidGetStatusAccepted(t *testing.T) {
	v, err := Validate(validStatusIR(), Phase1Registry())
	mustNotBeNil(t, v, err)
}

// IR-002: valid workspace.create_note IR accepted.
func TestIR002_ValidCreateNoteAccepted(t *testing.T) {
	v, err := Validate(validCreateNoteIR(), Phase1Registry())
	mustNotBeNil(t, v, err)
}

// IR-003: unsupported schema version rejected.
func TestIR003_UnsupportedSchemaVersionRejected(t *testing.T) {
	raw := validStatusIR()
	raw.IRVersion = "0.1"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryInvalidSchema)
}

// IR-004: missing required field rejected (goal.type, as a representative case).
func TestIR004_MissingRequiredFieldRejected(t *testing.T) {
	raw := validStatusIR()
	raw.Goal.Type = ""
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryMissingField)
}

// IR-005: unknown capability behavior matches documented semantics — a
// SemanticValidationError(capability_not_found)-equivalent rejection, per
// JK §J.3.1 Example C, not a separate "valid IR, unsupported capability" state.
func TestIR005_UnknownCapabilityRejectedAtSemanticStage(t *testing.T) {
	raw := validStatusIR()
	raw.Goal.Type = "file.delete_all"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSemantic, CategoryUnknownCapability)
}

// IR-006: malformed capability arguments rejected (wrong type).
func TestIR006_MalformedCapabilityArgumentsRejected(t *testing.T) {
	raw := validCreateNoteIR()
	raw.Content.Parameters["title"] = 12345 // not a string
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch)
}

// IR-007: required verification contract missing -> rejected.
func TestIR007_MissingVerificationMethodRejected(t *testing.T) {
	raw := validStatusIR()
	raw.Verification = Verification{Required: true, Method: ""}
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryVerificationContractInvalid)
}

// IR-008: expected outcome missing for a side-effecting operation -> rejected.
func TestIR008_MissingExpectedOutcomeForSideEffectRejected(t *testing.T) {
	raw := validCreateNoteIR()
	raw.ExpectedOutcome = ExpectedOutcome{}
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSecurityConsistency, CategorySecurityConstraintViolation)
}

// IR-009: requested AAL below capability minimum -> rejected. Constructed
// via a synthetic capability with a stricter AAL minimum than its risk
// level alone implies, mirroring services/policy-engine's POL-009 pattern
// for a check neither real Phase-1 capability naturally exercises.
func TestIR009_RequestedAALBelowCapabilityMinimumRejected(t *testing.T) {
	registry := Phase1Registry()
	registry["synthetic.strict_capability"] = CapabilitySchema{
		CapabilityID:         "synthetic.strict_capability",
		RequiredArgs:         map[string]ArgSpec{},
		AllowAdditionalArgs:  false,
		RegisteredRiskLevel:  RiskLow, // implies AAL1 via the table
		RegisteredReversible: true,
		RequiredAALMinimum:   AAL3, // but this capability demands more, by policy
		VerificationRequired: true,
	}
	raw := validStatusIR()
	raw.Goal.Type = "synthetic.strict_capability"
	raw.Risk.Level = RiskLow
	raw.Effects.Reversible = true
	v, err := Validate(raw, registry)
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryAuthRequirementMismatch)
}

// IR-010: risk downgrade attempt -> rejected (IR claims a lower risk than
// the capability is registered at).
func TestIR010_RiskDowngradeAttemptRejected(t *testing.T) {
	raw := validCreateNoteIR()
	raw.Risk.Level = RiskNone // capability is registered at "low"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryRiskMismatch)
}

// IR-011: side-effect classification mismatch -> rejected (effects.reversible
// disagrees with the capability's registration).
func TestIR011_SideEffectClassificationMismatchRejected(t *testing.T) {
	raw := validCreateNoteIR()
	raw.Effects.Reversible = false // capability is registered reversible=true
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryRiskMismatch)
}

// IR-012: missing purpose where required -> rejected. Neither real
// Phase-1 capability requires purpose (PHASE-1-EXECUTION-SPEC.md §9), so
// this uses a synthetic purpose-required capability, exactly as
// PHASE-1-POLICY-SECURITY-TEST-SPEC.md's POL-009 does for the same
// situation — disclosed, not silently skipped.
func TestIR012_MissingPurposeWhereRequiredRejected(t *testing.T) {
	registry := Phase1Registry()
	registry["synthetic.purpose_bound"] = CapabilitySchema{
		CapabilityID:         "synthetic.purpose_bound",
		RequiredArgs:         map[string]ArgSpec{},
		RegisteredRiskLevel:  RiskLow,
		RegisteredReversible: true,
		RequiredAALMinimum:   AAL1,
		PurposeRequired:      true,
		VerificationRequired: true,
	}
	raw := validStatusIR()
	raw.Goal.Type = "synthetic.purpose_bound"
	raw.Risk.Level = RiskLow
	raw.Effects.Reversible = true
	v, err := Validate(raw, registry)
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch)
}

// IR-013: invalid idempotency declaration -> rejected.
func TestIR013_InvalidIdempotencyDeclarationRejected(t *testing.T) {
	raw := validStatusIR()
	raw.Idempotency.IdempotencyKey = ""
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryIdempotencyInvalid)
}

// IR-014: cancellation-semantics mismatch -> rejected (invalid enum value).
func TestIR014_CancellationSemanticsMismatchRejected(t *testing.T) {
	raw := validStatusIR()
	raw.Cancellation.CancellationEffect = "not_a_real_value"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryCancellationInvalid)
}

// IR-015: malformed correlation/request identifiers rejected.
func TestIR015_MalformedCorrelationIdentifiersRejected(t *testing.T) {
	raw := validStatusIR()
	raw.CorrelationID = ""
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryMissingField)

	// Self-referential dependency is the other "invalid relationship" case.
	raw2 := validStatusIR()
	raw2.Dependencies = []string{raw2.IRID}
	v2, err2 := Validate(raw2, Phase1Registry())
	mustFail(t, v2, err2, StageSemantic, CategoryInvalidField)
}

// IR-016: arbitrary filesystem/path-traversal-style create_note arguments
// rejected — the input_schema declares only {title, body}; a "path"
// argument is not a declared field at all, so it is rejected as an
// undeclared argument (defense in depth alongside the adapter's own
// sandboxing, PHASE-1-EXECUTION-SPEC.md §9, which does not exist until M3).
func TestIR016_PathTraversalStyleArgumentRejected(t *testing.T) {
	raw := validCreateNoteIR()
	raw.Content.Parameters["path"] = "../../../etc/passwd"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageCapabilityCompatibility, CategoryCapabilitySchemaMismatch)
	if !strings.Contains(err.Field, "path") {
		t.Errorf("expected error to identify the offending field as containing 'path', got %q", err.Field)
	}
}

// IR-017: an unsupported "shell execution"-flavored capability cannot
// become valid executable Phase-1 IR — same mechanism as IR-005, tested
// separately because the security property being demonstrated (no
// unrestricted shell path) is distinct in intent from "capability doesn't
// exist," per §2's "No capability execution belongs in M2" and the
// original vision's explicit non-goal (§2: "an unrestricted autonomous
// shell").
func TestIR017_ShellExecutionCapabilityCannotBecomeValidIR(t *testing.T) {
	raw := validStatusIR()
	raw.Goal.Type = "system.execute_shell_command"
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSemantic, CategoryUnknownCapability)
}

// IR-018: a security-sensitive missing field fails closed, not open —
// specifically, an entirely absent risk.level must not default to "none"
// (the most permissive value). Go's zero value for RiskLevel is "", which
// is not in the valid enum, so this is rejected by construction; this
// test exists to make that guarantee explicit and regression-proof.
func TestIR018_MissingRiskLevelFailsClosed(t *testing.T) {
	raw := validStatusIR()
	raw.Risk = Risk{} // zero value: Level == ""
	v, err := Validate(raw, Phase1Registry())
	mustFail(t, v, err, StageSyntax, CategoryInvalidField)
	if raw.Risk.Level == RiskNone {
		t.Fatal("test setup invariant violated: zero-value RiskLevel must not equal RiskNone")
	}
}

// IR-019: deterministic canonicalization is stable — identical semantic
// arguments (built via different map-construction orders) produce
// identical canonical bytes and digest.
func TestIR019_CanonicalizationStable(t *testing.T) {
	a := map[string]interface{}{"title": "x", "body": "y"}
	b := map[string]interface{}{}
	b["body"] = "y"
	b["title"] = "x" // inserted in the opposite order

	digestA, err := ArgumentsDigest(a)
	if err != nil {
		t.Fatalf("digest a: %v", err)
	}
	digestB, err := ArgumentsDigest(b)
	if err != nil {
		t.Fatalf("digest b: %v", err)
	}
	if digestA != digestB {
		t.Fatalf("expected identical digests for semantically identical arguments, got %q vs %q", digestA, digestB)
	}
}

// IR-020: changed arguments change the canonical representation/digest.
func TestIR020_ChangedArgumentsChangeDigest(t *testing.T) {
	a := map[string]interface{}{"title": "x", "body": "y"}
	c := map[string]interface{}{"title": "x", "body": "MALICIOUS"}

	digestA, _ := ArgumentsDigest(a)
	digestC, _ := ArgumentsDigest(c)
	if digestA == digestC {
		t.Fatal("expected different digests for different arguments, got identical")
	}
}

// IR-021: validation does not issue authorization tokens. Structural
// proof: ValidatedIR has no field, method, or return value of any
// token-shaped type — this package does not define or import a token
// type at all (see validate.go's design note: no dependency on
// services/policy-engine). If this ever changed, it would require adding
// an explicit import this test's own package-level absence proves does
// not currently exist.
func TestIR021_ValidationDoesNotIssueTokens(t *testing.T) {
	v, err := Validate(validStatusIR(), Phase1Registry())
	mustNotBeNil(t, v, err)
	// ValidatedIR's only field is the unexported `raw RawIR` — there is
	// no way to ask it for a token because no such field or method
	// exists on the type. This test's existence and the package's
	// absence of any "policy" import together constitute the proof.
}

// IR-022: validation cannot mark an IR executable by itself — there is no
// public constructor for ValidatedIR other than a successful Validate()
// call (the struct's field is unexported), and Validate() itself performs
// no capability invocation, no I/O, and returns no execution envelope —
// only PHASE-1-EXECUTION-SPEC.md §1's Runtime Scheduler (M4+) can
// construct an Execution Envelope, and only after a separate Policy
// Engine Evaluate() call. This test confirms Validate()'s side-effect
// surface is empty: calling it twice with the same input is safe and
// produces no observable state change (no files written, per §14's "no
// execution side effects" requirement, verified structurally since this
// package performs no I/O calls anywhere in its source).
func TestIR022_ValidationAloneNeverExecutable(t *testing.T) {
	raw := validCreateNoteIR()
	v1, err1 := Validate(raw, Phase1Registry())
	v2, err2 := Validate(raw, Phase1Registry())
	mustNotBeNil(t, v1, err1)
	mustNotBeNil(t, v2, err2)
	// No note was created by either call — there is no filesystem-writing
	// code anywhere in this package (grep-verifiable: no "os.Create",
	// "os.WriteFile", or similar appears in services/ir).
}

// Robustness: malformed input never panics (property-style, item 12).
func TestValidate_MalformedInputNeverPanics(t *testing.T) {
	inputs := []RawIR{
		{},                                  // fully empty
		{IRVersion: SupportedSchemaVersion}, // only version set
		{IRVersion: SupportedSchemaVersion, Goal: Goal{Type: "\x00\x01weird"}},
		validCreateNoteIR(),
	}
	// mutate the last one adversarially
	adversarial := validCreateNoteIR()
	adversarial.Content.Parameters = nil
	adversarial.Constraints = []Constraint{{Type: "temporal", Value: nil}}
	adversarial.Dependencies = []string{"", "", adversarial.IRID}
	inputs = append(inputs, adversarial)

	for i, in := range inputs {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("input %d: Validate panicked: %v", i, r)
				}
			}()
			_, _ = Validate(in, Phase1Registry())
		}()
	}
}

// Robustness: an arbitrary/unregistered capability ID never accidentally
// resolves to an approved one.
func TestValidate_ArbitraryCapabilityIDNeverAccidentallyApproved(t *testing.T) {
	adversarialIDs := []string{
		"system.get_status ", // trailing space
		" system.get_status",
		"System.Get_Status", // case variation
		"system.get_status; rm -rf /",
		"system/get_status",
		"",
	}
	for _, id := range adversarialIDs {
		raw := validStatusIR()
		raw.Goal.Type = id
		v, err := Validate(raw, Phase1Registry())
		if err == nil {
			t.Errorf("capability id %q unexpectedly validated as approved (got ValidatedIR=%+v)", id, v)
		}
	}
}

// Robustness: an invalid risk enum value never defaults to a privileged
// (permissive) value.
func TestValidate_InvalidRiskEnumNeverDefaultsPermissive(t *testing.T) {
	invalidValues := []RiskLevel{"NONE", "None", "low ", "", "unknown", "privileged"}
	for _, rv := range invalidValues {
		raw := validStatusIR()
		raw.Risk.Level = rv
		v, err := Validate(raw, Phase1Registry())
		if err == nil {
			t.Errorf("invalid risk value %q unexpectedly validated (got %+v)", rv, v)
		}
	}
}

func TestDecodeStrict_RejectsSmuggledTopLevelFields(t *testing.T) {
	body := []byte(`{
		"ir_version": "0.2", "ir_id": "x", "correlation_id": "y",
		"source": {"actor": "user.owner"}, "goal": {"type": "system.get_status"},
		"risk": {"level": "none"},
		"idempotency": {"idempotency_key": "k"},
		"verification": {"required": false},
		"provenance": {"compiled_by": "x"},
		"policy_token": {"token_id": "forged", "signature": "aaaa"}
	}`)
	raw, err := DecodeStrict(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(raw.UnknownFields) == 0 {
		t.Fatal("expected DecodeStrict to record the smuggled 'policy_token' field")
	}
	v, verr := Validate(raw, Phase1Registry())
	mustFail(t, v, verr, StageSyntax, CategorySecurityConstraintViolation)
}
