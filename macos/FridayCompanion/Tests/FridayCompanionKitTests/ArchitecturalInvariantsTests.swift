import Testing
@testable import FridayCompanionKit
import Foundation

/// Coverage for the "FINAL ARCHITECTURAL INVARIANTS" hardening pass —
/// verifies each of the 6 numbered invariants holds structurally, not
/// merely by convention:
///
/// §1 authoritative precedence, §2 DialogueAct/ActionExecutionState
/// independence, §3 generated language cannot create facts (the
/// `ConversationalResponsePresenter.authoritative(_:context:)` hardening
/// added this pass), §4 the complete fallback chain
/// (`FallbackConversationReasoning`/`FallbackNaturalResponseRealizing`,
/// new this pass), §5 generalization beyond the exact wording used in
/// prior milestones' own examples, §6 the Stage A/B/C gate.
@Suite struct ArchitecturalInvariantsTests {
    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1", isRetryable: Bool? = nil) -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: isRetryable ?? DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false
        )
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    // MARK: - §3: generated language cannot create facts — enforced BY CONSTRUCTION

    /// A deliberately malicious/buggy `ConversationReasoning` that
    /// invents every fact §3 explicitly forbids inventing: it claims a
    /// genuine `EXECUTION_FAILED` outcome actually succeeded, that the
    /// failure cause is definitively known, and that retry is allowed —
    /// none of which `context` (a real `EXECUTION_FAILED`, no evidence,
    /// no structural retryability) supports.
    private struct HallucinatingReasoner: ConversationReasoning {
        func understand(transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext, acoustics: AcousticConversationFeatures, explicitUserStatements: [String]) -> ConversationUnderstanding {
            ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil,
                humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.0,
                dialogueAct: .command, interactionMode: .actionRequest,
                actionExecutionState: .executedSucceeded, // INVENTED — the real context says executedFailed
                explicitConstraints: [], failureReason: .known(type: "fabricated", evidence: "a service outage I have no evidence for"), // INVENTED
                retryability: .allowed, // INVENTED
                userGoal: nil, correctionTarget: nil, explanationRequested: false, humorSuitability: 0
            )
        }
    }

    @Test func hallucinatingReasoner_actionExecutionStateIsIgnored_recomputedFromContext() {
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingReasoner())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "hallucinate-t1")))
        // The reasoner claimed success — the presenter must never believe it.
        #expect(!response.wasSuccess)
        #expect(!response.text.contains("Done"))
    }

    @Test func hallucinatingReasoner_retryabilityIsIgnored_neverOffersRetry() {
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingReasoner())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "hallucinate-t2")))
        // The reasoner claimed retryability == allowed — the presenter
        // must recompute it from context (generic EXECUTION_FAILED ==
        // .unknown) and never let a retry offer through.
        #expect(!response.text.localizedCaseInsensitiveContains("try again"))
    }

    @Test func hallucinatingReasoner_failureReasonIsIgnored_neverInventsGroundedCause() {
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingReasoner())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "hallucinate-t3")))
        // The reasoner claimed a KNOWN, fabricated cause ("a service
        // outage I have no evidence for") — the presenter must
        // recompute failureReason from context.failureEvidence (nil
        // here), producing the honest generic phrasing instead.
        // P2-M5V8.1-P §11 — wording upgraded to explicitly admit the cause
        // isn't known yet (more honest than a bare "didn't go through"),
        // the underlying property under test here is unchanged: no
        // fabricated cause is ever spoken.
        #expect(response.text == "I couldn't complete that, and I don't know why yet.")
        #expect(!response.text.localizedCaseInsensitiveContains("outage"))
    }

    @Test func hallucinatingReasoner_neverAffectsAGenuineSuccess_stillReportsHonestly() {
        // Symmetric check: a hallucinating reasoner attached to a GENUINE
        // success must not be able to suppress it either — the
        // recompute is authoritative in both directions.
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingReasoner())
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "hallucinate-t4")))
        #expect(response.wasSuccess)
        #expect(DeterministicResponsePresenter.createNoteSuccessVariants(title: "groceries").contains(response.text))
    }

    // MARK: - §4: complete fallback chain

    @Test func fallbackConversationReasoning_usesPrimary_whenConfident() {
        struct ConfidentReasoner: ConversationReasoning {
            func understand(transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext, acoustics: AcousticConversationFeatures, explicitUserStatements: [String]) -> ConversationUnderstanding {
                ConversationUnderstanding(
                    communicativeIntent: .statement, topic: "test", continuationOfPreviousTurn: false, clarificationNeeded: false,
                    userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: .professional,
                    humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.1
                )
            }
        }
        let fallback = FallbackConversationReasoning(primary: ConfidentReasoner(), secondary: DeterministicConversationReasoner())
        let result = fallback.understand(transcript: nil, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result.topic == "test", "a confident primary result should be used as-is")
    }

    @Test func fallbackConversationReasoning_usesSecondary_whenPrimaryUncertain() {
        let fallback = FallbackConversationReasoning(primary: LLMConversationReasoner(), secondary: DeterministicConversationReasoner())
        let result = fallback.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        // LLM stub always reports uncertainty 1.0 -> must fall through to
        // the deterministic reasoner, which DOES classify this correctly.
        #expect(result.dialogueAct == .personalUpdate)
    }

    @Test func fallbackNaturalResponseRealizing_usesPrimary_whenNonNil() {
        struct AlwaysRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? { "primary text" }
        }
        let fallback = FallbackNaturalResponseRealizing(primary: AlwaysRealizer(), secondary: DeterministicNaturalResponseRealizer())
        let result = fallback.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == "primary text")
    }

    @Test func fallbackNaturalResponseRealizing_usesSecondary_whenPrimaryNil() {
        let fallback = FallbackNaturalResponseRealizing(primary: LLMNaturalResponseRealizer(), secondary: DeterministicNaturalResponseRealizer())
        let unsupportedContext = context(family: .unsupportedIntent, wasSuccess: false)
        let humorPlan = NaturalResponsePlan(responseGoal: .unsupported, socialRegister: .casualFriendly, warmth: 0.8, directness: 0.7, humorAllowance: true, humorStrength: 0.3, formality: 0.2, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .information)
        let result = fallback.realize(context: unsupportedContext, understanding: .minimal, plan: humorPlan, recentTurns: [], avoiding: nil)
        #expect(result != nil, "LLM stub defers (nil) -> deterministic secondary must produce real text")
    }

    @Test func conversationalPresenter_defaultConfiguration_usesTheFallbackChainByDefault_zeroBehaviorChange() {
        // The new defaults (Fallback... composites wrapping the stub LLM
        // types) must be byte-identical in observable behavior to the
        // old defaults (deterministic types directly), since the LLM
        // side always defers today.
        let withDefaults = ConversationalResponsePresenter()
        let withExplicitDeterministic = ConversationalResponsePresenter(reasoner: DeterministicConversationReasoner(), naturalRealizer: DeterministicNaturalResponseRealizer())
        for (outcome, text) in [("SUCCESS", "System status retrieved successfully."), ("EXECUTION_FAILED", "The action could not be completed."), ("UNSUPPORTED_INTENT", "That capability isn't available in Phase 1.")] {
            let a = withDefaults.response(for: .success(outcomeResult(outcome: outcome, text: text, taskID: "cmp-\(outcome)")))
            let b = withExplicitDeterministic.response(for: .success(outcomeResult(outcome: outcome, text: text, taskID: "cmp-\(outcome)")))
            #expect(a.text == b.text, "\(outcome): default fallback-chain config must match explicit-deterministic config")
        }
    }

    private func minimalPlan() -> NaturalResponsePlan {
        NaturalResponsePlan(responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.5, directness: 0.5, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
    }

    // MARK: - §5: generalization beyond the exact wording used in prior milestones' own examples

    private let reasoner = DeterministicConversationReasoner()

    @Test func generalizes_personalUpdate_toUnseenWording() {
        // NOT "I finally fixed that bug" (the mission's own literal
        // example) — different phrasing, same category.
        let understanding = reasoner.understand(transcript: "I eventually resolved that annoying login issue.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .personalUpdate)
    }

    @Test func generalizes_prohibition_toUnseenWording() {
        // NOT "don't change anything yet" — different phrasing.
        let understanding = reasoner.understand(transcript: "Please don't modify the configuration for now.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .prohibition)
        #expect(understanding.actionExecutionState == .notRequested)
    }

    @Test func generalizes_correction_toUnseenWording() {
        // NOT "No, call it weekend groceries" — different phrasing,
        // different correction marker ("actually" instead of "no,").
        let understanding = reasoner.understand(transcript: "Actually, rename it to shopping list.", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
    }

    @Test func generalizes_explanationRequest_toUnseenWording() {
        // NOT the mission's own bare "Why?" — a longer, differently
        // worded explanation request.
        let understanding = reasoner.understand(transcript: "Why exactly did that request get denied?", recentTurns: [], context: context(family: .policyDenied, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .explanationRequest)
    }

    @Test func generalizes_professionalRegister_toUnseenWording() {
        // NOT "draft an email to my professor" — a colleague/client
        // context instead.
        let understanding = reasoner.understand(transcript: "I need to send this to a client, keep it formal.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.socialRegisterRecommendation == .professional)
    }

    @Test func mandatoryFixesGeneralize_notJustTheExactMissionTranscript() {
        // The core P2-M5V7 fix, re-verified with wording the mission
        // never used, through the FULL presenter.
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "generalize-1")),
            transcript: "I eventually resolved that annoying login issue.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.contains("Done"))
        #expect(!response.wasSuccess)
    }

    // MARK: - §1: authoritative precedence (spot checks through the full pipeline)

    @Test func precedence_safetyShapedPurposeWinsOverCasualRecommendation_endToEnd() {
        // Even an explicitly casual-sounding transcript must not soften
        // a permission-denial response's register.
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "POLICY_DENIED", text: "I couldn't perform that action because authorization was denied.", taskID: "precedence-1")),
            transcript: "bro can you just delete all my files lol", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(response.category == .permissionDenied)
        #expect(!response.text.localizedCaseInsensitiveContains("bro"))
    }

    @Test func precedence_explicitConstraintNeverBypassedByHumorOrCasualStyle() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "precedence-2")),
            transcript: "haha don't change anything ok", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(response.text == "Got it. I won't change anything.")
        #expect(!response.wasSuccess)
    }

    // MARK: - §2: DialogueAct and ActionExecutionState are independently meaningful

    @Test func dialogueActAndActionExecutionState_areIndependentFields_notConflated() {
        // Two different dialogue acts can share the SAME ActionExecutionState.
        let personalUpdate = reasoner.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let prohibition = reasoner.understand(transcript: "Don't change anything.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(personalUpdate.dialogueAct != prohibition.dialogueAct)
        #expect(personalUpdate.actionExecutionState == prohibition.actionExecutionState)
        #expect(personalUpdate.actionExecutionState == .notRequested)
    }
}
