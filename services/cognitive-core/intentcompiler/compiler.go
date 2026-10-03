// Package intentcompiler implements the Phase-1 Intent Compiler (M5 brief
// §4): TextRequest -> Compile() -> ir.RawIR. It is deliberately
// deterministic (M5 brief §7) — no LLM, model provider, or embedding call
// exists anywhere in this package, and none may be added without an
// approved ADR (Future phases may replace or augment this compiler behind
// the same RawIR-producing contract; this package's internal grammar is
// not baked into that contract — see CompilerVersion below).
//
// This compiler's authority ends at structured interpretation (M5 brief
// §4): it never produces an authorization token, a policy decision, an
// Execution Envelope, or a direct Capability Bus/filesystem/system call —
// grep-verifiable: this module (friday/cognitive-core) has no dependency
// anywhere on friday/policy-engine, friday/capability-bus, or
// friday/policytoken (see go.mod — it imports only friday/ir).
//
// Security-relevant IR fields (risk.level, effects.reversible, the AAL
// implied by risk, verification.required/method) are NEVER derived from
// raw_text — they come exclusively from ir.Phase1Registry(), the same
// capability registry the M2 validator itself checks against (M5 brief
// §12, §13). There is no code path in this file that reads raw_text
// looking for words like "risk", "AAL", "policy", or "verification" —
// classify() (grammar.go) only ever extracts the two free-text arguments
// (title, body) for CREATE_NOTE; every other RawIR field comes from a
// fixed per-capability template or the registry.
package intentcompiler

import (
	"strings"

	"friday/cognitive-core/textrequest"
	"friday/ir"
)

// CompilerVersion identifies this deterministic grammar for RawIR's
// provenance.compiled_by field (M5 brief §23, §24) — versioned so a
// future model-based compiler can be distinguished in audit trails
// without changing the RawIR schema itself.
const CompilerVersion = "cognitive-core/intent-compiler/1.0.0-phase1-deterministic"

// capabilityTemplate holds the fields ir.CapabilitySchema does not carry
// (verification method name, data classification, human-readable
// description) for one of the two approved Phase-1 capabilities. Risk,
// reversibility, and the AAL-minimum check all come directly from
// ir.Phase1Registry() at Compile time, never duplicated here, so they
// cannot drift from the same table the M2 validator itself consults.
type capabilityTemplate struct {
	goalDescription    string
	contentIntent      string
	verificationMethod string
	dataRead           []string
	dataWritten        []string
	safeToRetryDefault bool
}

// Hand-synced with services/capability-bus/internal/registry/registry.go's
// VerificationMethod/DataRead/DataWritten values — disclosed, not hidden:
// ir.CapabilitySchema has no field for these, matching the same
// already-accepted "duplicated across modules, kept in sync by hand"
// tradeoff as ir's own RiskLevel/AAL types (see types.go's doc comment).
var capabilityTemplates = map[string]capabilityTemplate{
	"system.get_status": {
		goalDescription:    "Get the current system status",
		contentIntent:      "system.get_status",
		verificationMethod: "schema_conformance_against_live_self_model",
		dataRead:           []string{"self_model"},
		dataWritten:        nil,
		safeToRetryDefault: true,
	},
	"workspace.create_note": {
		goalDescription:    "Create a workspace note",
		contentIntent:      "workspace.create_note",
		verificationMethod: "post_write_existence_and_content_check",
		dataRead:           nil,
		dataWritten:        []string{"workspace_notes"},
		safeToRetryDefault: false, // conservative Phase-1 default; see idempotency.go doc note
	},
}

// Compile is a pure function of req: identical input always produces a
// byte-identical RawIR (M5-INTENT-010) — there is no time.Now() or
// crypto/rand call anywhere in this package. IRID is derived from
// req.RequestID (the caller/harness already guarantees uniqueness, the
// same pattern M3/M4's test harnesses use for task/execution IDs) and
// CreatedAt is req.ReceivedAt, not a fresh timestamp taken at compile
// time.
func Compile(req textrequest.TextRequest) (ir.RawIR, *CompileError) {
	if cerr := validateEnvelope(req); cerr != nil {
		return ir.RawIR{}, cerr
	}

	c := classify(req.RawText)
	switch c.Category {
	case CategoryGetSystemStatus:
		return buildRawIR(req, "system.get_status", map[string]interface{}{})
	case CategoryCreateNote:
		args := map[string]interface{}{"title": c.Title, "body": c.Body}
		return buildRawIR(req, "workspace.create_note", args)
	default:
		// CategoryAmbiguous, CategoryUnsupported, CategoryInvalid — c.Err
		// is always populated by classify() for every non-executable
		// category (see grammar.go).
		return ir.RawIR{}, c.Err
	}
}

func validateEnvelope(req textrequest.TextRequest) *CompileError {
	if strings.TrimSpace(req.RawText) == "" {
		return &CompileError{Code: ErrInvalidTextRequest, Message: "raw_text is empty or whitespace-only"}
	}
	if len(req.RawText) > textrequest.MaxRawTextBytes {
		return &CompileError{Code: ErrInvalidTextRequest, Message: "raw_text exceeds the Phase-1 maximum length"}
	}
	if req.RequestID == "" {
		return &CompileError{Code: ErrInvalidTextRequest, Message: "request_id is required"}
	}
	if req.Actor == "" {
		return &CompileError{Code: ErrInvalidTextRequest, Message: "actor is required"}
	}
	return nil
}

func buildRawIR(req textrequest.TextRequest, capabilityID string, args map[string]interface{}) (ir.RawIR, *CompileError) {
	schema := ir.Phase1Registry()[capabilityID] // presence guaranteed: capabilityID always one of the two literal strings above
	tmpl := capabilityTemplates[capabilityID]

	digest, err := ir.ArgumentsDigest(args)
	if err != nil {
		// Statistically unreachable (args here is always a map of plain
		// Go strings, which json.Marshal never fails on) but propagated
		// rather than silently discarded — "do not fabricate" applies to
		// swallowed errors too, not only invented results.
		return ir.RawIR{}, &CompileError{Code: ErrIRCompilationFailed, Message: "failed to compute arguments digest: " + err.Error()}
	}

	hasSideEffect := len(tmpl.dataWritten) > 0

	raw := ir.RawIR{
		IRVersion:     ir.SupportedSchemaVersion,
		IRID:          "ir-" + req.RequestID,
		CorrelationID: req.CorrelationID,
		CausationID:   "", // root: direct compilation of a user utterance (J.2)
		CreatedAt:     req.ReceivedAt,
		Source: ir.Source{
			Actor:         req.Actor,
			SessionID:     req.SessionID,
			InputModality: "text",
		},
		Goal: ir.Goal{
			Type:        capabilityID,
			Description: tmpl.goalDescription,
		},
		Entities: nil, // Phase-1's two capabilities need no reference resolution
		Content: ir.Content{
			Intent:     tmpl.contentIntent,
			Parameters: args,
		},
		Constraints: nil,
		Effects: ir.Effects{
			ExternalCommunication: false,
			DataWritten:           tmpl.dataWritten,
			DataRead:              tmpl.dataRead,
			DeviceStateChange:     false,
			Financial:             false,
			Reversible:            schema.RegisteredReversible, // from the registry, never from user text
		},
		Risk: ir.Risk{
			Level: schema.RegisteredRiskLevel, // from the registry, never from user text (M5-SEC-004)
		},
		Cancellation: ir.Cancellation{
			Cancellable:        true,
			CancellationEffect: ir.CancellationNoneYetStarted,
		},
		Idempotency: ir.Idempotency{
			IdempotencyKey: req.CorrelationID + ":" + capabilityID + ":" + digest,
			SafeToRetry:    tmpl.safeToRetryDefault,
		},
		Dependencies: nil, // Phase-1: one utterance -> one IR document, no decomposition
		Verification: ir.Verification{
			Required: true, // from the registry (schema.VerificationRequired), never from user text (M5-SEC-003)
			Method:   tmpl.verificationMethod,
		},
		KnowledgeState: nil,
		Provenance: ir.Provenance{
			CompiledBy: CompilerVersion,
			ModelUsed:  "none (deterministic grammar, no ML/LLM model involved)",
		},
	}

	if hasSideEffect {
		raw.ExpectedOutcome = ir.ExpectedOutcome{
			Description:      "the requested capability executes and its declared verification method confirms success",
			SuccessCondition: map[string]interface{}{"ok": true},
		}
	} else {
		// Not required by stage 3 for a non-side-effecting capability, but
		// harmless and consistent to declare anyway.
		raw.ExpectedOutcome = ir.ExpectedOutcome{
			Description:      "the requested read completes and returns a schema-conformant result",
			SuccessCondition: map[string]interface{}{"ok": true},
		}
	}

	return raw, nil
}
