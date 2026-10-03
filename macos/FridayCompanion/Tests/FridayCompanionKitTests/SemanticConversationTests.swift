import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V7 §28/§29/§30 — dedicated coverage for the semantic upgrade:
/// `DialogueAct`/`InteractionMode`/`ActionExecutionState`/`ExplicitConstraint`/
/// `FailureReason`/`Retryability`, `ConversationUnderstanding` 2.0,
/// `ResponseValidation` 2.0, `HumorDecision`, and — most importantly —
/// the exact mandatory regression tests §28 calls out by name (the
/// concrete "Done." bugs this milestone exists to fix). P2-M5V6's own
/// `ConversationalIntelligenceTests.swift` remains unmodified and
/// continues to pass, proving zero regression in everything it already
/// covered.
@Suite struct SemanticConversationTests {
    private let reasoner = DeterministicConversationReasoner()

    private func context(
        family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1", isRetryable: Bool? = nil, failureEvidence: String? = nil
    ) -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: isRetryable ?? DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false,
            failureEvidence: failureEvidence
        )
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    // MARK: - DialogueAct classification

    @Test func dialogueAct_personalUpdate_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .personalUpdate)
        #expect(understanding.interactionMode == .conversational)
    }

    @Test func dialogueAct_prohibition_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "This is important. Don't change anything yet.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .prohibition)
        #expect(understanding.interactionMode == .constraint)
        #expect(understanding.explicitConstraints == [.doNotModify])
    }

    @Test func dialogueAct_correction_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "No, call it weekend groceries.", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
        #expect(understanding.interactionMode == .correction)
    }

    @Test func dialogueAct_explanationRequest_fullQuestion_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "Why didn't that work?", recentTurns: [], context: context(family: .executionFailed, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .explanationRequest)
        #expect(understanding.explanationRequested)
        #expect(understanding.interactionMode == .informationRequest)
    }

    @Test func dialogueAct_explanationRequest_bareWhy_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "Why?", recentTurns: [], context: context(family: .policyDenied, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .explanationRequest)
    }

    @Test func dialogueAct_followUp_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "Can you check it again?", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .followUp)
    }

    @Test func dialogueAct_socialRemark_classifiesCorrectly() {
        let understanding = reasoner.understand(transcript: "That was annoying.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .socialRemark)
        #expect(understanding.interactionMode == .conversational)
    }

    @Test func dialogueAct_greetingAndFarewell_classifyCorrectly() {
        let greeting = reasoner.understand(transcript: "Hello there.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(greeting.dialogueAct == .greeting)
        let farewell = reasoner.understand(transcript: "Goodbye for now.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(farewell.dialogueAct == .farewell)
    }

    @Test func dialogueAct_greeting_withFillerLeadIn_stillClassifiesAsGreeting_notFallbackStatement() {
        // P2-M5V8.1-HW §13 — proven regression, reproduced live via the
        // provider-dialogue harness's own "Hey, good morning." scenario:
        // greeting matching used to require an EXACT match or the greeting
        // to be the very first words (unlike its own sibling `farewellMarkers`
        // check, which already matched anywhere), so a real filler lead-in
        // fell through every marker table to the generic `.statement`
        // default and incorrectly inherited whatever synthetic SUCCESS
        // outcome happened to be attached ("Done."), even though nothing
        // was actually requested. Fixed to match `farewellMarkers`'
        // already-correct "anywhere" pattern.
        let understanding = reasoner.understand(transcript: "Hey, good morning.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .greeting)
        #expect(understanding.interactionMode == .conversational)
        #expect(understanding.actionExecutionState == .notRequested, "a greeting must never inherit a synthetic action-success outcome")
    }

    @Test func interactionMode_derivedCorrectly_forEveryDialogueAct() {
        // P2-M5V8.1-S §3/§4/§5 — `.request`/`.followUp`/`.statement` are
        // now evidence-gated rather than unconditionally `.actionRequest`
        // (the root cause of "It was one environment variable." → "Done."
        // and "Production is down now." → "Done."): absence of positive
        // `ActionRequestEvidence` must resolve to a SAFE default
        // (`.informationRequest` for a question-shaped `.request`,
        // `.conversational` for `.followUp`/`.statement`), never silently
        // inverted to always-conversational either (§3: that would merely
        // invert the bug) — the WITH-evidence half of this test proves
        // `.actionRequest` is still reachable for a genuine command.
        let noEvidenceExpectations: [(DialogueAct, InteractionMode)] = [
            (.command, .actionRequest), (.request, .informationRequest), (.question, .informationRequest), (.statement, .conversational),
            (.personalUpdate, .conversational), (.acknowledgement, .conversational), (.correction, .correction),
            (.clarification, .clarification), (.constraint, .constraint), (.prohibition, .constraint),
            (.permissionResponse, .actionRequest), (.followUp, .conversational), (.explanationRequest, .informationRequest),
            (.confirmationRequest, .informationRequest), (.socialRemark, .conversational), (.jokeOrPlayfulRemark, .conversational),
            (.greeting, .conversational), (.farewell, .conversational), (.unknown, .actionRequest),
            (.needStatement, .actionRequest), (.styleRefinement, .actionRequest),
        ]
        for (act, expectedMode) in noEvidenceExpectations {
            #expect(DeterministicConversationReasoner.interactionMode(for: act, evidence: .none) == expectedMode, "\(act) with NO evidence should map to \(expectedMode)")
        }

        let positiveEvidence = ActionRequestEvidence(explicitActionVerb: true, imperativeStructure: true)
        for act: DialogueAct in [.request, .followUp, .statement] {
            #expect(DeterministicConversationReasoner.interactionMode(for: act, evidence: positiveEvidence) == .actionRequest, "\(act) WITH positive evidence should still be reachable as .actionRequest")
        }
    }

    // MARK: - ActionExecutionState (§3)

    @Test func actionExecutionState_conversational_alwaysNotRequested_evenWithSyntheticSuccessOutcome() {
        // The core fix: a SUCCESS-shaped outcome attached to a
        // conversational utterance must never flip this to executedSucceeded.
        let understanding = reasoner.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.actionExecutionState == .notRequested)
    }

    @Test func actionExecutionState_constraint_alwaysNotRequested() {
        let understanding = reasoner.understand(transcript: "Don't change anything.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.actionExecutionState == .notRequested)
    }

    @Test func actionExecutionState_actionRequest_derivedFromRealOutcome() {
        let succeeded = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(succeeded.actionExecutionState == .executedSucceeded)
        let denied = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .policyDenied, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(denied.actionExecutionState == .denied)
        let unsupported = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(unsupported.actionExecutionState == .unsupported)
        let failed = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .executionFailed, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(failed.actionExecutionState == .executedFailed)
        let pending = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .ambiguousIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(pending.actionExecutionState == .requestedNotStarted)
    }

    // MARK: - FailureReason / Retryability (§5/§6) — the mandatory regression tests

    @Test func mandatoryRegression_genericExecutionFailed_failureReasonIsUnknown_neverInvented() {
        let understanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .executionFailed, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.failureReason == .unknown)
    }

    @Test func failureReason_withRealEvidence_becomesKnown() {
        let understanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .executionFailed, wasSuccess: false, failureEvidence: "connection refused, service unreachable"), acoustics: .unavailable, explicitUserStatements: [])
        guard case .known(_, let evidence) = understanding.failureReason else {
            Issue.record("expected .known when evidence is supplied")
            return
        }
        #expect(evidence == "connection refused, service unreachable")
    }

    @Test func mandatoryRegression_genericExecutionFailed_retryabilityIsUnknown_notAllowed() {
        let understanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .executionFailed, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.retryability == .unknown, "§6: must not infer retryability from a generic execution failure")
    }

    @Test func retryability_capabilityUnavailable_isAllowed_whenStructurallyRetryable() {
        let understanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .capabilityUnavailable, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.retryability == .allowed)
    }

    @Test func retryability_neverAllowed_whenContextItselfIsNotRetryable() {
        let understanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .capabilityUnavailable, wasSuccess: false, isRetryable: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.retryability == .notAllowed)
    }

    // MARK: - ExplicitConstraint extraction (§4)

    @Test func explicitConstraints_waitFor_mapsToWaitForConfirmation() {
        let understanding = reasoner.understand(transcript: "Please wait for my confirmation before doing anything.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.explicitConstraints == [.waitForConfirmation])
    }

    @Test func explicitConstraints_justAnswer_mapsToAnswerOnly() {
        let understanding = reasoner.understand(transcript: "Don't do anything, just answer the question.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.explicitConstraints == [.answerOnly])
    }

    // MARK: - ResponseValidation 2.0 (§21)

    @Test func neverClaimsActionForNotRequested_rejectsCompletionWording() {
        #expect(!ResponseValidation.neverClaimsActionForNotRequested("Done. Your note's ready.", actionExecutionState: .notRequested))
        #expect(!ResponseValidation.neverClaimsActionForNotRequested("It's ready now.", actionExecutionState: .notRequested))
    }

    @Test func neverClaimsActionForNotRequested_allowsConversationalAcknowledgment() {
        #expect(ResponseValidation.neverClaimsActionForNotRequested("Nice. What ended up causing it?", actionExecutionState: .notRequested))
        #expect(ResponseValidation.neverClaimsActionForNotRequested("Got it. I won't change anything.", actionExecutionState: .notRequested))
    }

    @Test func neverClaimsActionForNotRequested_irrelevantWhenActionWasRequested() {
        #expect(ResponseValidation.neverClaimsActionForNotRequested("Done. Your note's ready.", actionExecutionState: .executedSucceeded))
    }

    @Test func neverOffersRetryUnlessAllowed_rejectsWhenNotAllowed() {
        #expect(!ResponseValidation.neverOffersRetryUnlessAllowed("That didn't go through. Want me to try again?", retryability: .unknown))
        #expect(!ResponseValidation.neverOffersRetryUnlessAllowed("Should I retry?", retryability: .notAllowed))
    }

    @Test func neverOffersRetryUnlessAllowed_allowsWhenAllowed() {
        #expect(ResponseValidation.neverOffersRetryUnlessAllowed("That didn't go through. Want me to try again?", retryability: .allowed))
    }

    @Test func neverInventsFailureCause_rejectsConnectivityClaimWithoutEvidence() {
        #expect(!ResponseValidation.neverInventsFailureCause("I couldn't reach it that time.", failureReason: .unknown))
        #expect(!ResponseValidation.neverInventsFailureCause("There was a connection issue.", failureReason: .unknown))
    }

    @Test func neverInventsFailureCause_allowsGenericPhrasingWithoutEvidence() {
        #expect(ResponseValidation.neverInventsFailureCause("That didn't go through.", failureReason: .unknown))
    }

    @Test func neverInventsFailureCause_allowsConnectivityClaimWhenGrounded() {
        #expect(ResponseValidation.neverInventsFailureCause("I couldn't reach the service that time.", failureReason: .known(type: "runtime-reported", evidence: "connection refused")))
    }

    // MARK: - HumorDecision (§12)

    private func understanding(humorSuitability: Double, socialRegisterRecommendation: SocialRegister? = nil, dialogueAct: DialogueAct = .statement) -> ConversationUnderstanding {
        ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: socialRegisterRecommendation,
            humorAppropriateness: humorSuitability > 0, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false,
            uncertainty: 0.5, dialogueAct: dialogueAct, humorSuitability: humorSuitability
        )
    }

    @Test func humorDecision_prohibitedForDisabledPurposeOrRegister() {
        #expect(HumorPolicy.decision(register: .casualFriendly, purpose: .permissionDenied, understanding: understanding(humorSuitability: 0.8)) == .prohibited)
        #expect(HumorPolicy.decision(register: .professional, purpose: .success, understanding: understanding(humorSuitability: 0.8)) == .prohibited)
    }

    @Test func humorDecision_unnecessaryWhenSuitabilityZero() {
        #expect(HumorPolicy.decision(register: .casualFriendly, purpose: .success, understanding: understanding(humorSuitability: 0)) == .unnecessary)
    }

    @Test func humorDecision_appropriateForCasualRecommendationOrPersonalUpdate() {
        #expect(HumorPolicy.decision(register: .casualFriendly, purpose: .success, understanding: understanding(humorSuitability: 0.6, socialRegisterRecommendation: .casualFriendly)) == .appropriate(strength: 0.6))
        #expect(HumorPolicy.decision(register: .friendlyNeutral, purpose: .success, understanding: understanding(humorSuitability: 0.6, dialogueAct: .personalUpdate)) == .appropriate(strength: 0.6))
    }

    @Test func humorDecision_optionalOtherwise() {
        #expect(HumorPolicy.decision(register: .friendlyNeutral, purpose: .success, understanding: understanding(humorSuitability: 0.4)) == .optional(strength: 0.4))
    }

    // MARK: - Mandatory §28 regression tests, through the FULL ConversationalResponsePresenter

    @Test func mandatoryRegression_personalUpdate_neverProducesDone() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "bugfix-1")),
            transcript: "I finally fixed that bug.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.contains("Done"))
        #expect(!response.wasSuccess, "no action was requested, so this must not read as a confirmed success either")
    }

    @Test func mandatoryRegression_constraint_neverProducesDone() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "constraint-1")),
            transcript: "This is important. Don't change anything yet.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.contains("Done"))
        #expect(response.text == "Got it. I won't change anything.")
    }

    @Test func mandatoryRegression_genericExecutionFailed_neverInventsConnectivityCause() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "fail-1")))
        #expect(!response.text.localizedCaseInsensitiveContains("reach"))
        #expect(!response.text.localizedCaseInsensitiveContains("connect"))
        // P2-M5V8.1-P §11 — more directly honest wording; the property
        // under test (no connectivity cause invented) is unchanged.
        #expect(response.text == "I couldn't complete that, and I don't know why yet.")
    }

    @Test func mandatoryRegression_genericExecutionFailed_neverOffersRetry() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "fail-2")))
        #expect(!response.text.localizedCaseInsensitiveContains("try again"))
    }

    @Test func mandatoryRegression_capabilityUnavailable_mayOfferRetry() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(for: .success(outcomeResult(outcome: "CAPABILITY_UNAVAILABLE", text: "I can't perform that action right now.", taskID: "unavail-1")))
        #expect(response.text.localizedCaseInsensitiveContains("try again"), "a genuinely retryable, structurally-transient family may naturally offer a retry")
    }

    @Test func mandatoryRegression_humorAllowedDoesNotRequireHumorToBeUsed() {
        // A normal, non-humor-relevant success must not gain a joke just
        // because humor happens to be allowed in this register/context.
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "normal-1")),
            transcript: "bro create a note called groceries", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(DeterministicResponsePresenter.createNoteSuccessVariants(title: "groceries").contains(response.text), "no joke should be injected into an ordinary note-creation confirmation")
    }

    @Test func mandatoryRegression_professionalContext_disablesHumor() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "prof-1")),
            transcript: "Please draft an email to my professor — can you launch a spaceship for the demo?", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(DeterministicResponseRealizer.unsupportedIntentVariants.contains(response.text), "professional register must fall back to the plain, non-humorous unsupported-intent wording")
    }

    @Test func mandatoryRegression_correctionTranscript_classifiesAsCorrection() {
        let understanding = reasoner.understand(transcript: "No, call it weekend groceries.", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
    }

    @Test func mandatoryRegression_bareWhy_classifiesAsExplanationRequest() {
        let understanding = reasoner.understand(transcript: "Why?", recentTurns: [], context: context(family: .policyDenied, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .explanationRequest)
    }

    // MARK: - §29 LLM safety / failure-case coverage

    @Test func llmReasoner_emptyOrMalformedInput_safelyReturnsMinimal_neverCrashes() {
        let llm = LLMConversationReasoner()
        let understanding = llm.understand(transcript: "", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding == .minimal)
    }

    @Test func presenter_hallucinatedConnectivityCause_rejectedByValidation() {
        struct HallucinatingRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
                "I couldn't reach the database server that time."
            }
        }
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "hallucinate-1")))
        #expect(!response.text.localizedCaseInsensitiveContains("reach"), "an invented, ungrounded failure cause must be rejected and fall back to the truthful generic phrasing")
        // P2-M5V8.1-P.2-FINAL-CLOSURE §3/§4 — the safety net now
        // consults the rich, failureReason-aware realizer instead of the
        // flat base presenter (a deliberate fallback-truth-parity fix,
        // not a regression): a genuinely `.unknown` cause now says so
        // explicitly rather than the older, less honest generic phrase.
        // The property under test — the hallucinated cause never survives
        // — is unchanged and still verified by the assertion above.
        #expect(response.text == "I couldn't complete that, and I don't know why yet.")
    }

    @Test func presenter_hallucinatedRetryOffer_rejectedByValidation() {
        struct HallucinatingRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
                "That didn't go through. Want me to try again?"
            }
        }
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "hallucinate-2")))
        #expect(!response.text.localizedCaseInsensitiveContains("try again"), "retry may not be offered without Retryability.allowed")
    }

    @Test func presenter_contradictsExplicitConstraint_rejectedAndFallsToSafeAcknowledgment() {
        // A realizer that ignores the user's explicit "don't change
        // anything" constraint and claims it made a change must never be
        // spoken — the presenter's own safety net (never the ignorant
        // realizer's text) must win for a `.notRequested` action state.
        struct DisobedientRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
                "Done. I've changed it."
            }
        }
        let presenter = ConversationalResponsePresenter(naturalRealizer: DisobedientRealizer())
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "disobedient-1")),
            transcript: "Don't change anything.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.contains("Done"))
        #expect(!response.text.localizedCaseInsensitiveContains("i've changed"))
        #expect(response.text == "Got it. I won't change anything.")
    }

    // MARK: - Multi-turn scenarios (§25), driven directly through the presenter

    @Test func scenario_dontAct_neverExecutesOrClaimsCompletion() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "scenario2")),
            transcript: "This is important. Don't change anything yet.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(response.text == "Got it. I won't change anything.")
        #expect(!response.wasSuccess)
    }

    @Test func scenario_humorThenSerious_humorStopsImmediately() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        let humorTurn = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "humor-1")),
            transcript: "Can you launch a spaceship?", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(DeterministicResponseRealizer.unsupportedIntentVariants.contains(humorTurn.text) || ["Not quite in my skill set yet.", "Not yet. Give me a little more time.", "I can't do that one yet."].contains(humorTurn.text))

        let seriousTurn = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "humor-2")),
            transcript: "I'm serious, this is important.", acoustics: .unavailable, explicitUserStatements: []
        )
        // explicitUrgency must suppress humor immediately (no lingering
        // playful tone from the previous turn).
        #expect(DeterministicResponseRealizer.unsupportedIntentVariants.contains(seriousTurn.text), "urgency must disable the humor-eligible phrasing")
    }
}
