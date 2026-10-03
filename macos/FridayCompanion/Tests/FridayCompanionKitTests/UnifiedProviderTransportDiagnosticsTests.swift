import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-O.1 — dedicated coverage for the root-cause fix behind the
/// live 21/21 unified-provider failure: a `null` `message.content` (a
/// standards-compliant OpenAI-compatible response when `finish_reason ==
/// "length"` cuts a completion off before visible output) used to fail
/// envelope decoding ENTIRELY, `finish_reason` was never decoded at all,
/// and the unified path reused the SAME 400-token budget as each
/// single-stage call despite combining two structured objects. None of
/// this touches ANY semantic-authority code — it is purely transport/
/// decode/diagnostic-layer.
@Suite struct UnifiedProviderTransportDiagnosticsTests {
    private struct EnvelopeMessage: Encodable { let content: String? }
    private struct EnvelopeChoice: Encodable { let message: EnvelopeMessage; let finish_reason: String? }
    private struct Envelope: Encodable { let choices: [EnvelopeChoice] }

    private func chatCompletionEnvelope(content: String?, finishReason: String? = "stop") -> Data {
        let envelope = Envelope(choices: [EnvelopeChoice(message: EnvelopeMessage(content: content), finish_reason: finishReason)])
        return try! JSONEncoder().encode(envelope)
    }

    private struct TestStructuredType: Decodable { let text: String }

    // MARK: - Root-cause: null content + finish_reason=length

    @Test func nullContent_finishReasonLength_classifiesAsResponseTruncatedByLength() {
        let data = chatCompletionEnvelope(content: nil, finishReason: "length")
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: TestStructuredType.self) == nil)
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        #expect(outcome == .responseTruncatedByLength)
    }

    @Test func emptyStringContent_finishReasonLength_classifiesAsResponseTruncatedByLength() {
        // A model that emits an empty string (rather than a literal
        // `null`) before being cut off must be classified identically.
        let data = chatCompletionEnvelope(content: "", finishReason: "length")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        #expect(outcome == .responseTruncatedByLength)
    }

    @Test func nullContent_finishReasonStop_classifiesAsMissingContent_notTruncation() {
        // A `null`/empty content with a NORMAL finish reason is a
        // genuinely different (and rarer) situation — must not be
        // mislabeled as a token-budget truncation it wasn't.
        let data = chatCompletionEnvelope(content: nil, finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        #expect(outcome == .missingContent)
    }

    @Test func nullContent_neverCrashesEnvelopeDecoding() {
        // Before the fix, `content: String` (non-optional) made the
        // WHOLE envelope fail Decodable synthesis for a standards-
        // compliant `null` — this proves it now decodes far enough to
        // distinguish the failure precisely rather than collapsing to
        // the opaque `envelopeDecodeFailure`.
        let data = chatCompletionEnvelope(content: nil, finishReason: "length")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        #expect(outcome != .envelopeDecodeFailure)
    }

    // MARK: - Successful decode still works (regression guard on the envelope change)

    @Test func validContent_stillDecodesSuccessfully() {
        let data = chatCompletionEnvelope(content: "{\"text\":\"hello\"}", finishReason: "stop")
        let result = ConversationModelRequestBuilder.decodeChatCompletion(data, as: TestStructuredType.self)
        #expect(result?.text == "hello")
    }

    // MARK: - Malformed envelope / structured decode failure (unchanged classes, still correct)

    @Test func malformedEnvelope_classifiesAsEnvelopeDecodeFailure() {
        let data = "not json at all".data(using: .utf8)!
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        #expect(outcome == .envelopeDecodeFailure)
    }

    @Test func validEnvelope_invalidInnerStructuredJSON_classifiesAsStructuredDecodeFailure() {
        let data = chatCompletionEnvelope(content: "{\"wrongField\":123}", finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: TestStructuredType.self)
        // P2-M5V8.1-O.2 §2 — precise detail now available: a missing
        // required key surfaces its OWN name in the coding path, not just
        // a bare "something failed to decode."
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("keyNotFound"))
        #expect(detail.contains("text"))
    }

    // MARK: - Sanitized provider error classification (§3)

    @Test func httpFailure_openAIErrorEnvelope_classifiesAsProviderRejected_withSanitizedFields() {
        let detail = "HTTP 400: {\"error\":{\"message\":\"Invalid schema for response_format\",\"type\":\"invalid_request_error\",\"param\":\"response_format\",\"code\":\"invalid_json_schema\"}}"
        let outcome = ProviderStageOutcome.classifyTransportFailure(detail)
        guard case .providerRejected(let statusCode, let errorType, let errorCode, let errorParam, let sanitizedMessage) = outcome else {
            Issue.record("expected .providerRejected, got \(outcome)")
            return
        }
        #expect(statusCode == 400)
        #expect(errorType == "invalid_request_error")
        #expect(errorCode == "invalid_json_schema")
        #expect(errorParam == "response_format")
        #expect(sanitizedMessage == "Invalid schema for response_format")
    }

    @Test func httpFailure_nonJSONBody_fallsBackToPlainHTTPFailure() {
        let detail = "HTTP 502: <html>Bad Gateway</html>"
        let outcome = ProviderStageOutcome.classifyTransportFailure(detail)
        #expect(outcome == .httpFailure(502, "<html>Bad Gateway</html>"))
    }

    @Test func httpFailure_noBody_classifiesAsPlainHTTPFailure() {
        let outcome = ProviderStageOutcome.classifyTransportFailure("HTTP 503")
        #expect(outcome == .httpFailure(503, nil))
    }

    @Test func providerRejected_sanitizedMessage_isLengthBounded() {
        let longMessage = String(repeating: "x", count: 5000)
        let detail = "HTTP 400: {\"error\":{\"message\":\"\(longMessage)\",\"type\":\"invalid_request_error\"}}"
        let outcome = ProviderStageOutcome.classifyTransportFailure(detail)
        guard case .providerRejected(_, _, _, _, let sanitizedMessage) = outcome else {
            Issue.record("expected .providerRejected")
            return
        }
        #expect((sanitizedMessage?.count ?? 0) <= 200)
    }

    @Test func providerRejected_neverContainsAuthorizationOrCredentialLookingText() {
        // Defense-in-depth: even if a provider's error body echoed
        // something that LOOKED like a header, the sanitized fields are
        // fixed-shape (type/code/param/message) — a Bearer-looking
        // string embedded in the error body only ever surfaces as the
        // (length-capped) `message` text, never as a distinct credential
        // field this codebase could be tempted to log/print separately.
        let detail = "HTTP 401: {\"error\":{\"message\":\"Incorrect API key provided: sk-***\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}"
        let outcome = ProviderStageOutcome.classifyTransportFailure(detail)
        guard case .providerRejected(let statusCode, _, let errorCode, _, _) = outcome else {
            Issue.record("expected .providerRejected")
            return
        }
        #expect(statusCode == 401)
        #expect(errorCode == "invalid_api_key")
    }

    // MARK: - Timeout / cancelled / not-configured classification unchanged

    @Test func timeoutDetail_classifiesAsTimeout() {
        #expect(ProviderStageOutcome.classifyTransportFailure("request timed out after 8.0s") == .timeout)
    }

    @Test func cancelledDetail_classifiesAsCancelled() {
        #expect(ProviderStageOutcome.classifyTransportFailure("cancelled") == .cancelled)
    }

    @Test func notConfiguredDetail_classifiesAsNotConfigured() {
        #expect(ProviderStageOutcome.classifyTransportFailure("not configured") == .notConfigured)
    }

    // MARK: - Token budget: unified path uses its OWN larger budget, two-stage unaffected

    @Test func encode_unifiedCompletionTokenBudget_usedWhenExplicitlyPassed() {
        let data = ConversationModelRequestBuilder.encode(
            systemPolicy: "policy", userPayloadJSON: "{}", modelName: "m", temperature: 0.2,
            tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit,
            completionTokenBudget: ConversationModelLimits.maxUnifiedCompletionTokens
        )
        let json = String(data: data!, encoding: .utf8)!
        #expect(json.contains("\"max_completion_tokens\":\(ConversationModelLimits.maxUnifiedCompletionTokens)"))
        #expect(!json.contains("\"max_completion_tokens\":\(ConversationModelLimits.maxCompletionTokens)"))
    }

    @Test func encode_defaultCompletionTokenBudget_unchangedForExistingCallers() {
        // §7 — `ModelConversationReasoner`/`ModelNaturalResponseRealizer`
        // never pass `completionTokenBudget` — this proves the DEFAULT
        // still produces the exact pre-existing 400-token value.
        let data = ConversationModelRequestBuilder.encode(
            systemPolicy: "policy", userPayloadJSON: "{}", modelName: "m", temperature: 0.1,
            tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit
        )
        let json = String(data: data!, encoding: .utf8)!
        #expect(json.contains("\"max_completion_tokens\":\(ConversationModelLimits.maxCompletionTokens)"))
    }

    @Test func unifiedProvider_actualOutgoingRequest_usesLargerBudget() {
        // End-to-end proof at the ACTUAL call site: `ModelUnifiedConversationProvider`
        // must request the larger unified budget in the real request it sends.
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = ConversationModelConfig(
            endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m",
            tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit, architecture: .unifiedOneCall
        )
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "hi", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = String(data: body, encoding: .utf8) else {
            Issue.record("no request body captured")
            return
        }
        #expect(json.contains("\"max_completion_tokens\":\(ConversationModelLimits.maxUnifiedCompletionTokens)"))
    }

    // MARK: - Call count remains exactly one after the fix (no hidden retry)

    @Test func fixDoesNotIntroduceRetry_stillExactlyOneCallOnFailure() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionEnvelope(content: nil, finishReason: "length"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        let result = provider.propose(transcript: "hi", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        #expect(result == nil, "a truncated/empty response must still fail closed to nil")
        #expect(fake.sendCallCount == 1, "a decode failure must never trigger a repair/retry request")
    }

    // MARK: - Diagnostic outcome recorded precisely on the truncation path (not a vague failure)

    @Test func provider_truncatedResponse_recordsResponseTruncatedByLengthOutcome() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionEnvelope(content: nil, finishReason: "length"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "hi", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerOutcome == .responseTruncatedByLength)
        #expect(snapshot.lastRealizerOutcome == .responseTruncatedByLength)
        #expect(snapshot.lastProviderCallCount == 1)
    }

    // MARK: - P2-M5V8.1-O.2 §4/§17: nonempty PARTIAL JSON + finish_reason=length

    @Test func nonemptyPartialJSON_finishReasonLength_classifiesAsResponseTruncatedByLength() {
        // A real provider cut off mid-object — valid UTF-8, non-empty,
        // but not valid JSON (or not a valid ModelUnifiedWire) — must
        // still be recognized as TRUNCATION, not a generic structured-
        // decode/schema failure, when finish_reason says so.
        let partial = "{\"reasoning\":{\"dialogueAct\":\"personalUpdate\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Nice, gl"
        let data = chatCompletionEnvelope(content: partial, finishReason: "length")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        #expect(outcome == .responseTruncatedByLength)
    }

    @Test func nonemptyPartialJSON_finishReasonStop_classifiesAsStructuredDecodeFailure_notTruncation() {
        // The SAME malformed content, but a NORMAL finish reason — this
        // is a genuine contract/decode problem, not token exhaustion.
        let partial = "{\"reasoning\":{\"dialogueAct\":\"personalUpdate\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Nice, gl"
        let data = chatCompletionEnvelope(content: partial, finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
    }

    // MARK: - P2-M5V8.1-O.2 §17: full ModelUnifiedWire fixture battery

    private func unifiedJSON(reasoning: String? = "{\"dialogueAct\":\"personalUpdate\",\"interactionMode\":\"conversational\"}", response: String? = "{\"text\":\"Nice, glad you got it sorted.\"}") -> String {
        var parts: [String] = []
        if let reasoning { parts.append("\"reasoning\":\(reasoning)") }
        if let response { parts.append("\"response\":\(response)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    @Test func fullUnifiedResult_validCompleteShape_decodesSuccessfully() {
        let data = chatCompletionEnvelope(content: unifiedJSON(), finishReason: "stop")
        #expect(ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self) != nil)
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        #expect(outcome == .success)
    }

    @Test func fullUnifiedResult_validShape_realModelUnifiedWire_decodesViaSchema() {
        // End-to-end through the REAL production type + schema validator,
        // not just the test proxy.
        let data = chatCompletionEnvelope(content: unifiedJSON(), finishReason: "stop")
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil)
        let unified = wire.flatMap { ConversationModelSchema.unified(from: $0) }
        #expect(unified?.understanding.dialogueAct == .personalUpdate)
        #expect(unified?.candidateText == "Nice, glad you got it sorted.")
    }

    @Test func validJSON_wrongTopLevelKeys_classifiesAsKeyNotFound_forReasoning() {
        let data = chatCompletionEnvelope(content: "{\"analysis\":{},\"response\":{\"text\":\"hi\"}}", finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("keyNotFound"))
        #expect(detail.contains("reasoning"))
    }

    @Test func missingReasoningKey_classifiesPrecisely() {
        let data = chatCompletionEnvelope(content: unifiedJSON(reasoning: nil), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("reasoning"))
    }

    @Test func missingResponseKey_classifiesPrecisely() {
        let data = chatCompletionEnvelope(content: unifiedJSON(response: nil), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("response"))
    }

    @Test func missingNestedRequiredField_dialogueAct_classifiesWithExactCodingPath() {
        // Mirrors the mission's own Example B exactly: a missing nested
        // required field surfaces its OWN dot-joined coding path.
        let data = chatCompletionEnvelope(content: unifiedJSON(reasoning: "{\"interactionMode\":\"conversational\"}"), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("keyNotFound"))
        #expect(detail.contains("reasoning.dialogueAct"))
    }

    @Test func missingNestedRequiredField_text_classifiesWithExactCodingPath() {
        let data = chatCompletionEnvelope(content: unifiedJSON(response: "{\"responseGoal\":\"success\"}"), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("response.text"))
    }

    @Test func wrongType_humorSuitabilityGivenAString_classifiesAsTypeMismatch() {
        let data = chatCompletionEnvelope(content: unifiedJSON(reasoning: "{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\",\"humorSuitability\":\"high\"}"), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("typeMismatch"))
        #expect(detail.contains("humorSuitability"))
    }

    @Test func unexpectedNull_dialogueActGivenNull_classifiesAsValueNotFound() {
        let data = chatCompletionEnvelope(content: unifiedJSON(reasoning: "{\"dialogueAct\":null,\"interactionMode\":\"conversational\"}"), finishReason: "stop")
        let outcome = ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self)
        guard case .structuredDecodeFailure(let detail) = outcome else {
            Issue.record("expected .structuredDecodeFailure, got \(outcome)"); return
        }
        #expect(detail.contains("valueNotFound"))
        #expect(detail.contains("reasoning.dialogueAct"))
    }

    @Test func illegalEnumValue_decodesAtCodableLevel_thenFailsAtSchemaValidation_notStructuredDecode() {
        // `interactionMode`/`dialogueAct` are plain `String` fields at the
        // Codable level — an illegal ENUM VALUE decodes FINE here and
        // only fails later, at `ConversationModelSchema.unified(from:)`'s
        // own semantic validation — a materially different failure point
        // (confirms these two classes are never conflated).
        let data = chatCompletionEnvelope(content: unifiedJSON(reasoning: "{\"dialogueAct\":\"statement\",\"interactionMode\":\"totallyBogusMode\"}"), finishReason: "stop")
        #expect(ConversationModelRequestBuilder.classifyDecodeFailure(data, as: ModelUnifiedWire.self) == .success)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil, "the illegal enum string itself still decodes as a plain String")
        #expect(ConversationModelSchema.unified(from: wire!) == nil, "but semantic/schema validation must still fail closed")
    }

    // MARK: - P2-M5V8.1-O.2 §2/§6: diagnoseUnifiedDecode structural inspection

    @Test func diagnoseUnifiedDecode_fullSuccess_reportsNoFailureAndCorrectStructure() {
        let data = chatCompletionEnvelope(content: unifiedJSON(), finishReason: "stop")
        let diagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self)
        #expect(diagnostic.finishReason == "stop")
        #expect(diagnostic.contentWasNull == false)
        #expect(diagnostic.contentWasEmpty == false)
        #expect(diagnostic.structuredJSONParseable == true)
        #expect(diagnostic.topLevelJSONType == "object")
        #expect(diagnostic.topLevelKeys == ["reasoning", "response"])
        #expect(diagnostic.decoderFailureKind == nil)
        #expect(diagnostic.assistantContentByteCount > 0)
        #expect(diagnostic.assistantContentCharacterCount > 0)
    }

    @Test func diagnoseUnifiedDecode_wrongTopLevelKeys_reportsExactKeys() {
        let data = chatCompletionEnvelope(content: "{\"analysis\":{},\"response\":{\"text\":\"hi\"}}", finishReason: "stop")
        let diagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self)
        #expect(diagnostic.structuredJSONParseable == true)
        #expect(diagnostic.topLevelKeys == ["analysis", "response"])
        #expect(diagnostic.decoderFailureKind == "keyNotFound")
    }

    @Test func diagnoseUnifiedDecode_neverIncludesContentPreview_unlessExplicitlyRequested() {
        let data = chatCompletionEnvelope(content: unifiedJSON(), finishReason: "stop")
        let defaultDiagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self)
        #expect(defaultDiagnostic.sanitizedContentPreview == nil)
        let optedIn = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self, includeContentPreview: true)
        #expect(optedIn.sanitizedContentPreview != nil)
    }

    @Test func diagnoseUnifiedDecode_usageMetadata_surfacedWhenProviderReportsIt() {
        struct UsageEnvelopeMessage: Encodable { let content: String? }
        struct UsageEnvelopeChoice: Encodable { let message: UsageEnvelopeMessage; let finish_reason: String? }
        struct CompletionTokensDetails: Encodable { let reasoning_tokens: Int }
        struct Usage: Encodable { let prompt_tokens: Int; let completion_tokens: Int; let total_tokens: Int; let completion_tokens_details: CompletionTokensDetails }
        struct UsageEnvelope: Encodable { let choices: [UsageEnvelopeChoice]; let usage: Usage }
        let envelope = UsageEnvelope(
            choices: [UsageEnvelopeChoice(message: UsageEnvelopeMessage(content: unifiedJSON()), finish_reason: "stop")],
            usage: Usage(prompt_tokens: 500, completion_tokens: 300, total_tokens: 800, completion_tokens_details: CompletionTokensDetails(reasoning_tokens: 220))
        )
        let data = try! JSONEncoder().encode(envelope)
        let diagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(data, as: ModelUnifiedWire.self)
        #expect(diagnostic.promptTokens == 500)
        #expect(diagnostic.completionTokens == 300)
        #expect(diagnostic.totalTokens == 800)
        #expect(diagnostic.reasoningTokens == 220)
    }

    // MARK: - Call count remains one across the whole fixture battery (spot check)

    @Test func fixtureBattery_neverAffectsCallCount() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionEnvelope(content: "{\"analysis\":{},\"response\":{\"text\":\"hi\"}}", finishReason: "stop"))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let ctx = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        let result = provider.propose(transcript: "hi", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        #expect(result == nil)
        #expect(fake.sendCallCount == 1)
    }

    // MARK: - P2-M5V8.1-O.4 §3: per-stage request-byte and decode-diagnostic instrumentation

    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private func chatCompletionWithUsage(content: String, promptTokens: Int, completionTokens: Int, reasoningTokens: Int) -> Data {
        struct Details: Encodable { let reasoning_tokens: Int }
        struct Usage: Encodable { let prompt_tokens: Int; let completion_tokens: Int; let total_tokens: Int; let completion_tokens_details: Details }
        struct Msg: Encodable { let content: String }
        struct Choice: Encodable { let message: Msg; let finish_reason: String }
        struct Envelope: Encodable { let choices: [Choice]; let usage: Usage }
        let envelope = Envelope(
            choices: [Choice(message: Msg(content: content), finish_reason: "stop")],
            usage: Usage(prompt_tokens: promptTokens, completion_tokens: completionTokens, total_tokens: promptTokens + completionTokens, completion_tokens_details: Details(reasoning_tokens: reasoningTokens))
        )
        return try! JSONEncoder().encode(envelope)
    }

    @Test func diagnosticsRecorder_recordRequestBytes_routesToCorrectStageField() {
        let recorder = WakeDiagnosticsRecorder()
        recorder.recordRequestBytes(stage: "understand", 1234)
        recorder.recordRequestBytes(stage: "realize", 5678)
        recorder.recordRequestBytes(stage: "unified", 9999)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerRequestBytes == 1234)
        #expect(snapshot.lastRealizerRequestBytes == 5678)
        #expect(snapshot.lastUnifiedRequestBytes == 9999)
    }

    @Test func diagnosticsRecorder_recordStageDecodeDiagnostic_routesToCorrectStageField() {
        let recorder = WakeDiagnosticsRecorder()
        let diagnostic = ConversationModelRequestBuilder.diagnoseUnifiedDecode(chatCompletionWithUsage(content: "{\"text\":\"hi\"}", promptTokens: 100, completionTokens: 20, reasoningTokens: 5), as: ModelRealizationWire.self)
        recorder.recordStageDecodeDiagnostic(stage: "understand", diagnostic)
        recorder.recordStageDecodeDiagnostic(stage: "realize", diagnostic)
        #expect(recorder.snapshot().lastReasonerDecodeDiagnostic?.promptTokens == 100)
        #expect(recorder.snapshot().lastRealizerDecodeDiagnostic?.completionTokens == 20)
    }

    @Test func reasoner_recordsRequestBytesAndTokenUsage() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionWithUsage(content: "{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"}", promptTokens: 300, completionTokens: 15, reasoningTokens: 3))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let reasoner = ModelConversationReasoner(client: fake, config: config, diagnostics: recorder)
        _ = reasoner.understand(transcript: "hello", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let snapshot = recorder.snapshot()
        #expect((snapshot.lastReasonerRequestBytes ?? 0) > 0)
        #expect(snapshot.lastReasonerDecodeDiagnostic?.promptTokens == 300)
        #expect(snapshot.lastReasonerDecodeDiagnostic?.completionTokens == 15)
        #expect(snapshot.lastReasonerDecodeDiagnostic?.reasoningTokens == 3)
        #expect(snapshot.lastReasonerDecodeDiagnostic?.finishReason == "stop")
    }

    @Test func realizer_recordsRequestBytesAndTokenUsage() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionWithUsage(content: "{\"text\":\"Nice.\"}", promptTokens: 250, completionTokens: 8, reasoningTokens: 0))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config, diagnostics: recorder)
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let understanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let plan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: understanding, strategy: strategy, persona: .friday)
        _ = realizer.realize(context: ctx, understanding: understanding, plan: plan, recentTurns: [], avoiding: nil)
        let snapshot = recorder.snapshot()
        #expect((snapshot.lastRealizerRequestBytes ?? 0) > 0)
        #expect(snapshot.lastRealizerDecodeDiagnostic?.promptTokens == 250)
        #expect(snapshot.lastRealizerDecodeDiagnostic?.completionTokens == 8)
    }

    @Test func unifiedProvider_recordsRequestBytes() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionWithUsage(content: "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Got it.\"}}", promptTokens: 400, completionTokens: 25, reasoningTokens: 10))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "hi", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        let snapshot = recorder.snapshot()
        #expect((snapshot.lastUnifiedRequestBytes ?? 0) > 0)
        #expect(snapshot.lastUnifiedDecodeDiagnostic?.promptTokens == 400)
        #expect(snapshot.lastUnifiedDecodeDiagnostic?.completionTokens == 25)
        #expect(snapshot.lastUnifiedDecodeDiagnostic?.reasoningTokens == 10)
    }

    // MARK: - P2-M5V8.1-O.6 §5/§6 — history-cost instrumentation

    @Test func diagnosticsRecorder_recordHistoryStats_routesToCorrectStageField() {
        let recorder = WakeDiagnosticsRecorder()
        recorder.recordHistoryStats(stage: "understand", turnCount: 2, bytes: 111)
        recorder.recordHistoryStats(stage: "realize", turnCount: 3, bytes: 222)
        recorder.recordHistoryStats(stage: "unified", turnCount: 4, bytes: 333)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerHistoryTurnCount == 2 && snapshot.lastReasonerHistoryBytes == 111)
        #expect(snapshot.lastRealizerHistoryTurnCount == 3 && snapshot.lastRealizerHistoryBytes == 222)
        #expect(snapshot.lastUnifiedHistoryTurnCount == 4 && snapshot.lastUnifiedHistoryBytes == 333)
    }

    @Test func conversationModelLimits_historyStats_matchesTruncationRulesAndCap() {
        // 7 turns supplied, but `maxRecentTurns` (5) caps how many are
        // actually sent — the same truncation `buildRequest` itself
        // applies, mirrored here (not duplicated as an independent guess).
        let turns = (0..<7).map {
            ConversationTurn(taskID: "t\($0)", transcript: String(repeating: "x", count: 400), responseFamily: .genericSuccess, responseText: String(repeating: "y", count: 400), purpose: .success)
        }
        let stats = ConversationModelLimits.historyStats(for: turns)
        #expect(stats.turnCount == ConversationModelLimits.maxRecentTurns)
        // Each turn contributes exactly TWO truncated-to-300 fields (transcript + responseText).
        let expectedBytesPerTurn = ConversationModelLimits.maxCharactersPerHistoricalTurn * 2
        #expect(stats.bytes == expectedBytesPerTurn * ConversationModelLimits.maxRecentTurns)
    }

    @Test func conversationModelLimits_historyStats_emptyHistory_isZero() {
        let stats = ConversationModelLimits.historyStats(for: [])
        #expect(stats.turnCount == 0 && stats.bytes == 0)
    }

    @Test func unifiedProvider_recordsHistoryStats_forARealisticMultiTurnRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionWithUsage(content: "{\"reasoning\":{\"dialogueAct\":\"statement\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Got it.\"}}", promptTokens: 400, completionTokens: 25, reasoningTokens: 10))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let recentTurns = (0..<3).map { ConversationTurn(taskID: "r\($0)", transcript: "earlier turn", responseFamily: .genericSuccess, responseText: "earlier response", purpose: .success) }
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hi", recentTurns: recentTurns, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "hi", recentTurns: recentTurns, context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastUnifiedHistoryTurnCount == 3)
        #expect((snapshot.lastUnifiedHistoryBytes ?? 0) > 0)
    }

    // MARK: - P2-M5V8.1-O.6 §8 — `LatencyStatistics`'s new min/p25/p75 fields

    @Test func latencyStatistics_computesMinP25P75_additively() {
        let samples = (1...100).map { Double($0) }
        guard let stats = LatencyStatistics.compute(from: samples) else {
            Issue.record("expected statistics for a non-empty sample"); return
        }
        #expect(stats.min == 1)
        #expect(stats.p25 >= 20 && stats.p25 <= 30)
        #expect(stats.p75 >= 70 && stats.p75 <= 80)
        // Ordering invariant regardless of exact interpolation choice.
        #expect(stats.min <= stats.p25 && stats.p25 <= stats.median && stats.median <= stats.p75 && stats.p75 <= stats.p95 && stats.p95 <= stats.max)
    }

    // MARK: - P2-M5V8.1-O.4 §3/§6: static byte-size facts, pinned as a regression guard

    /// A REAL measurement (not a guess): the combined unified system
    /// prompt (7172 bytes) is essentially EQUAL TO — very slightly LARGER
    /// than — the sum of the two original prompts (3345+3819=7164) —
    /// confirming that MERGING the two prompts saved a round trip, but did
    /// NOT shrink the total instruction text the model has to read (SECTION
    /// C's new type guidance more than offset any dedup from merging).
    /// This directly informs the §5/§23 conclusion in the milestone
    /// report: prompt SIZE is not the dominant latency lever here — see
    /// that report for the full reasoning. Pinned here (a generous ±15%
    /// band around the measured sum, not an exact-byte pin, so routine
    /// wording edits don't spuriously fail this) so a future prompt edit
    /// that meaningfully changes this relationship is visible in review.
    @Test func unifiedPromptSize_isCloseToSumOfTheTwoOriginalPrompts_notMeaningfullySmaller() {
        let reasonerBytes = ConversationModelPersona.reasoningSystemPolicy.utf8.count
        let realizerBytes = ConversationModelPersona.realizationSystemPolicy.utf8.count
        let unifiedBytes = ConversationModelPersona.unifiedSystemPolicy.utf8.count
        let sum = reasonerBytes + realizerBytes
        #expect(Double(unifiedBytes) > Double(sum) * 0.85, "unified should be within ~15% of the naive sum, not dramatically smaller")
        // P2-M5V8.1-Q §8 — REVIEWED, deliberate growth: this pass narrowed
        // the "if asked to explain" instruction (a real, forensically-proven
        // production defect — a general-knowledge question was being
        // refused because this line told the model to use only
        // failureReason for EVERY explanation, not just a failed/unsupported
        // action) and gave `.briefExplanation` a second, more explicit
        // wording for the no-capability-needed case. Ceiling widened from
        // 1.15 to 1.25 to admit this specific, reviewed change — per this
        // test's own doc comment ("a future prompt edit that meaningfully
        // changes this relationship is visible in review"), this IS that
        // review, not a silent bypass.
        #expect(Double(unifiedBytes) < Double(sum) * 1.25, "unified should not have grown dramatically past the naive sum either")
    }
}
