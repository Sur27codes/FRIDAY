import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-O.3 — dedicated coverage for the LIVE-CONFIRMED root cause: a
/// real OpenAI response substituted descriptive PHRASES for three
/// non-string primitive fields (`reasoning.continuationReference` — Bool
/// expected, got `"the bug they finally fixed"`; `reasoning.humorSuitability`
/// and `reasoning.uncertainty` — Double expected, got `"subtle"`/`"low"`),
/// because the unified prompt listed these field NAMES but never their
/// JSON TYPES. `response_format` is plain `{"type":"json_object"}` (OpenAI's
/// basic JSON-mode) for every path (reasoner/realizer/unified) — it
/// enforces valid JSON SYNTAX only, never per-property types/enums — so
/// this class of bug was always possible until the PROMPT itself pinned
/// down each field's exact type, which is the fix this file verifies.
/// None of this touches the Swift wire TYPES themselves (still `Bool`/
/// `Double`, unchanged) or any semantic-authority code.
@Suite struct UnifiedWireContractConformanceTests {
    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)},\"finish_reason\":\"stop\"}]}"
        return envelope.data(using: .utf8)!
    }

    // MARK: - §16: the exact live sanitized fixture, before and after correction

    /// The SANITIZED equivalent of the real live provider output that
    /// triggered this pass — reproduces the EXACT bug (three fields
    /// carrying descriptive phrases instead of their required primitive
    /// JSON type), not just the first one the decoder happened to report.
    private let liveBuggyContent = """
    {"reasoning":{"dialogueAct":"personalUpdate","interactionMode":"conversational","userGoal":"share a successful bug fix","topic":"bugOrIssue","continuationReference":"the bug they finally fixed","correctionTarget":"none","explicitConstraints":[],"recommendedSocialRegister":"friendlyNeutral","humorSuitability":"subtle","followUpNeed":false,"uncertainty":"low"},"response":{"text":"Finally. Nice work\\u2014that bug had it coming.","responseGoal":"celebrate the user's success","socialRegister":"warm and friendly","humorUsed":true,"prosodyIntent":"pleased, lightly playful"}}
    """

    /// The SAME response, with the three type-mismatched fields corrected
    /// to the exact JSON primitive types the wire contract requires —
    /// `correctionTarget` also corrected from the sentinel string `"none"`
    /// to JSON `null` (§16: "use the exact legal machine representation").
    private let liveCorrectedContent = """
    {"reasoning":{"dialogueAct":"personalUpdate","interactionMode":"conversational","userGoal":"share a successful bug fix","topic":"bugOrIssue","continuationReference":false,"correctionTarget":null,"explicitConstraints":[],"recommendedSocialRegister":"friendlyNeutral","humorSuitability":0.3,"followUpNeed":false,"uncertainty":0.2},"response":{"text":"Finally. Nice work\\u2014that bug had it coming.","responseGoal":"celebrate the user's success","socialRegister":"warm and friendly","humorUsed":true,"prosodyIntent":"pleased, lightly playful"}}
    """

    @Test func liveBuggyFixture_failsClosed_withPreciseContinuationReferenceDiagnostic() {
        let data = chatCompletionData(content: liveBuggyContent)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("typeMismatch"))
        #expect(detail.contains("reasoning.continuationReference"))
    }

    @Test func liveBuggyFixture_neverPartiallyDecodes_evenThoughContentIsValidJSON() {
        // §12/§13 — a decode failure must be ALL-OR-NOTHING: the rest of
        // the object being perfectly well-formed must never smuggle a
        // partial result through.
        let data = chatCompletionData(content: liveBuggyContent)
        let diagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self)
        #expect(diagnostic.structuredJSONParseable == true, "the content IS valid JSON — this is a type-contract failure, not a syntax failure")
        #expect(diagnostic.topLevelKeys == ["reasoning", "response"])
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
    }

    @Test func liveCorrectedFixture_decodesFullyThroughToSemanticValidation() {
        let data = chatCompletionData(content: liveCorrectedContent)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil)
        let unified = wire.flatMap { ConversationModelSchema.unified(from: $0) }
        #expect(unified != nil)
        #expect(unified?.understanding.dialogueAct == .personalUpdate)
        #expect(unified?.understanding.interactionMode == .conversational)
        #expect(unified?.understanding.continuationOfPreviousTurn == false)
        #expect(unified?.understanding.correctionTarget == nil, "the sentinel string \"none\" must become nil, not a literal correctionTarget value")
        #expect(unified?.understanding.socialRegisterRecommendation == .friendlyNeutral)
        #expect(unified?.candidateText == "Finally. Nice work\u{2014}that bug had it coming.")
    }

    @Test func liveCorrectedFixture_reachesTheEndToEndPresenterPipeline() {
        // Full pipeline proof: the corrected shape reaches semantic
        // validation and is genuinely ACCEPTED (a benign, truthful
        // candidate for a positive personal update).
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: liveCorrectedContent))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, client: fake, diagnostics: recorder)
        let taskID = "live-corrected-1"
        let result = RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: "SUCCESS", text: "Acknowledged.")
        let response = presenter.response(for: .success(result), transcript: "I finally fixed that bug.", acoustics: .unavailable, explicitUserStatements: [])
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerUsed == "model")
        #expect(snapshot.lastRealizerUsed == "model")
        #expect(snapshot.lastSchemaValid == true)
        #expect(snapshot.lastSemanticGroundingValid == true)
        #expect(snapshot.lastResponseAccepted == true)
        #expect(snapshot.lastFinalResponseSource == .model)
        #expect(snapshot.lastProviderCallCount == 1)
        #expect(response.text == "Finally. Nice work\u{2014}that bug had it coming.")
    }

    // MARK: - §17: full field-contract battery (every practical field, one golden fixture)

    @Test func fullFieldContract_everyFieldPresentAndCorrectlyTyped_decodesAndMapsCorrectly() {
        let content = """
        {"reasoning":{"dialogueAct":"needStatement","interactionMode":"actionRequest","userGoal":"draft an email","topic":"draftOrMessage","continuationReference":true,"correctionTarget":"earlier","explicitConstraints":["waitForConfirmation"],"recommendedSocialRegister":"professional","humorSuitability":0.0,"followUpNeed":true,"uncertainty":0.4},"response":{"text":"Sure, what should it say?","responseGoal":"gather drafting content","socialRegister":"professional","humorUsed":false,"prosodyIntent":"neutral"}}
        """
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil)
        let unified = wire.flatMap { ConversationModelSchema.unified(from: $0) }
        #expect(unified?.understanding.dialogueAct == .needStatement)
        #expect(unified?.understanding.interactionMode == .actionRequest)
        #expect(unified?.understanding.userGoal == "draft an email")
        #expect(unified?.understanding.topic == "draftOrMessage")
        #expect(unified?.understanding.continuationOfPreviousTurn == true)
        #expect(unified?.understanding.correctionTarget == "earlier")
        #expect(unified?.understanding.explicitConstraints == [.waitForConfirmation])
        #expect(unified?.understanding.socialRegisterRecommendation == .professional)
        #expect(unified?.understanding.humorSuitability == 0.0)
        #expect(unified?.understanding.followUpNeeded == true)
        #expect(unified?.understanding.uncertainty == 0.4)
        #expect(unified?.candidateText == "Sure, what should it say?")
    }

    @Test func fullFieldContract_allFieldsOmitted_stillDecodesToSafeDefaults() {
        // Every non-required field is genuinely optional — omitting all
        // of them (the model choosing to say nothing about them, which
        // this pass's own prompt fix explicitly permits via "or null")
        // must never be a decode failure.
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Got it.\"}}"
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil)
        let unified = wire.flatMap { ConversationModelSchema.unified(from: $0) }
        #expect(unified?.understanding.continuationOfPreviousTurn == false)
        #expect(unified?.understanding.correctionTarget == nil)
        #expect(unified?.understanding.explicitConstraints == [])
        #expect(unified?.understanding.socialRegisterRecommendation == nil)
    }

    // MARK: - §18: prompt enumerates every closed vocabulary exactly

    @Test func unifiedPrompt_enumeratesAllDialogueActValues() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        let dialogueActValues = [
            "command", "request", "question", "statement", "personalUpdate", "acknowledgement", "correction",
            "clarification", "constraint", "prohibition", "permissionResponse", "followUp", "explanationRequest",
            "confirmationRequest", "socialRemark", "jokeOrPlayfulRemark", "greeting", "farewell", "needStatement", "styleRefinement",
        ]
        for value in dialogueActValues {
            #expect(prompt.contains("\"\(value)\""), "unifiedSystemPolicy is missing dialogueAct value \"\(value)\"")
        }
    }

    @Test func unifiedPrompt_enumeratesAllInteractionModeValues() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        for value in ["actionRequest", "informationRequest", "conversational", "correction", "constraint", "clarification"] {
            #expect(prompt.contains("\"\(value)\""), "unifiedSystemPolicy is missing interactionMode value \"\(value)\"")
        }
    }

    @Test func unifiedPrompt_enumeratesAllExplicitConstraintValues() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        for value in ["doNotAct", "doNotModify", "waitForConfirmation", "keepExistingState", "answerOnly", "explainOnly"] {
            #expect(prompt.contains("\"\(value)\""), "unifiedSystemPolicy is missing explicitConstraints value \"\(value)\"")
        }
    }

    @Test func unifiedPrompt_enumeratesAllSocialRegisterValues() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        for value in ["casualFriendly", "friendlyNeutral", "professional", "focused", "reassuring", "serious", "warning", "urgent"] {
            #expect(prompt.contains("\"\(value)\""), "unifiedSystemPolicy is missing recommendedSocialRegister value \"\(value)\"")
        }
    }

    @Test func unifiedPrompt_specifiesJSONBooleanTypeForContinuationReferenceAndFollowUpNeed() {
        // §18/§0 — the ROOT CAUSE this whole pass fixes: these fields
        // must be explicitly told they are JSON booleans, not just named.
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        #expect(prompt.contains("\"continuationReference\""))
        #expect(prompt.contains("\"followUpNeed\""))
        #expect(prompt.contains("\"humorUsed\""))
        #expect(prompt.contains("are the JSON boolean true or false ONLY"))
    }

    @Test func unifiedPrompt_specifiesJSONNumberTypeForHumorSuitabilityAndUncertainty() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        #expect(prompt.contains("\"humorSuitability\""))
        #expect(prompt.contains("\"uncertainty\""))
        #expect(prompt.contains("are JSON NUMBERS between 0 and 1"))
    }

    @Test func unifiedPrompt_specifiesNullConventionForCorrectionTarget() {
        let prompt = ConversationModelPersona.unifiedSystemPolicy
        #expect(prompt.contains("\"correctionTarget\""))
        #expect(prompt.contains("null"))
        // §16 — the exact sentinel-string bug found live must be
        // explicitly disallowed, not merely left ambiguous.
        #expect(prompt.contains("never the word \"none\""))
    }

    // MARK: - §19: representative good/bad shape fixtures for every mismatch class

    @Test func goodShape_validBoolean_decodes() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\",\"continuationReference\":true},\"response\":{\"text\":\"Right.\"}}"
        let data = chatCompletionData(content: content)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) != nil)
    }

    @Test func badShape_stringForBoolean_failsClosed() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\",\"continuationReference\":\"yes, definitely\"},\"response\":{\"text\":\"Right.\"}}"
        let data = chatCompletionData(content: content)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
        guard case .structuredDecodeFailure(let detail) = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self) else {
            Issue.record("expected .structuredDecodeFailure"); return
        }
        #expect(detail.contains("typeMismatch"))
    }

    @Test func goodShape_validEnum_decodesAndValidates() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"greeting\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Hey.\"}}"
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(ConversationModelSchema.unified(from: wire!)?.understanding.dialogueAct == .greeting)
    }

    @Test func badShape_illegalEnum_decodesAtCodableLevel_failsAtSchemaValidation() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"emotionallyComplicated\"},\"response\":{\"text\":\"Hey.\"}}"
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil, "an illegal enum STRING still decodes fine at the Codable level")
        #expect(ConversationModelSchema.unified(from: wire!) == nil, "but must fail closed at schema validation")
    }

    @Test func goodShape_validResponseText_decodes() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Sounds good.\"}}"
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil)
        #expect(ConversationModelSchema.unified(from: wire!)?.candidateText == "Sounds good.")
    }

    @Test func badShape_wrongResponseFieldType_textAsNumber_failsClosed() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":42}}"
        let data = chatCompletionData(content: content)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
    }

    @Test func badShape_missingRequiredField_dialogueAct_failsClosed() {
        let content = "{\"reasoning\":{\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Hey.\"}}"
        let data = chatCompletionData(content: content)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
        guard case .structuredDecodeFailure(let detail) = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self) else {
            Issue.record("expected .structuredDecodeFailure"); return
        }
        #expect(detail.contains("reasoning.dialogueAct"))
    }

    @Test func badShape_missingRequiredField_text_failsClosed() {
        let content = "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"responseGoal\":\"x\"}}"
        let data = chatCompletionData(content: content)
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) == nil)
    }

    // MARK: - §10: response_format enforcement claim, verified from actual request bytes

    @Test func responseFormat_isPlainJSONObjectMode_notPropertyLevelSchema() {
        // §10 — honest verification: the ACTUAL outgoing request uses
        // OpenAI's basic JSON-mode (`{"type":"json_object"}`), never a
        // `json_schema`/`strict` structured-outputs object. This is why a
        // property-level type mismatch was possible in the first place —
        // conformance here comes ENTIRELY from prompt precision (this
        // pass's fix), not from provider-side schema enforcement.
        let data = ConversationModelRequestBuilder.encode(systemPolicy: "p", userPayloadJSON: "{}", modelName: "m", temperature: 0.2)
        let json = String(data: data!, encoding: .utf8)!
        #expect(json.contains("\"response_format\":{\"type\":\"json_object\"}"))
        #expect(!json.contains("json_schema"))
        #expect(!json.contains("\"strict\""))
    }

    // MARK: - Regression guard: the prompt-precision fix itself must fit the request-size ceiling

    @Test func unifiedSystemPolicy_fitsWithHeadroomUnderItsOwnRequestSizeCeiling() {
        // A REAL self-inflicted bug caught while building this pass: adding
        // SECTION C's explicit JSON-type guidance pushed the combined
        // system prompt bytes past the (then-shared) request-size ceiling,
        // so EVERY unified request started failing LOCALLY (before any
        // network attempt) — a total regression with a completely
        // different, non-obvious cause from the live type-mismatch bug
        // this pass set out to fix. This guards against a future prompt
        // edit silently reintroducing that failure mode.
        let policyBytes = ConversationModelPersona.unifiedSystemPolicy.utf8.count
        #expect(policyBytes < ConversationModelLimits.maxUnifiedSerializedContextBytes, "system prompt alone (\(policyBytes) bytes) must leave real headroom for the user payload JSON within maxUnifiedSerializedContextBytes")
    }

    @Test func unifiedProvider_realisticRequest_staysUnderItsOwnSizeCeiling() {
        // End-to-end proof at the ACTUAL call site, not just the bare
        // system prompt: a realistic request (with recent-turn history)
        // must still encode successfully.
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let recentTurns = (0..<5).map {
            ConversationTurn(taskID: "r\($0)", transcript: "some prior turn's transcript text", responseFamily: .genericSuccess, responseText: "some prior response text", purpose: .success)
        }
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "I need to email my professor about missing class.", recentTurns: recentTurns, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "I need to email my professor about missing class.", recentTurns: recentTurns, context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: "some avoided text")
        #expect(fake.sendCallCount == 1, "the request must actually be SENT (encode must not silently fail on a realistic payload)")
    }

    // MARK: - §21: call count unaffected by the contract fix

    @Test func correctedFixture_stillMakesExactlyOneCall() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: liveCorrectedContent))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "I finally fixed that bug.", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        let result = provider.propose(transcript: "I finally fixed that bug.", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        #expect(result != nil)
        #expect(fake.sendCallCount == 1)
    }
}
