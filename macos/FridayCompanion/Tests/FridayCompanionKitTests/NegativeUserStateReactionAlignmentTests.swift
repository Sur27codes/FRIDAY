import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-S3.1 — dedicated coverage for the live failure class:
/// "Production is down now." → MODEL: "That's good to hear." was
/// ACCEPTED. Root cause: `userReportedStateContradictionGuard` (S2.2)
/// only ever scoped POSITIVE-STATE-ASSERTION phrases ("everything's
/// fine," "all clear") — a claim class distinct from a candidate
/// POSITIVELY EVALUATING the reported negative situation ("that's good
/// to hear," "great news"), which no guard covered. `userReportedStateReactionGuard`
/// (new, `ResponsePresenting.swift`) closes that gap as a SEPARATE,
/// additional guard — S2.2's own guard is untouched.
@Suite struct NegativeUserStateReactionAlignmentTests {
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

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
        return envelope.data(using: .utf8)!
    }

    private func alwaysSucceedingReasonerFake() -> FakeConversationModelRequesting {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"statement","interactionMode":"conversational","uncertainty":0.1}
        """))
        return fake
    }

    private let negative = UserReportedState(polarity: .negative, source: .userReported)

    // MARK: - negativeUserState_positiveReaction_rejected

    @Test func negativeUserState_positiveReaction_rejected() {
        let candidates = [
            "That's good to hear.", "Great to hear.", "Glad to hear it.", "That's great.",
            "Good news.", "Everything sounds good.",
        ]
        for candidate in candidates {
            #expect(!ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: negative), "\"\(candidate)\" must be rejected")
        }
    }

    // MARK: - negativeUserState_resolutionClaim_rejected

    @Test func negativeUserState_resolutionClaim_rejected() {
        let candidates = ["Nice, that's sorted.", "Looks like everything is back to normal.", "Good — that's working now."]
        for candidate in candidates {
            #expect(!ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: negative), "\"\(candidate)\" must be rejected")
        }
    }

    // MARK: - negativeUserState_negativeReaction_accepted / neutralAcknowledgement_accepted

    @Test func negativeUserState_negativeReaction_accepted() {
        let candidates = ["That's rough.", "That's not good.", "Got it.", "Want me to check what I can?", "I don't know what caused that yet."]
        for candidate in candidates {
            #expect(ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: negative), "\"\(candidate)\" must be accepted")
        }
    }

    @Test func negativeUserState_neutralAcknowledgement_accepted() {
        #expect(ResponseValidation.userReportedStateReactionGuard("Got it.", userReportedState: negative))
    }

    // MARK: - negativeUserState_disclosureAppreciation_accepted

    @Test func negativeUserState_disclosureAppreciation_accepted() {
        let candidates = ["Thanks for telling me.", "I'm glad you told me.", "Thank you for letting me know."]
        for candidate in candidates {
            #expect(ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: negative), "\"\(candidate)\" (disclosure appreciation) must be accepted")
        }
    }

    // MARK: - positiveUserState_positiveReaction_accepted / neutralContext_positiveReaction_notGloballyRejected

    @Test func positiveUserState_positiveReaction_accepted() {
        // No negative UserReportedState at all (a POSITIVE personal
        // update, e.g. "I finally fixed that bug.") — positive language
        // must remain completely unaffected by this guard.
        let candidates = ["Nice.", "That's great.", "Glad that's sorted."]
        for candidate in candidates {
            #expect(ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: nil), "\"\(candidate)\" must be accepted with no negative user-reported state")
        }
    }

    @Test func neutralContext_positiveReaction_notGloballyRejected() {
        #expect(ResponseValidation.userReportedStateReactionGuard("Good to hear.", userReportedState: nil))
        #expect(ResponseValidation.userReportedStateReactionGuard("Great news.", userReportedState: nil))
    }

    // MARK: - unicodeTypography_doesNotBypassReactionGuard

    @Test func unicodeTypography_doesNotBypassReactionGuard() {
        // Curly apostrophe (U+2019, a real model's default output),
        // upper case, and extra internal whitespace all still route
        // through the same S2.2 normalization layer this guard reuses.
        let candidates = [
            "That\u{2019}s good to hear.", "THAT'S GREAT.", "Glad   to   hear   it.", "That’s  sorted now.",
        ]
        for candidate in candidates {
            #expect(!ResponseValidation.userReportedStateReactionGuard(candidate, userReportedState: negative), "\"\(candidate)\" must still be rejected despite typographic variance")
        }
    }

    // MARK: - generalizedNegativeUserReportedStates

    @Test func generalizedNegativeUserReportedStates() {
        // §17 — unseen negative situational reports must still be
        // detected via the existing BOUNDED `UserReportedState` keyword-
        // root detection (no new lookup table), and a positive reaction
        // to any of them must still be rejected.
        let reasoner = DeterministicConversationReasoner()
        let unseenReports = [
            "The server is offline.", "The build is failing again.", "The deployment just broke.",
            "The app keeps crashing.", "The service went down.", "The database isn't responding.",
        ]
        for report in unseenReports {
            let understanding = reasoner.understand(transcript: report, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
            #expect(understanding.userReportedState?.polarity == .negative, "\"\(report)\" should be detected as a negative user-reported state")
            #expect(!ResponseValidation.userReportedStateReactionGuard("That's good to hear.", userReportedState: understanding.userReportedState), "\"\(report)\" → a positive reaction must be rejected")
            #expect(ResponseValidation.userReportedStateReactionGuard("Got it.", userReportedState: understanding.userReportedState), "\"\(report)\" → a neutral acknowledgement must remain accepted")
        }
    }

    // MARK: - semanticRejection_preservesS2_1SelectionTruth

    @Test func semanticRejection_preservesS2_1SelectionTruth_forPositiveReactionToNegativeState() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"That's good to hear.\"}"))
        let reasonerFake = alwaysSucceedingReasonerFake()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "s31-1")),
            transcript: "Production is down now.", acoustics: .unavailable, explicitUserStatements: []
        )

        let snapshot = recorder.snapshot()
        // Provider inference succeeded on both stages.
        #expect(snapshot.lastReasonerUsed == "model")
        #expect(snapshot.lastRealizerUsed == "model")
        // Schema-valid, but semantically rejected.
        #expect(snapshot.lastSchemaValid == true)
        #expect(snapshot.lastSemanticGroundingValid == false)
        #expect(snapshot.lastResponseAccepted == false)
        // §24 — the exact S2.1 selection-truth shape.
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
        // The rejected candidate text is NEVER what's actually spoken.
        #expect(response.text != "That's good to hear.")
        #expect(!response.text.localizedCaseInsensitiveContains("good to hear"))
    }

    // MARK: - commiseratePrompt_containsNegativeSituationGuidance

    @Test func commiseratePrompt_containsNegativeSituationGuidance() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: "{\"text\":\"Got it.\"}"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config)
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let understanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            dialogueAct: .statement, interactionMode: .conversational, actionExecutionState: .notRequested,
            userReportedState: negative, pragmaticResponseAct: .commiserate
        )
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let plan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: understanding, strategy: strategy, persona: .friday)
        _ = realizer.realize(context: ctx, understanding: understanding, plan: plan, recentTurns: [], avoiding: nil)

        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("no request body was captured")
            return
        }
        let lower = bodyString.lowercased()
        #expect(lower.contains("commiserate"))
        #expect(lower.contains("never praise") || lower.contains("never celebrate"))
    }
}
