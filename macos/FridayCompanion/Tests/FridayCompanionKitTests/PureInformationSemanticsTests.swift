import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-Q — the authorized, narrow correction: a daemon
/// `UNSUPPORTED_INTENT` verdict must not, by itself, mean "FRIDAY cannot
/// answer this user turn." Adds `CapabilityRequirement` (local,
/// deterministic, never asked of the model) and threads it into
/// `actionExecutionState`/`responseScope` so a pure informational/
/// no-capability-needed turn gets `.notRequested` (never `.unsupported`)
/// and a substantive `.briefExplanation` scope (never `.conversationalShort`),
/// while every capability/private/current-state/unsupported-action path
/// is completely unchanged.
///
/// §17 — every transcript below is a phrasing not used anywhere else in
/// this codebase's tests or in the mission text that authorized this pass.
@Suite struct PureInformationSemanticsTests {
    private let reasoner = DeterministicConversationReasoner()

    /// Mirrors the REAL daemon verdict for a turn no capability matched
    /// ("UNSUPPORTED_INTENT" -> `.unsupportedIntent`, `wasSuccess: false`)
    /// — exactly what the R2.4 forensic run observed for both proven
    /// real-world failures.
    private func unsupportedIntentContext(taskID: String = "t") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "UNSUPPORTED_INTENT", responseFamily: .unsupportedIntent,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    /// A genuine successful capability outcome — the untouched, existing path.
    private func successContext(taskID: String = "t") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "SUCCESS", responseFamily: .genericSuccess,
            wasSuccess: true, isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private func understand(_ transcript: String, context: ConversationContext) -> ConversationUnderstanding {
        reasoner.understand(transcript: transcript, recentTurns: [], context: context, acoustics: .unavailable, explicitUserStatements: [])
    }

    // MARK: - §1: existing .notRequested is sufficient (no new ActionExecutionState case)

    @Test func actionExecutionState_hasNoNewCaseIntroduced_notRequestedAlreadyCovers_noCapabilityNeeded() {
        // Structural: this is a compile-time fact more than a runtime
        // assertion — `ActionExecutionState` still has exactly its
        // original 7 cases (see DialogueAct.swift). Documented here as a
        // live check on the SAME field the mission requires: the
        // no-capability-needed case below resolves to `.notRequested`,
        // never a hypothetical `.notApplicable`.
        let u = understand("Why does the sky look red at sunset?", context: unsupportedIntentContext())
        #expect(u.actionExecutionState == .notRequested)
    }

    // MARK: - §11 PURE GENERAL KNOWLEDGE

    @Test func sunset_isPureGeneralKnowledge() {
        let u = understand("Why does the sky look red at sunset?", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation)
    }

    @Test func gradientDescent_isPureGeneralKnowledge() {
        let u = understand("Explain gradient descent in simple terms.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation)
    }

    @Test func http503_isPureGeneralKnowledge() {
        let u = understand("What does HTTP 503 mean?", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation)
    }

    @Test func compareTcpUdp_isPureGeneralKnowledge() {
        let u = understand("Compare TCP and UDP.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation)
    }

    @Test func studyTips_isPureGeneralKnowledge_withSubstantiveScope() {
        let u = understand("Give me three practical ways to stay focused while studying.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation, "must NOT be conversationalShort — the exact real proven failure")
    }

    @Test func quantumComputingInDetail_isLongFormRequested() {
        let u = understand("Explain quantum computing in detail.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.responseScope == .longFormRequested)
    }

    // MARK: - CASUAL CONVERSATION

    @Test func howAreYou_isConversationalShort() {
        // "How are you?" happens to match the LOCAL classifier's own
        // pre-existing "how" question-marker (dialogueAct=.question,
        // unrelated to this pass) — its `actionExecutionState` legitimately
        // follows the real runtime outcome (existing, unchanged behavior);
        // what THIS pass guarantees is that a casual turn never gets
        // pulled into a substantive `.briefExplanation` scope merely
        // because it's question-shaped.
        let u = understand("How are you?", context: successContext())
        #expect(u.responseScope == .conversationalShort)
    }

    @Test func thatsInteresting_isConversationalShort() {
        let u = understand("That's interesting.", context: successContext())
        #expect(u.responseScope == .conversationalShort)
    }

    // MARK: - SUPPORTED CAPABILITY (existing path, must be unaffected)

    @Test func systemStatus_requiresCapability() {
        let u = understand("What's the system status?", context: successContext())
        #expect(u.capabilityRequirement == .required)
        #expect(u.actionExecutionState == .executedSucceeded, "a genuinely successful capability outcome is completely unaffected")
    }

    @Test func openCalculator_requiresCapability() {
        let u = understand("Open the calculator.", context: successContext())
        #expect(u.capabilityRequirement == .required)
    }

    // MARK: - UNSUPPORTED ACTION (capability genuinely required, genuinely absent — must stay .unsupported)

    @Test func sendFax_requiredAndUnsupported_neverClaimsSuccess() {
        let u = understand("Send a fax to John.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .required)
        #expect(u.actionExecutionState == .unsupported, "a genuinely unsupported ACTION must stay unsupported — not silently become notRequested")
    }

    @Test func deleteFilesUnsupportedRemote_requiredAndUnsupported() {
        let u = understand("Delete every file in an unsupported remote service.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .required)
        #expect(u.actionExecutionState == .unsupported)
    }

    // MARK: - PRIVATE / CURRENT-STATE INFORMATION (must never be answered from general knowledge)

    @Test func latestEmail_requiresCapability_neverGeneralKnowledge() {
        let u = understand("What's my latest email?", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .required)
        #expect(u.actionExecutionState == .unsupported, "private data with no matching capability must stay a truthful unsupported state, never a free-knowledge answer")
    }

    @Test func batteryPercentage_requiresCapability() {
        let u = understand("What's my battery percentage?", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .required)
    }

    @Test func todaysMeetings_requiresCapability() {
        let u = understand("What meetings do I have today?", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .required)
    }

    // MARK: - AMBIGUOUS (fails conservative — never silently general knowledge)

    @Test func checkPython_isAmbiguous_neverSilentlyGeneralKnowledge() {
        let u = understand("Check Python.", context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == .unknown)
        #expect(u.actionExecutionState != .notRequested, "unknown must fail closed — never silently treated as no-capability-needed")
    }

    // MARK: - §12 PROVIDER REQUEST CONTENT — authoritativeFacts truth

    private func unifiedRequestJSON(for transcript: String, context: ConversationContext, fake: FakeConversationModelRequesting) -> [String: Any] {
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.invalid/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let localUnderstanding = understand(transcript, context: context)
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: context, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: transcript, recentTurns: [], context: context, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return [:]
        }
        return json
    }

    private func userPayload(from json: [String: Any]) -> [String: Any] {
        guard let messages = json["messages"] as? [[String: Any]], let user = messages.first(where: { $0["role"] as? String == "user" }),
              let content = user["content"] as? String, let payloadData = content.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return [:] }
        return payload
    }

    @Test func generalKnowledgeRequest_authoritativeFacts_neverFalselyImplyUnsupportedOrFailed() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // only the OUTBOUND request matters
        let json = unifiedRequestJSON(for: "Why does the sky look red at sunset?", context: unsupportedIntentContext(), fake: fake)
        let facts = userPayload(from: json)["authoritativeFacts"] as? [String: Any]
        #expect(facts?["actionExecutionState"] as? String == "notRequested")
        #expect(facts?["actionExecutionState"] as? String != "unsupported")
        #expect(facts?["actionExecutionState"] as? String != "executedFailed")
    }

    @Test func unsupportedActionRequest_authoritativeFacts_stillTruthfullyUnsupported() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let json = unifiedRequestJSON(for: "Send a fax to John.", context: unsupportedIntentContext(), fake: fake)
        let facts = userPayload(from: json)["authoritativeFacts"] as? [String: Any]
        #expect(facts?["actionExecutionState"] as? String == "unsupported")
    }

    // MARK: - §13 one-call contract preserved

    @Test func generalKnowledgeTurn_oneCallOnly() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(#"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#.data(using: .utf8)!)
        _ = unifiedRequestJSON(for: "Explain photosynthesis briefly.", context: unsupportedIntentContext(), fake: fake)
        #expect(fake.sendCallCount == 1)
    }

    // MARK: - §17 PARAPHRASE GENERALIZATION — 20 unseen phrasings, no fixture strings reused

    private struct ParaphraseCase {
        let transcript: String
        let expectedCapability: CapabilityRequirement
    }

    private static let paraphraseMatrix: [ParaphraseCase] = [
        // science explanation
        ParaphraseCase(transcript: "How does photosynthesis actually work?", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "What causes a rainbow to appear after rain?", expectedCapability: .notRequired),
        // programming concept
        ParaphraseCase(transcript: "What is a race condition in concurrent programming?", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Describe how a hash table works.", expectedCapability: .notRequired),
        // study advice
        ParaphraseCase(transcript: "What are some good habits for retaining information while reading?", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Give me a couple of tips for beating procrastination.", expectedCapability: .notRequired),
        // definition
        ParaphraseCase(transcript: "What is a black hole?", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Define recursion for me.", expectedCapability: .notRequired),
        // comparison
        ParaphraseCase(transcript: "What's the difference between a virus and a worm?", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Compare an electric car to a gasoline car.", expectedCapability: .notRequired),
        // short list request
        ParaphraseCase(transcript: "List two benefits of regular exercise.", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Give me a few ideas for a weekend project.", expectedCapability: .notRequired),
        // long explanation request
        ParaphraseCase(transcript: "Walk me through how the internet routes a packet, in depth.", expectedCapability: .notRequired),
        ParaphraseCase(transcript: "Explain how vaccines work thoroughly.", expectedCapability: .notRequired),
        // current/private state request
        ParaphraseCase(transcript: "Is my laptop connected to the wifi right now?", expectedCapability: .required),
        ParaphraseCase(transcript: "What's in my calendar for tomorrow?", expectedCapability: .required),
        ParaphraseCase(transcript: "How much storage do I have left?", expectedCapability: .required),
        // explicit action request
        ParaphraseCase(transcript: "Turn off the wifi.", expectedCapability: .required),
        ParaphraseCase(transcript: "Schedule a reminder for tomorrow morning.", expectedCapability: .required),
        // unsupported action request
        ParaphraseCase(transcript: "Print this page on the office printer.", expectedCapability: .required),
    ]

    @Test(arguments: paraphraseMatrix) private func paraphraseGeneralizes(_ testCase: ParaphraseCase) {
        let u = understand(testCase.transcript, context: unsupportedIntentContext())
        #expect(u.capabilityRequirement == testCase.expectedCapability, "\"\(testCase.transcript)\" expected \(testCase.expectedCapability), got \(u.capabilityRequirement)")
    }
}
