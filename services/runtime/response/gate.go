// M8 closure milestone: the Response Validation Gate
// (docs/MN-memory-and-knowledge-architecture.md §N.2.1 — "every user-
// facing response that asserts a factual claim passes through a Response
// Validation Gate before being emitted... fail closed... not fail
// open"), implementing exactly two requirement IDs together, since the
// SRS itself cross-references them as one mechanism described from two
// angles:
//
//   - FR-KNOW-002: "The system SHALL prefer stating 'I don't know yet;
//     I need to verify this' over generating an unsupported answer,
//     enforced by the Response Validation Gate."
//   - NFR-KNOW-001: the gate itself — "a claim tagged UNKNOWN, or
//     carrying no knowledge_state tag at all, SHALL NOT be emitted
//     phrased as a known fact."
//
// §N.2.1's gate operates on a `knowledge_state` tag attached to each
// factual assertion (N.2: KNOWN/LIVE/CACHED/INFERRED/PREDICTED/UNKNOWN).
// Phase 1 makes exactly ONE kind of factual claim to a user at all — "did
// the requested capability succeed" — since M7's response templates are
// fixed and never assert anything else (no free-form generation exists
// anywhere in Phase 1, see cognitive-core/pipeline's own structural
// no-LLM guarantee). This gate is therefore the literal, faithful,
// minimal Phase-1 instantiation of N.2.1 for that one claim: a
// success-shaped response is the KNOWN-state claim; anything the gate
// cannot affirmatively confirm is treated as UNKNOWN and blocked from
// success wording, exactly matching N.2.1's "no attached knowledge_state
// at all... treated as UNKNOWN by default — fail closed."
package response

import "friday/runtime-store/store"

// Claim is what a caller asks the gate to validate before emitting a
// user-facing response — the Phase-1 analog of a "factual assertion"
// carrying a knowledge_state tag, built entirely from durable, already-
// verified facts (never from raw_text, never from an LLM's own
// self-assessment — see the package doc's "structural, not behavioral"
// point, mirrored from N.2.1 itself).
type Claim struct {
	TaskState             store.TaskState
	VerificationRequired  bool
	VerificationConfirmed bool // true only if a real VerificationResult with Result == VerificationSucceeded was recorded
	PersistenceOK         bool // false if a required durable write failed
}

// knowledgeState mirrors N.2's state machine, restricted to what a
// Claim can actually resolve to in Phase 1.
type knowledgeState string

const (
	stateKnown   knowledgeState = "KNOWN"   // task genuinely SUCCEEDED with confirmed verification
	stateUnknown knowledgeState = "UNKNOWN" // anything the gate cannot affirmatively confirm — the fail-closed default
)

// classify is the gate's only decision function — deterministic, no LLM,
// unit-testable independent of any specific model (N.2.1's own
// "Testability" note).
func classify(c Claim) knowledgeState {
	if !c.PersistenceOK {
		return stateUnknown
	}
	if c.TaskState != store.StateSucceeded {
		return stateUnknown
	}
	if c.VerificationRequired && !c.VerificationConfirmed {
		return stateUnknown
	}
	return stateKnown
}

// ValidateSuccessClaim is the gate's public API (NFR-KNOW-001): callers
// pass the candidate success response together with the Claim it would
// assert, and get back either the same response (state == KNOWN) or a
// safe, honest substitute (state == UNKNOWN, matching N.2.1's own
// prescribed substitution: "I don't know yet; I need to verify this,"
// adapted to Phase 1's execution-outcome domain rather than a knowledge-
// retrieval domain). There is no way to call this function and get the
// candidate response back for anything other than a genuinely KNOWN
// claim — the zero-value Claim{} (nothing set) classifies as UNKNOWN,
// which is the concrete form of "no attached knowledge_state at all ...
// treated as UNKNOWN by default."
func ValidateSuccessClaim(candidate Response, c Claim) Response {
	if classify(c) == stateKnown {
		return candidate
	}
	// FR-KNOW-002's literal preferred wording, applied to the one domain
	// Phase 1 actually has claims about.
	return Response{Outcome: OutcomeVerificationFailed, TaskID: candidate.TaskID,
		Text: "I don't know yet whether that completed successfully; I need to verify this before I can confirm it."}
}
