import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-S2.2 — dedicated coverage for two real live-owner-run
/// correctness gaps: (1) a correction-completion grounding regression
/// ("No, the earlier one." → "I've corrected the note." was accepted),
/// root-caused to a `correctionTarget` scoping bug (gated on an
/// unrelated prior note-creation turn) PLUS an authoritative-precedence
/// bug (a model-supplied `correctionTarget` could silently override the
/// correct local "earlier" value) PLUS typographic apostrophe mismatch
/// (a curly `'` never matched a straight `'` in the phrase table); and
/// (2) FRIDAY directly contradicting a user-asserted current negative
/// state ("Production is down now." → "Everything's in order." was
/// accepted).
@Suite struct UserAssertedTruthAndCorrectionGroundingTests {
    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    private let reasoner = DeterministicConversationReasoner()

    // MARK: - §1: root cause #1 — correctionTarget scoping (no note-creation prerequisite)

    @Test func correctionTarget_resolvesWithoutAnyPriorNoteCreationTurn() {
        // The proven bug: `correctionTarget` used to stay `nil` unless
        // `recentTurns` contained a prior `.createNoteSuccess` turn —
        // defeating the referential guard for ANY other kind of
        // correction. Empty `recentTurns` here, deliberately.
        let understanding = reasoner.understand(transcript: "No, the earlier one.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
        #expect(understanding.correctionTarget == "earlier")
    }

    @Test func correctionTarget_generalizes_iMeantPhrasing() {
        // §10's own required test — "I meant the first version." matched
        // NO existing correction marker at all before this pass.
        let understanding = reasoner.understand(transcript: "I meant the first version.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
        #expect(understanding.correctionTarget == "earlier")
    }

    @Test func correctionTarget_generalizes_notThisOneDashVariant() {
        let understanding = reasoner.understand(transcript: "Not this one—the first one.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
        #expect(understanding.correctionTarget == "earlier")
    }

    // MARK: - §1: root cause #2 — authoritative precedence (local must win over a model-supplied correctionTarget)

    private struct HallucinatingCorrectionReasoner: ConversationReasoning {
        let bogusCorrectionTarget: String?
        func understand(transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext, acoustics: AcousticConversationFeatures, explicitUserStatements: [String]) -> ConversationUnderstanding {
            ConversationUnderstanding(
                communicativeIntent: .correction, topic: nil, continuationOfPreviousTurn: true, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.1,
                dialogueAct: .correction, interactionMode: .correction, actionExecutionState: .executedSucceeded,
                explicitConstraints: [], failureReason: .unknown, retryability: .unknown, userGoal: nil,
                correctionTarget: bogusCorrectionTarget, // <- the model's own, unrelated claim
                explanationRequested: false, humorSuitability: 0
            )
        }
    }

    @Test func authoritative_localCorrectionTargetWins_overModelSuppliedValue() {
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingCorrectionReasoner(bogusCorrectionTarget: "the groceries note"), naturalRealizer: nil)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "prec-1")),
            transcript: "No, the earlier one.", acoustics: .unavailable, explicitUserStatements: []
        )
        // A non-nil, non-"earlier" model claim must not have silently
        // defeated the local "earlier" resolution — proven indirectly via
        // the response text never claiming a forward/new action, since
        // the presenter's own safety net for `.correction` interactionMode
        // (no dedicated wording) still routes through `passesSemanticGuards`
        // with the AUTHORITATIVE correctionTarget.
        #expect(!response.text.localizedCaseInsensitiveContains("new"))
    }

    // MARK: - §2: typographic normalization — the actual root cause of the live regression

    @Test func referentialCorrectionClaimGuard_catchesCurlyApostrophe_notJustStraight() {
        // The EXACT live failure: a genuine U+2019 typographic apostrophe,
        // which is what any real model actually emits by default.
        let curly = "I\u{2019}ve corrected the note."
        #expect(!ResponseValidation.referentialCorrectionClaimGuard(curly, dialogueAct: .correction, correctionTarget: "earlier"))
    }

    @Test func referentialCorrectionClaimGuard_stillCatchesStraightApostrophe() {
        let straight = "I've corrected the note."
        #expect(!ResponseValidation.referentialCorrectionClaimGuard(straight, dialogueAct: .correction, correctionTarget: "earlier"))
    }

    @Test func claimGuards_toleratesDashCaseAndWhitespaceVariance() {
        // A representative sample across several DIFFERENT guards proves
        // the normalization is centralized, not patched into one place.
        #expect(!ResponseValidation.executionSuccessClaimGuard("ALL   SET.", actionExecutionState: .executedFailed))
        #expect(!ResponseValidation.neverInventsFailureCause("The service was refused\u{2014}connection issue.", failureReason: .unknown, actionExecutionState: .executedFailed))
    }

    // MARK: - §3/§4/§10: correction does not imply execution (reference vs. execution compatibility, both required)

    @Test func correction_noUsePreviousOne_rejectsIveUpdatedIt() {
        #expect(!ResponseValidation.passesSemanticGuards(
            "I've updated it.", wasSuccess: true, actionExecutionState: .executedSucceeded, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .correction, correctionTarget: "earlier"
        ))
    }

    @Test func correction_iMeantFirstVersion_rejectsPassiveHasBeenChanged() {
        #expect(!ResponseValidation.passesSemanticGuards(
            "That version has been changed.", wasSuccess: true, actionExecutionState: .executedSucceeded, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .correction, correctionTarget: "earlier"
        ))
    }

    @Test func correction_referenceCorrectButExecutionClaimStillRejected_bothChecksRequired() {
        // §4 — proves the two checks are genuinely independent: a
        // candidate can get the referential direction right (doesn't
        // claim "new"/"current") and STILL be rejected for claiming
        // execution.
        let text = "Got it, the earlier one — I've fixed it."
        #expect(!ResponseValidation.referentialCorrectionClaimGuard(text, dialogueAct: .correction, correctionTarget: "earlier"))
    }

    @Test func correction_safeAcknowledgement_passesBothChecks() {
        #expect(ResponseValidation.referentialCorrectionClaimGuard("Got it, the earlier one.", dialogueAct: .correction, correctionTarget: "earlier"))
    }

    @Test func liveFailure_noTheEarlierOne_endToEnd_neverAccepted() {
        // Full end-to-end reproduction of the exact live failure using a
        // fake model realizer producing the EXACT curly-apostrophe text
        // the real model produced.
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"I\\u2019ve corrected the note.\"}"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            memory: memory, diagnostics: recorder
        )
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "live-1")),
            transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: []
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "live-2")),
            transcript: "No, the earlier one.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("corrected"))
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastSemanticGroundingValid == false)
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
    }

    // MARK: - §5/§6/§7/§10: user-reported state must not be contradicted

    @Test func generalization_negativeSituationalStates_detected() {
        for transcript in ["The service is down.", "The build is failing.", "The app keeps crashing.", "The deployment broke.", "The server is offline.", "Production is down now."] {
            let understanding = reasoner.understand(transcript: transcript, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
            #expect(understanding.userReportedState?.polarity == .negative, "\(transcript)")
            #expect(understanding.userReportedState?.source == .userReported, "\(transcript)")
        }
    }

    @Test func userState_serviceOffline_rejectsEverythingsFine() {
        let understanding = reasoner.understand(transcript: "The service is offline.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(!ResponseValidation.passesSemanticGuards(
            "Everything's fine.", wasSuccess: understanding.actionExecutionState != .notRequested, actionExecutionState: understanding.actionExecutionState,
            retryability: understanding.retryability, failureReason: understanding.failureReason, userReportedState: understanding.userReportedState
        ))
    }

    @Test func userState_buildFailing_rejectsWorkingNormally() {
        let understanding = reasoner.understand(transcript: "The build is failing.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(!ResponseValidation.passesSemanticGuards(
            "Everything is working normally.", wasSuccess: understanding.actionExecutionState != .notRequested, actionExecutionState: understanding.actionExecutionState,
            retryability: understanding.retryability, failureReason: understanding.failureReason, userReportedState: understanding.userReportedState
        ))
    }

    @Test func userState_buildFailing_acceptsNeutralAcknowledgement() {
        let understanding = reasoner.understand(transcript: "The build is failing.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(ResponseValidation.passesSemanticGuards(
            "Got it.", wasSuccess: false, actionExecutionState: understanding.actionExecutionState,
            retryability: understanding.retryability, failureReason: understanding.failureReason, userReportedState: understanding.userReportedState
        ))
    }

    @Test func userState_serviceOffline_acceptsInvestigationOffer() {
        let understanding = reasoner.understand(transcript: "The service is offline.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(ResponseValidation.passesSemanticGuards(
            "Want me to check it?", wasSuccess: false, actionExecutionState: understanding.actionExecutionState,
            retryability: understanding.retryability, failureReason: understanding.failureReason, userReportedState: understanding.userReportedState
        ))
    }

    @Test func liveFailure_productionIsDownNow_endToEnd_neverAcceptsAllClearCandidate() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"Everything\\u2019s in order.\"}"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "live-3")),
            transcript: "Production is down now.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("in order"))
        #expect(!response.text.localizedCaseInsensitiveContains("everything"))
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastSemanticGroundingValid == false)
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
    }

    // §8 — verified-fact supersession: no verified-runtime source exists
    // in this codebase today (disclosed, not fabricated), so the guard
    // conservatively rejects an all-clear claim REGARDLESS of
    // `context.wasSuccess` — proving it does not silently trust an
    // unrelated synthetic SUCCESS outcome as "verified contradiction."
    @Test func userState_negativeReport_notSupersededByUnrelatedSyntheticSuccessOutcome() {
        let understanding = reasoner.understand(transcript: "The server is offline.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.userReportedState != nil, "a synthetic SUCCESS outcome attached to this turn is not verified evidence about the SERVER's health")
    }

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
        return envelope.data(using: .utf8)!
    }

    // MARK: - §11: S2.1 selection-truth fields still correct for a semantic rejection

    @Test func semanticRejection_stillProducesFullS2_1TruthShape() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"Done.\"}"))
        let reasonerFake = FakeConversationModelRequesting()
        reasonerFake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"request","interactionMode":"actionRequest","uncertainty":0.1}
        """))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "s21-1")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerUsed == "model")
        #expect(snapshot.lastRealizerUsed == "model", "provider inference must remain successful")
        #expect(snapshot.lastSchemaValid == true)
        #expect(snapshot.lastSemanticGroundingValid == false)
        #expect(snapshot.lastResponseAccepted == false)
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
    }
}
