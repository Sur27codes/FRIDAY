import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-P.2-FINAL-CLOSURE — coverage for the two systematic
/// blockers this pass fixes, and nothing else:
///
/// - BLOCKER A: after ONE-CALL/two-stage candidate rejection, the safety
///   net (`ConversationalResponsePresenter.safetyNetResponse`) must
///   preserve whatever authoritative failure specificity FRIDAY locally
///   knows (known cause / genuine unknown / retry option / permission
///   denial / unsupported-capability truth) instead of flattening every
///   non-`.notRequested` state to the old generic base text.
/// - BLOCKER B: an unresolved GENERIC ambiguous referential correction
///   ("the other one," "that one") must actually ask for clarification,
///   never pretend acknowledgement equals resolution.
///
/// All transcripts here are either the mission's own live-cited evidence
/// (verbatim) or fresh, unseen phrasings — none duplicate an existing
/// `PersonaP2Tests.swift` transcript. Every scenario forces the
/// candidate-rejection path the same proven way `SemanticConversationTests`
/// already does: inject a `NaturalConversationRealizing` stand-in whose
/// text validation is guaranteed to reject (a false completion claim, or
/// a confident-sounding but ungrounded guess), then assert on the FINAL
/// spoken text `safetyNetResponse` actually produces. Nothing here
/// touches `ResponseScope`/authority/`ExecutionClaimDetector`/humor
/// policy — all frozen this pass.
@Suite struct PersonaP2FinalTests {
    /// A candidate realizer that always proposes the same (rejectable)
    /// text, standing in for "the model produced something that gets
    /// rejected by validation" — regardless of which architecture
    /// (two-stage or ONE-CALL) it came from, both funnel rejection
    /// through the exact same `safetyNetResponse` this suite exercises.
    private struct HallucinatingRealizer: NaturalConversationRealizing {
        let text: String
        func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
            text
        }
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    // MARK: - §21 — fallback truth parity (5 required cases, unseen wording)

    @Test func fallbackParity_knownCause_preservedAfterCandidateRejection() {
        // A confident but entirely fabricated completion claim for a
        // connectivity failure that DOES have known evidence — must be
        // rejected, and the fallback must surface the TRUE known cause,
        // not the old generic flat text.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "All set — I synced your calendar just now."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "final-1")),
            transcript: "Update my calendar.", acoustics: .unavailable, explicitUserStatements: [],
            failureEvidence: "connection refused, service unreachable"
        )
        #expect(!response.text.localizedCaseInsensitiveContains("synced"), "the fabricated completion claim must never survive")
        #expect(response.text.localizedCaseInsensitiveContains("reach"), "the fallback must preserve the KNOWN connectivity cause, not degrade to generic wording")
    }

    @Test func fallbackParity_unknownCause_explicitUncertaintyPreservedAfterCandidateRejection() {
        // Same fabricated-completion shape, but this time there is
        // genuinely NO known cause — the fallback must say so honestly,
        // never invent one and never silently go generic either.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "Done — that's fixed now."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "final-2")),
            transcript: "Update my calendar.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("fixed"), "the fabricated completion claim must never survive")
        #expect(response.text.localizedCaseInsensitiveContains("don't know"), "a genuinely unknown cause must stay explicitly honest, never flattened to a bare non-committal phrase")
    }

    @Test func fallbackParity_retryableFailure_retryOptionPreservedAfterCandidateRejection() {
        // §8 regression target: after the Blocker A fix, a retryable
        // failure whose candidate gets rejected must STILL correctly
        // surface retry availability — the fix must not have
        // accidentally lost this in the process of adding specificity.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "That's taken care of."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "CAPABILITY_UNAVAILABLE", text: "The action could not be completed.", taskID: "final-3")),
            transcript: "Update my calendar.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("taken care"), "the fabricated completion claim must never survive")
        #expect(response.text.localizedCaseInsensitiveContains("try again"), "a structurally retryable failure must still offer retry after candidate rejection")
    }

    @Test func fallbackParity_permissionDenied_denialTruthPreservedAfterCandidateRejection() {
        // "submitted" is a recognized completion-claim trigger verb with
        // "I" as its subject (FRIDAY claiming the action for itself) —
        // guaranteed to be caught by the existing, unchanged
        // `ExecutionClaimDetector`/`neverClaimsExecutionBeyondAuthority` guard.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "Don't worry, I submitted it anyway."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "POLICY_DENIED", text: "Not authorized.", taskID: "final-4")),
            transcript: "Can you wire the funds now?", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("submitted"), "a claimed override of a denial must never survive")
        #expect(
            response.text.localizedCaseInsensitiveContains("permission") || response.text.localizedCaseInsensitiveContains("approval"),
            "the fallback must preserve the TRUE denial, not a fabricated override"
        )
    }

    @Test func fallbackParity_unsupportedCapability_unsupportedTruthPreservedAfterCandidateRejection() {
        // "booked" is a recognized completion-claim trigger verb with "I"
        // as its subject — guaranteed rejection by the same unchanged guard.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "Don't worry, I booked it already."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "Not supported.", taskID: "final-5")),
            transcript: "Can you book me a flight to Tokyo?", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("booked"), "a claimed completion of an unsupported capability must never survive")
        // The truth ("this isn't something I can do") may be expressed
        // either via the flat base variants or (since humor is locally
        // permitted here, unaffected by this pass — humor policy is
        // frozen) one of the humor-flavored unsupported-intent variants;
        // either is truthful, neither is the fabricated completion claim.
        let truthfulUnsupportedVariants = DeterministicResponseRealizer.unsupportedIntentVariants
            + ["Not quite in my skill set yet.", "Not yet. Give me a little more time.", "I can't do that one yet.", "Afraid not. My launch credentials are conspicuously absent."]
        #expect(truthfulUnsupportedVariants.contains(response.text), "the fallback must preserve the TRUE unsupported-capability fact, not the fabricated claim")
    }

    // MARK: - §22 — referential ambiguity (resolved / ambiguous / missing, via the reused `correctionTarget` field)

    @Test func referential_firstOne_resolvesWithoutClarification() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-1a")), transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: [])
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-1b")), transcript: "Actually, the first one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(!response.text.contains("?"), "a uniquely grounded backward reference is RESOLVED — it must not ask for clarification")
        #expect(response.text.localizedCaseInsensitiveContains("earlier"), "must acknowledge the EXISTING item, never imply a new one")
    }

    @Test func referential_earlierOne_resolvesWithoutClarification() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-2a")), transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: [])
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-2b")), transcript: "No, the earlier one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(!response.text.contains("?"))
        #expect(response.text.localizedCaseInsensitiveContains("earlier"))
    }

    @Test func referential_theOtherOne_ambiguous_asksForClarification() {
        // The mission's own live-cited evidence, verbatim: "No, I meant
        // the other one." used to get "Right—the other one." — a
        // confident-sounding non-answer. Must now ask, not assert.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-3a")), transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: [])
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-3b")), transcript: "No, I meant the other one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(response.text.contains("?"), "an ungrounded generic referent must trigger an actual clarifying question")
        #expect(!response.text.localizedCaseInsensitiveContains("right—"), "must never sound like a confident, resolved acknowledgement")
    }

    @Test func referential_thatOne_missingCandidate_asksForClarification() {
        // No prior artifact/turn context established at all — "missing"
        // grounding, not merely "multiple." Behaviorally identical
        // requirement to the ambiguous case: ask, never guess.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-4")), transcript: "Wait, that one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(response.text.contains("?"), "a referent with no grounded candidate at all must still ask, never guess")
    }

    @Test func referential_namedTarget_resolvesWithoutClarification() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-5a")), transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: [])
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-5b")), transcript: "No, I meant groceries.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(!response.text.contains("?"), "a NAMED target is already grounded by the name itself — nothing to clarify")
    }

    @Test func referential_confidentAmbiguousGuess_rejectedByGuardDirectly() {
        // Guard-level proof, independent of any realizer: a candidate
        // that confidently answers an ambiguous referent must fail
        // validation on its own terms.
        #expect(!ResponseValidation.referentialAmbiguityRequiresClarification("Right—the other one.", dialogueAct: .correction, correctionTarget: "ambiguous"))
        #expect(ResponseValidation.referentialAmbiguityRequiresClarification("Which one do you mean?", dialogueAct: .correction, correctionTarget: "ambiguous"))
        // Unaffected cases: guard is a no-op outside the ambiguous sentinel.
        #expect(ResponseValidation.referentialAmbiguityRequiresClarification("Got it—the earlier one.", dialogueAct: .correction, correctionTarget: "earlier"))
        #expect(ResponseValidation.referentialAmbiguityRequiresClarification("Got it—the earlier one.", dialogueAct: .statement, correctionTarget: nil))
    }

    @Test func referential_confidentAmbiguousGuess_rejectedEndToEnd() {
        // End-to-end version of the guard-level proof above: a candidate
        // realizer that guesses confidently for an ambiguous referent
        // must never reach the user unchanged.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "Right—the other one."), memory: memory)
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "ref-6")), transcript: "No, I meant the other one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(response.text != "Right—the other one.")
        #expect(response.text.contains("?"))
    }

    // MARK: - §13 regression — resolved-reference naturalness unaffected by the Blocker B fix

    @Test func regression_resolvedReferenceNaturalness_unaffectedByAmbiguityFix() {
        // The exact P.1-era scenario: a compound phrase carrying BOTH a
        // generic pronoun ("that one") AND a specific backward reference
        // ("the first one") must still resolve to the SPECIFIC one — the
        // new ambiguous-phrase check must never shadow the pre-existing,
        // more specific "earlier" check it was added alongside.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "reg13-a")), transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: [])
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "reg13-b")), transcript: "Sorry, not that one — the first one.", acoustics: .unavailable, explicitUserStatements: [])
        #expect(response.text == "Got it—the earlier one.")
        #expect(!response.text.contains("?"), "the specific backward reference must win over the generic pronoun sharing the same sentence")
    }

    // MARK: - §15 regression — execution-claim discipline unaffected by the safetyNetResponse rewrite

    @Test func regression_executedSucceeded_completionClaimMayPass() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I sent the email."))
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority("I sent the email.", actionExecutionState: .executedSucceeded))
    }

    @Test func regression_notSucceeded_completionClaimRejected() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I sent the email.", actionExecutionState: .executedFailed))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I sent the email.", actionExecutionState: .denied))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I sent the email.", actionExecutionState: .unsupported))
    }

    @Test func regression_futureIntentionWording_remainsAllowedEvenWhenNotSucceeded() {
        // Future/intention wording ("I'll send it") never claims a PAST
        // completed action — must stay allowed regardless of state.
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I'll send the email."))
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority("I'll send the email.", actionExecutionState: .executedFailed))
    }

    // MARK: - Live-evidence end-to-end reproduction (P4b, verbatim shape)

    @Test func liveEvidence_P4b_oneCallStyleRejection_noLongerFlattensToGenericText() {
        // Reproduces the mission's own disclosed live bug end-to-end：a
        // candidate that invents an ungrounded cause for a KNOWN
        // connectivity failure must be rejected, and the fallback must
        // no longer be the old generic "I couldn't complete that
        // request." — it must be the grounded, specific truth.
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer(text: "I couldn't reach the database server that time."))
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "p4b-repro")),
            transcript: "Update my calendar.", acoustics: .unavailable, explicitUserStatements: [],
            failureEvidence: "connection refused, service unreachable"
        )
        #expect(response.text == "I couldn't reach the service that time.")
        #expect(response.text != "I couldn't complete that request.", "the old, specificity-losing generic fallback must never resurface")
    }
}
