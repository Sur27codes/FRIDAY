import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-PROD-BOOTSTRAP-R2.6 §10 / P2-M5V8.1-R — real, code-verified forensic
/// proof (network-free, via `FakeConversationModelRequesting`, never a real
/// credential/API spend) of exactly what happens to an informational-
/// imperative voice turn ("explain X in N sentences"-shaped), both while
/// `friday-daemon` is unreachable (R2.6's original investigation) and — the
/// actual real production scenario — while it is healthy but reports
/// `UNSUPPORTED_INTENT` for a non-actionable question.
///
/// **History, for anyone reading `git blame`:** this file originally
/// documented a real classification BUG (R2.6): "explain machine learning
/// in five sentences" fell through the whole `classifyDialogueAct` priority
/// chain to the generic `.statement` default, which (via `interactionMode`'s
/// `.statement` case, no action-verb evidence) became `.conversational` —
/// and `.conversational` unconditionally resolves to `actionExecutionState:
/// .notRequested` WITHOUT ever consulting `capabilityRequirement`, bypassing
/// the whole fail-closed truth boundary for BOTH general-knowledge AND
/// private/current-state phrasings shaped this way. P2-M5V8.1-R fixed the
/// root cause in `classifyDialogueAct` (a new, last-priority check reusing
/// the existing, already-tested `isInformationalContentRequest` signal) —
/// every assertion below reflects the CORRECTED, current, real behavior.
@Suite struct BackendDownConversationForensicsTests {
    private let unifiedConfig = ConversationModelConfig(
        endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall
    )

    private struct UnifiedReasoningWire: Encodable { let dialogueAct: String; let interactionMode: String }
    private struct UnifiedResponseWire: Encodable { let text: String }
    private struct UnifiedContentWire: Encodable { let reasoning: UnifiedReasoningWire; let response: UnifiedResponseWire }

    private func unifiedContent(dialogueAct: String, interactionMode: String, text: String) -> String {
        let obj = UnifiedContentWire(reasoning: .init(dialogueAct: dialogueAct, interactionMode: interactionMode), response: .init(text: text))
        return String(data: try! JSONEncoder().encode(obj), encoding: .utf8)!
    }

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
        return envelope.data(using: .utf8)!
    }

    /// friday-daemon itself unreachable — the R2.6 scenario.
    private var transportFailureContext: ConversationContext {
        ConversationContext(
            interactionID: "transport-failure", taskID: "", outcomeCode: "(transport failure)",
            responseFamily: .transportFailure, wasSuccess: false, isVerifiedData: false,
            needsClarification: false, isRetryable: true, isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    /// friday-daemon healthy, reports no executable capability existed —
    /// the ACTUAL real-production shape for a pure informational question
    /// (confirmed via `VoiceAuditionTool production-conversation-forensics`
    /// against the owner's real daemon: `daemon outcome code:
    /// UNSUPPORTED_INTENT`). This is the scenario PART 11/12's real
    /// acceptance tests exercise.
    private var unsupportedIntentContext: ConversationContext {
        ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "UNSUPPORTED_INTENT", responseFamily: .unsupportedIntent,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: false,
            isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    // MARK: - §10.1: the daemon-transport-failure path itself is real and independent of classification

    @Test func realTransportFailure_toAnUnreachableDaemonSocket_producesAGenuineFailureOutcome() throws {
        // The exact real mechanism `WakeCoordinator.beginProcessing` hits
        // when `friday-daemon` is down (no daemon, no fake — a real
        // `RuntimeClient` against a socket path nothing is listening on).
        let deadSocket = "/tmp/friday-r26-forensics-definitely-unreachable-\(UUID().uuidString).sock"
        let client = RuntimeClient(socketPath: deadSocket)
        do {
            _ = try client.submitText("explain machine learning in five sentences", requestID: "r26-forensic", correlationID: "r26-forensic")
            Issue.record("expected a genuine transport failure against an unreachable socket")
        } catch {
            // Real, not simulated — confirms "RuntimeClient attempted: YES, runtime error: YES" with real evidence, not a guess.
        }
    }

    // MARK: - §10.2/P2-M5V8.1-R §1: the FIXED classification, both real daemon-health shapes

    @Test func explainMlPhrasing_realProductionShape_daemonHealthy_classifiesAsInformationRequest_notRequested() {
        // The REAL production scenario: friday-daemon reachable, reports
        // UNSUPPORTED_INTENT (no executable capability existed — because
        // none was needed, per P2-M5V8.1-Q's own corrected rule). Fixed by
        // P2-M5V8.1-R's new `classifyDialogueAct` check.
        let u = DeterministicConversationReasoner().understand(
            transcript: "explain machine learning in five sentences", recentTurns: [], context: unsupportedIntentContext,
            acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(u.dialogueAct == .explanationRequest, "was .statement before P2-M5V8.1-R")
        #expect(u.interactionMode == .informationRequest, "was .conversational before P2-M5V8.1-R")
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested, "no capability was ever needed — safe to answer from general knowledge")
        #expect(u.responseScope == .briefExplanation, "now reached directly via the `.explanationRequest` dialogueAct case, not the old capabilityRequirement fallback")
    }

    @Test func explainMlPhrasing_daemonUnreachable_classifiesAsInformationRequest_butFailsClosed() {
        // A genuinely DIFFERENT, MORE conservative real scenario: the
        // daemon itself could not be reached at all, so whether a
        // capability existed is genuinely UNKNOWN — `actionExecutionState`
        // correctly resolves to `.executedFailed` (fail-closed), NOT
        // `.notRequested`, via `context.responseFamily == .transportFailure`'s
        // own existing (unchanged) mapping. This is a genuine SAFETY
        // IMPROVEMENT this fix brings for free: before P2-M5V8.1-R, this
        // exact scenario ALSO incorrectly resolved to `.notRequested`
        // (via the old `.conversational` bypass), which is less
        // conservative than intended for a truly unknown-capability
        // outage.
        let u = DeterministicConversationReasoner().understand(
            transcript: "explain machine learning in five sentences", recentTurns: [], context: transportFailureContext,
            acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(u.dialogueAct == .explanationRequest)
        #expect(u.interactionMode == .informationRequest)
        #expect(u.actionExecutionState == .executedFailed, "was .notRequested before P2-M5V8.1-R — this outage scenario is now MORE conservative, not less")
        #expect(u.responseScope == .briefExplanation)
    }

    // MARK: - §10.3: with a reachable conversation provider and a healthy daemon, this phrasing gets a real answer

    @Test func daemonHealthy_reachableConversationProvider_producesTheRealAnswer_exactlyOneCall() {
        let fake = FakeConversationModelRequesting()
        let realAnswer = "Machine learning is a field of AI where systems learn patterns from data instead of following fixed rules."
        fake.behavior = .success(chatCompletionData(content: unifiedContent(
            dialogueAct: "explanationRequest", interactionMode: "informationRequest", text: realAnswer
        )))
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: unifiedConfig, client: fake, diagnostics: recorder)

        let outcome = CommandRuntimeOutcome.success(RuntimeTextResult(
            protocolVersion: 1, requestID: "t", correlationID: "t", taskID: "t", outcome: "UNSUPPORTED_INTENT", text: "unsupported"
        ))
        let response = presenter.response(
            for: outcome, transcript: "explain machine learning in five sentences",
            acoustics: .unavailable, explicitUserStatements: []
        )

        #expect(fake.sendCallCount == 1, "the one-call path makes exactly one provider request per turn")
        #expect(recorder.snapshot().lastProviderCallCount == 1)
        #expect(response.text == realAnswer, "a genuine general-knowledge question, correctly classified, must reach speech verbatim")
        #expect(response.wasSuccess == false, "no action was ever requested — never reported as a completed action")
    }

    // MARK: - §10.4: a genuinely conversational remark is unaffected by any of this (by design, not a bug)

    @Test func genuineConversationalRemark_stillGetsAnOrdinaryShortReply_unaffectedByThisFix() {
        // "thanks" matches none of `informationalLeadPhrases` — the new
        // classifier check never fires, so ordinary casual remarks are
        // completely unaffected by P2-M5V8.1-R.
        let understanding = DeterministicConversationReasoner().understand(
            transcript: "thanks", recentTurns: [], context: transportFailureContext,
            acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(understanding.dialogueAct == .acknowledgement)
        #expect(understanding.interactionMode == .conversational)
        #expect(understanding.actionExecutionState == .notRequested, "a casual remark never required the (unavailable) backend in the first place")
    }

    // MARK: - §10.5: total outage (daemon down AND provider unreachable) now gets the HONEST grounded-failure text, not "Okay."

    @Test func totalOutage_daemonAndProviderBothUnreachable_nowGetsGroundedFailureText_notAGenericAcknowledgment() {
        // A real, additional improvement this fix brings: previously
        // (`.statement`/`.conversational`, `actionExecutionState:
        // .notRequested`) this exact scenario fell back to the generic
        // conversational acknowledgment pool ("Okay."/"Alright."/"Got
        // it."), even though a real failure had genuinely occurred.
        // Correctly classified as `.executedFailed` now, this reaches the
        // GROUNDED failure text instead — an honest report that FRIDAY
        // could not be reached, not a content-free "Okay."
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // the EXTERNAL provider call itself also fails
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: unifiedConfig, client: fake, diagnostics: recorder)

        let response = presenter.response(
            for: .failure("transport(\"connection refused\")"), transcript: "explain machine learning in five sentences",
            acoustics: .unavailable, explicitUserStatements: []
        )

        #expect(fake.sendCallCount == 1)
        #expect(recorder.snapshot().lastFinalResponseSource == .deterministicFallback)
        #expect(!["Got it.", "Alright.", "Okay."].contains(response.text),
                "was the generic conversational pool before P2-M5V8.1-R — a genuine outage must no longer be reported as a content-free acknowledgment")
        #expect(!response.wasSuccess)
    }

    @Test func totalOutage_noConversationProviderConfiguredAtAll_alsoGetsGroundedFailureText() {
        let presenter = ConversationalResponsePresenter() // no unified provider wired at all — e.g. credential never configured
        let response = presenter.response(for: .failure("connection refused"), transcript: "explain machine learning in five sentences")
        #expect(!response.wasSuccess)
        #expect(!["Got it.", "Alright.", "Okay."].contains(response.text))
    }
}
