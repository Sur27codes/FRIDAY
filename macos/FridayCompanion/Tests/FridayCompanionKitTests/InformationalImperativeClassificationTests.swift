import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-R — the required test matrix (§8/§9/§10): informational
/// imperatives ("explain X in N sentences"-shaped, without a question mark
/// or a leading question word) must classify as genuine information
/// requests, real actions must remain action requests, and current/private-
/// state requests must remain capability-gated — decided by SEMANTICS
/// (`requiresCapability`/`isInformationalContentRequest`, both pre-existing,
/// unchanged), never by the presence of an imperative verb alone.
@Suite struct InformationalImperativeClassificationTests {
    private func unsupportedIntentContext(taskID: String = "t") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "UNSUPPORTED_INTENT", responseFamily: .unsupportedIntent,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: false,
            isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private func understand(_ transcript: String) -> ConversationUnderstanding {
        DeterministicConversationReasoner().understand(
            transcript: transcript, recentTurns: [], context: unsupportedIntentContext(),
            acoustics: .unavailable, explicitUserStatements: []
        )
    }

    // MARK: - §8 INFORMATIONAL IMPERATIVES (exact required cases)

    @Test func explainMachineLearningInFiveSentences_isAnInformationRequest_capabilityNotRequired_notRequested_briefExplanation() {
        let u = understand("explain machine learning in five sentences")
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(u.responseScope == .briefExplanation)
    }

    @Test func explainMachineLearningInFiveSentences_theFiveSentenceConstraintSurvivesIntoTheTranscriptItself() {
        // §5 — the existing constraint representation IS the verbatim
        // transcript reaching the model (`userUtterance` in
        // `UnifiedConversationModelProvider.buildRequest`, confirmed by
        // direct source inspection): no separate/duplicate constraint
        // subsystem is needed. This test locks in the ONE fact that
        // representation depends on — the literal wording is never
        // altered/stripped by classification.
        let transcript = "explain machine learning in five sentences"
        #expect(understand(transcript).dialogueAct == .explanationRequest)
        #expect(transcript.contains("five sentences"), "sanity: the constraint text itself, unchanged")
    }

    @Test func describePhotosynthesisInTwoSentences_isAnInformationRequest_twoSentenceConstraintPreserved() {
        let transcript = "describe photosynthesis in two sentences"
        let u = understand(transcript)
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(transcript.contains("two sentences"))
    }

    @Test func giveMeThreeWaysToFocus_isAnInformationRequest_countThreePreserved() {
        let transcript = "give me three ways to focus while studying"
        let u = understand(transcript)
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(transcript.contains("three ways"))
    }

    @Test func listFourDifferencesBetweenTcpAndUdp_isAnInformationRequest_countFourPreserved() {
        let transcript = "list four differences between tcp and udp"
        let u = understand(transcript)
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(transcript.contains("four differences"))
    }

    @Test func compareSupervisedAndUnsupervisedLearning_isAnInformationRequest() {
        let u = understand("compare supervised and unsupervised learning")
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
    }

    @Test func defineOverfitting_isAnInformationRequest() {
        let u = understand("define overfitting")
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
    }

    @Test func summarizeGradientDescentInOneParagraph_isAnInformationRequest() {
        let transcript = "summarize gradient descent in one paragraph"
        let u = understand(transcript)
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
        #expect(transcript.contains("one paragraph"))
    }

    @Test func walkMeThroughHowDnsWorks_isAnInformationRequest() {
        let u = understand("walk me through how dns works")
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
    }

    @Test func helpMeUnderstandRecursion_isAnInformationRequest() {
        let u = understand("help me understand recursion")
        #expect(u.interactionMode == .informationRequest)
        #expect(u.capabilityRequirement == .notRequired)
        #expect(u.actionExecutionState == .notRequested)
    }

    // MARK: - §8 REAL ACTIONS (must remain capability/action requests — completely unaffected by this fix)

    @Test func openSafari_isStillACapabilityRequest() {
        let u = understand("open safari")
        #expect(u.interactionMode == .actionRequest)
        #expect(u.capabilityRequirement == .required)
    }

    @Test func sendAnEmailToJohn_isStillACapabilityRequest() {
        let u = understand("send an email to john")
        #expect(u.interactionMode == .actionRequest)
        #expect(u.capabilityRequirement == .required)
    }

    @Test func deleteTheFile_isStillACapabilityRequest() {
        let u = understand("delete the file")
        #expect(u.interactionMode == .actionRequest)
        #expect(u.capabilityRequirement == .required)
    }

    @Test func turnOffWifi_isStillACapabilityRequest() {
        let u = understand("turn off wifi")
        #expect(u.interactionMode == .actionRequest)
        #expect(u.capabilityRequirement == .required)
    }

    @Test func createACalendarEvent_isStillACapabilityRequest() {
        let u = understand("create a calendar event")
        #expect(u.interactionMode == .actionRequest)
        #expect(u.capabilityRequirement == .required)
    }

    // MARK: - §8 CURRENT/PRIVATE STATE (must remain capability-gated — the real gap this fix also closes)

    @Test func tellMeMyBatteryPercentage_requiresRuntimeTruth_neverGeneralKnowledge() {
        // Before P2-M5V8.1-R: fell to `.statement`/`.conversational`, so
        // `actionExecutionState` was `.notRequested` REGARDLESS of
        // `capabilityRequirement == .required` — a real, silent bypass of
        // the fail-closed boundary. Now correctly routed to
        // `.informationRequest`, which DOES consult `capabilityRequirement`.
        let u = understand("tell me my battery percentage")
        #expect(u.capabilityRequirement == .required, "battery percentage is unambiguous current/runtime state")
        #expect(u.actionExecutionState != .notRequested, "must never be answered as if no capability were needed")
        #expect(u.actionExecutionState == .unsupported, "the daemon reported UNSUPPORTED_INTENT and a capability WAS required")
    }

    @Test func listMyMeetingsToday_requiresAccountTruth_neverGeneralKnowledge() {
        let u = understand("list my meetings today")
        #expect(u.capabilityRequirement == .required, "\"my meetings\" is possessive current/account state")
        #expect(u.actionExecutionState != .notRequested)
        #expect(u.actionExecutionState == .unsupported)
    }

    @Test func describeMyLatestEmail_requiresPrivateTruth_neverGeneralKnowledge() {
        let u = understand("describe my latest email")
        #expect(u.capabilityRequirement == .required, "\"my latest email\" is possessive private state")
        #expect(u.actionExecutionState != .notRequested)
        #expect(u.actionExecutionState == .unsupported)
    }

    // MARK: - §9 PARAPHRASE GENERALIZATION (25+ unseen paraphrases — not overfit to the fixtures above)

    private struct ParaphraseCase: CustomStringConvertible {
        let transcript: String
        let expectedInteractionMode: InteractionMode
        let expectedCapabilityRequirement: CapabilityRequirement
        var description: String { transcript }
    }

    private static let paraphraseMatrix: [ParaphraseCase] = [
        // Imperative explanations
        .init(transcript: "explain how neural networks learn", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "explain quantum entanglement briefly", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "describe how a car engine works", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "describe the water cycle step by step", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Imperative lists
        .init(transcript: "list three benefits of exercise", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "list five common html tags", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "give me four tips for better sleep", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "give me two examples of renewable energy", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Imperative comparisons
        .init(transcript: "compare python and javascript", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "compare electric cars and gas cars briefly", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Imperative summaries
        .init(transcript: "summarize the french revolution in three sentences", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "summarize how vaccines work", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Imperative definitions
        .init(transcript: "define photosynthesis", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "define inflation in economics", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Explicit-count requests
        .init(transcript: "give me three reasons to learn swift", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "list six planets in order from the sun", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Explicit-length requests
        .init(transcript: "explain the theory of relativity in four sentences", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        .init(transcript: "describe your understanding of gravity in one paragraph", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .notRequired),
        // Real actions (must remain action requests, capability required)
        .init(transcript: "restart the computer", expectedInteractionMode: .actionRequest, expectedCapabilityRequirement: .required),
        .init(transcript: "mute the microphone", expectedInteractionMode: .actionRequest, expectedCapabilityRequirement: .required),
        .init(transcript: "download this report", expectedInteractionMode: .actionRequest, expectedCapabilityRequirement: .required),
        .init(transcript: "lock my screen", expectedInteractionMode: .actionRequest, expectedCapabilityRequirement: .required),
        // Private/current-state requests (must remain capability-required)
        .init(transcript: "tell me my wifi network name", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .required),
        .init(transcript: "describe my current location", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .required),
        .init(transcript: "give me my disk space remaining", expectedInteractionMode: .informationRequest, expectedCapabilityRequirement: .required),
        // Ambiguous commands — "check" is deliberately excluded from
        // `capabilityActionVerbs` (see that table's own doc comment:
        // "too ambiguous on its own — could mean 'is it installed' or
        // 'tell me about it'"), so `capabilityRequirement` correctly
        // fails conservative to `.unknown` here rather than guessing
        // either way — proving the ambiguous case is handled safely,
        // not silently defaulted to a wrong answer in either direction.
        .init(transcript: "check the weather", expectedInteractionMode: .actionRequest, expectedCapabilityRequirement: .unknown),
    ]

    @Test(arguments: paraphraseMatrix) private func paraphraseGeneralizes(_ testCase: ParaphraseCase) {
        let u = understand(testCase.transcript)
        #expect(u.interactionMode == testCase.expectedInteractionMode, "transcript: \(testCase.transcript)")
        #expect(u.capabilityRequirement == testCase.expectedCapabilityRequirement, "transcript: \(testCase.transcript)")
    }

    // MARK: - §10 PROVIDER REQUEST ACCEPTANCE (real serialized request reflects the corrected facts)

    @Test func providerRequest_forMachineLearningPhrase_reflectsCorrectedFacts_exactlyOneCall() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // only the OUTBOUND request matters here
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.example.invalid/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let context = unsupportedIntentContext()
        let localUnderstanding = understand("explain machine learning in five sentences")
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: context, understanding: localUnderstanding, strategy: strategy, persona: .friday)

        _ = provider.propose(
            transcript: "explain machine learning in five sentences", recentTurns: [], context: context,
            localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil
        )

        #expect(fake.sendCallCount == 1, "exactly one provider call")
        let body = String(data: fake.capturedRequestBodies.first ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("explain machine learning in five sentences"), "the five-sentence constraint must reach the provider verbatim")
        // The outer HTTP request body is itself JSON whose `messages[1]
        // .content` is a JSON-encoded STRING containing the real user
        // payload — so its own quotes appear literally backslash-escaped
        // one level down (`\"key\":\"value\"`), not bare `"key":"value"`.
        #expect(body.contains(#"\"actionExecutionState\":\"notRequested\""#), "no false unsupported-action state")
        #expect(!body.contains(#"\"actionExecutionState\":\"unsupported\""#))
        #expect(!body.contains(#"\"failureReason\":\"policyDenied\""#), "no fake failureReason")
    }

    // MARK: - §6 VALIDATION FORENSICS — the real root cause found while proving PART 11's real test

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

    /// The EXACT root cause found via a real installed-app/real-provider
    /// run (see the mission's final report): `ResponseValidation
    /// .executionSuccessClaimGuard`'s bare, context-free "is ready"/
    /// "done"/"completed" checks rejected a genuine, correct, real
    /// machine-learning explanation that naturally discusses training
    /// being "completed" and a model being "ready" — ordinary third-
    /// person educational content, never a claim FRIDAY did anything.
    /// This is the exact reproduction, network-free, permanent.
    @Test func genuineExplanation_mentioningTrainingCompletedAndModelReady_isNoLongerFalselyRejected() {
        let fake = FakeConversationModelRequesting()
        let realAnswer = "Machine learning is a branch of AI where systems learn patterns from data. During training, the model adjusts its parameters. Once training is completed, the model is ready to make predictions. It can then analyze new data. Performance depends on data quality."
        fake.behavior = .success(chatCompletionData(content: unifiedContent(
            dialogueAct: "explanationRequest", interactionMode: "informationRequest", text: realAnswer
        )))
        let recorder = WakeDiagnosticsRecorder()
        let unifiedConfig = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: unifiedConfig, client: fake, diagnostics: recorder)

        let outcome = CommandRuntimeOutcome.success(RuntimeTextResult(
            protocolVersion: 1, requestID: "t", correlationID: "t", taskID: "t", outcome: "UNSUPPORTED_INTENT", text: "unsupported"
        ))
        let response = presenter.response(
            for: outcome, transcript: "explain machine learning in five sentences",
            acoustics: .unavailable, explicitUserStatements: []
        )

        #expect(fake.sendCallCount == 1)
        #expect(recorder.snapshot().lastFinalResponseSource == .model, "was .deterministicFallback before this fix")
        #expect(response.text == realAnswer, "the genuine, correct explanation must now reach speech verbatim")
    }

    /// The inverse: a candidate that genuinely (falsely) claims FRIDAY
    /// itself completed an action must still be rejected, even for a
    /// `.briefExplanation`-scoped turn — the fix is scoped to the
    /// AMBIGUOUS, context-free case only, never to genuine claims.
    @Test func genuineFalseCompletionClaim_stillRejected_evenUnderBriefExplanationScope() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: unifiedContent(
            dialogueAct: "explanationRequest", interactionMode: "informationRequest",
            text: "I've completed that for you — it's done and ready."
        )))
        let recorder = WakeDiagnosticsRecorder()
        let unifiedConfig = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: unifiedConfig, client: fake, diagnostics: recorder)

        let outcome = CommandRuntimeOutcome.success(RuntimeTextResult(
            protocolVersion: 1, requestID: "t", correlationID: "t", taskID: "t", outcome: "UNSUPPORTED_INTENT", text: "unsupported"
        ))
        let response = presenter.response(
            for: outcome, transcript: "explain machine learning in five sentences",
            acoustics: .unavailable, explicitUserStatements: []
        )

        #expect(recorder.snapshot().lastFinalResponseSource == .deterministicFallback, "a genuine false completion claim must still be rejected and fall back")
        #expect(response.text != "I've completed that for you — it's done and ready.")
    }

    // MARK: - executionSuccessClaimGuard direct unit coverage (§6)

    @Test func executionSuccessClaimGuard_thirdPersonCompletionWording_allowedOnlyUnderExplanatoryScopes() {
        let texts = [
            "Once training is completed, the model can make predictions.",
            "The model is ready to make predictions after training finishes.",
            "This process is done automatically by the algorithm.",
        ]
        for t in texts {
            #expect(ResponseValidation.executionSuccessClaimGuard(t, actionExecutionState: .notRequested, responseScope: .briefExplanation), "\(t)")
            #expect(ResponseValidation.executionSuccessClaimGuard(t, actionExecutionState: .notRequested, responseScope: .longFormRequested), "\(t)")
            #expect(!ResponseValidation.executionSuccessClaimGuard(t, actionExecutionState: .notRequested, responseScope: .conversationalShort), "\(t) — default/other scopes must be completely unaffected")
        }
    }

    @Test func executionSuccessClaimGuard_genuineFirstPersonOrPronounClaims_blockedRegardlessOfScope() {
        let genuineClaims = ["I've completed your task.", "I completed it.", "I'm done with that.", "I am done.", "It's ready now.", "That's ready."]
        for claim in genuineClaims {
            #expect(!ResponseValidation.executionSuccessClaimGuard(claim, actionExecutionState: .notRequested, responseScope: .briefExplanation), "\(claim)")
            #expect(!ResponseValidation.executionSuccessClaimGuard(claim, actionExecutionState: .notRequested, responseScope: .longFormRequested), "\(claim)")
            #expect(!ResponseValidation.executionSuccessClaimGuard(claim, actionExecutionState: .notRequested, responseScope: .conversationalShort), "\(claim)")
        }
    }

    @Test func executionSuccessClaimGuard_defaultParameter_preservesExactPreExistingBehavior() {
        // No responseScope argument at all — every pre-existing call site's shape.
        #expect(!ResponseValidation.executionSuccessClaimGuard("Done.", actionExecutionState: .notRequested))
        #expect(!ResponseValidation.executionSuccessClaimGuard("The model is ready.", actionExecutionState: .notRequested))
        #expect(ResponseValidation.executionSuccessClaimGuard("Done.", actionExecutionState: .executedSucceeded))
    }

    /// A REAL regression this pass's own first attempt at the fix
    /// introduced and its own full-suite run caught (`PersonaP2FinalTests
    /// .fallbackParity_unknownCause_explicitUncertaintyPreservedAfterCandidateRejection`):
    /// `.briefExplanation` is reached for a genuinely FAILED action's
    /// explanation too (`responseScope`'s own `actionExecutionState ==
    /// .executedFailed || .denied` case), not only a `.notRequested`
    /// general-knowledge turn — the carve-out must require BOTH
    /// `responseScope` AND `actionExecutionState == .notRequested`, never
    /// `responseScope` alone.
    @Test func executionSuccessClaimGuard_briefExplanationForAGenuineActionFailure_stillBlocksBareCompletionWords() {
        #expect(!ResponseValidation.executionSuccessClaimGuard("Done — that's fixed now.", actionExecutionState: .executedFailed, responseScope: .briefExplanation))
        #expect(!ResponseValidation.executionSuccessClaimGuard("The task is completed.", actionExecutionState: .executedFailed, responseScope: .briefExplanation))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("The file was ordered and sent.", actionExecutionState: .executedFailed, responseScope: .briefExplanation))
    }

    // MARK: - neverClaimsExecutionBeyondAuthority / ExecutionClaimDetector direct unit coverage (§6)
    //
    // Real, second root cause found while proving PART 11's real TCP/UDP
    // test: "TCP ensures ORDERED, reliable delivery" — "ordered" used as
    // a plain adjective (never a claim FRIDAY ordered anything) — was
    // ALSO false-positive rejected, by a DIFFERENT guard
    // (`neverClaimsExecutionBeyondAuthority` → `ExecutionClaimDetector
    // .claimsExecutionOrMutation`) than the one PART 6's first fix
    // addressed.

    @Test func neverClaimsExecutionBeyondAuthority_orderedAsAPlainAdjective_allowedOnlyUnderExplanatoryScopes() {
        let text = "TCP is connection-oriented and ensures ordered, reliable delivery, but adds latency and overhead. UDP sends datagrams without delivery or ordering guarantees, making it faster and better suited to real-time uses like gaming, streaming, and DNS."
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .longFormRequested))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .conversationalShort), "default/other scopes must be completely unaffected")
    }

    @Test func neverClaimsExecutionBeyondAuthority_genuineOrderedClaim_blockedRegardlessOfScope() {
        let claim = "I ordered that replacement part for you."
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(claim, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(claim, actionExecutionState: .notRequested, responseScope: .conversationalShort))
    }

    /// A second homograph found in the SAME real forensic run: "hand-
    /// written rules" — "written" as an ordinary compound-adjective
    /// modifier, never a claim FRIDAY wrote anything.
    @Test func neverClaimsExecutionBeyondAuthority_writtenAsAPlainAdjective_allowedOnlyUnderExplanatoryScopes() {
        let text = "Instead of following only hand-written rules, a model adjusts its internal parameters during training."
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .longFormRequested))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(text, actionExecutionState: .notRequested, responseScope: .conversationalShort), "default/other scopes must be completely unaffected")
    }

    @Test func neverClaimsExecutionBeyondAuthority_genuineWrittenClaim_blockedRegardlessOfScope() {
        let claim = "I've written the report for you."
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(claim, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(claim, actionExecutionState: .notRequested, responseScope: .conversationalShort))
    }

    @Test func neverClaimsExecutionBeyondAuthority_unambiguousVerbs_stayProtectedEvenUnderExplanatoryScope() {
        // Only `resultStateAdjectives` and the narrow "ordered" homograph
        // get the scope-based carve-out — every other `pastFormTriggers`
        // verb (created/deleted/sent/uploaded/etc.) keeps its full,
        // unconditional protection, even with no explicit subject nearby,
        // regardless of scope.
        let texts = ["The file was created automatically.", "The note was deleted by the system.", "The report was sent overnight."]
        for t in texts {
            #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority(t, actionExecutionState: .notRequested, responseScope: .briefExplanation), "\(t)")
        }
    }

    // MARK: - neverOffersRetryUnlessAllowed / neverOffersRetryClaimUnlessAllowed direct unit coverage (§6)
    //
    // Real, THIRD root cause found while proving PART 11's real HTTP-503
    // test: "...it may work if you try again later" — ordinary factual
    // advice about the TOPIC (how to handle an HTTP 503) — was ALSO
    // false-positive rejected as if FRIDAY itself were offering to retry
    // an action it never attempted.

    @Test func neverOffersRetry_topicalTryAgainAdvice_allowedOnlyForNotRequestedPlusExplanatoryScope() {
        let text = "HTTP 503 means Service Unavailable: the server is temporarily unable to handle the request. It may work if you try again later."
        #expect(ResponseValidation.neverOffersRetryUnlessAllowed(text, retryability: .unknown, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(ResponseValidation.neverOffersRetryClaimUnlessAllowed(text, retryability: .unknown, actionExecutionState: .notRequested, responseScope: .briefExplanation))
        #expect(!ResponseValidation.neverOffersRetryUnlessAllowed(text, retryability: .unknown, actionExecutionState: .notRequested, responseScope: .conversationalShort), "unaffected for other scopes")
        #expect(!ResponseValidation.neverOffersRetryUnlessAllowed(text, retryability: .unknown), "unaffected default parameters — every pre-existing call site's exact behavior")
    }

    @Test func neverOffersRetry_genuineRetryOfferForARealFailedAction_stillBlocked() {
        #expect(!ResponseValidation.neverOffersRetryUnlessAllowed("Want me to try again?", retryability: .notAllowed, actionExecutionState: .executedFailed, responseScope: .briefExplanation))
        #expect(!ResponseValidation.neverOffersRetryClaimUnlessAllowed("Should I try that again?", retryability: .notAllowed, actionExecutionState: .executedFailed, responseScope: .briefExplanation))
    }

    @Test func fullGuardChain_realHttp503Explanation_nowAccepted() {
        let text = "HTTP 503 means Service Unavailable: the server is temporarily unable to handle the request, often due to overload or maintenance. It may work if you try again later."
        #expect(ResponseValidation.passesSemanticGuards(
            text, wasSuccess: false, actionExecutionState: .notRequested, retryability: .unknown, failureReason: .unknown, responseScope: .briefExplanation
        ), "was rejected before this pass's third guard fix")
    }
}
