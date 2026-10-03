import Testing
@testable import FridayCompanionKit
import Foundation

/// A network-free fake `ConversationModelRequesting` — every P2-M5V8 test
/// in this file uses this instead of `URLSessionConversationModelClient`,
/// so the whole suite runs instantly and deterministically with zero real
/// network access.
final class FakeConversationModelRequesting: ConversationModelRequesting, @unchecked Sendable {
    indirect enum Behavior {
        case success(Data)
        case failure(Error)
        /// Never calls `completion` at all — the caller's own bounded
        /// `overallDeadline` wait is what ends the call (a real timeout).
        case neverCompletes
        /// Calls `completion` after `seconds`, from a background queue —
        /// used to prove a LATE callback arriving after the caller
        /// already gave up never applies its result.
        case delayed(seconds: TimeInterval, then: Behavior)
    }

    var behavior: Behavior = .failure(ConversationModelError.notConfigured)
    private let lock = NSLock()
    private(set) var capturedRequestBodies: [Data] = []
    private(set) var sendCallCount = 0
    private(set) var cancelCallCount = 0

    func send(requestBody: Data, config: ConversationModelConfig, completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> ConversationModelCancelToken {
        lock.lock()
        sendCallCount += 1
        capturedRequestBodies.append(requestBody)
        let currentBehavior = behavior
        lock.unlock()
        deliver(currentBehavior, completion: completion)
        return ConversationModelCancelToken(cancelAction: { [weak self] in
            self?.lock.lock(); self?.cancelCallCount += 1; self?.lock.unlock()
        })
    }

    private func deliver(_ behavior: Behavior, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        switch behavior {
        case .success(let data): completion(.success(data))
        case .failure(let error): completion(.failure(error))
        case .neverCompletes: break
        case .delayed(let seconds, let inner):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.deliver(inner, completion: completion) }
        }
    }

    func lastRequestBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequestBodies.last
    }
}

@Suite struct ModelProviderTests {
    private let fastConfig = ConversationModelConfig(
        endpoint: URL(string: "https://example.invalid/v1/chat/completions"), apiKey: "test-key", modelName: "test-model",
        connectTimeout: 0.05, requestTimeout: 0.05, overallDeadline: 0.08
    )

    // MARK: - P2-M5V8.1 §2: modes, fail-closed on invalid

    @Test func mode_absent_defaultsToModelPreferredWithFallback() {
        #expect(ConversationProviderMode(environmentValue: nil) == .modelPreferredWithFallback)
        #expect(ConversationProviderMode(environmentValue: "") == .modelPreferredWithFallback)
    }

    @Test func mode_explicitValues_mapCorrectly() {
        #expect(ConversationProviderMode(environmentValue: "deterministic-only") == .deterministicOnly)
        #expect(ConversationProviderMode(environmentValue: "model-preferred-with-fallback") == .modelPreferredWithFallback)
        #expect(ConversationProviderMode(environmentValue: "model-evaluation") == .modelEvaluation)
    }

    @Test func mode_invalidGarbageValue_failsClosedToDeterministicOnly() {
        #expect(ConversationProviderMode(environmentValue: "banana") == .deterministicOnly)
        #expect(ConversationProviderMode(environmentValue: "MODEL_PREFERRED_TYPO") == .deterministicOnly)
    }

    @Test func config_fromEnvironment_readsNewModelModeVariableName() {
        let config = ConversationModelConfig.fromEnvironment([
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://example.invalid",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "key",
            "FRIDAY_CONVERSATION_MODEL_MODE": "model-evaluation",
        ])
        #expect(config.mode == .modelEvaluation)
    }

    // MARK: - P2-M5V8.1 §4: HTTPS / localhost rule

    @Test func endpoint_httpsRemote_allowed() {
        #expect(ConversationModelConfig.isEndpointAllowed(URL(string: "https://api.example.com/v1/chat/completions")!))
    }

    @Test func endpoint_httpRemote_rejected() {
        #expect(!ConversationModelConfig.isEndpointAllowed(URL(string: "http://api.example.com/v1/chat/completions")!))
    }

    @Test func endpoint_httpLocalhost_allowed() {
        #expect(ConversationModelConfig.isEndpointAllowed(URL(string: "http://localhost:11434/v1/chat/completions")!))
        #expect(ConversationModelConfig.isEndpointAllowed(URL(string: "http://127.0.0.1:11434/v1/chat/completions")!))
    }

    @Test func endpoint_otherScheme_rejected() {
        #expect(!ConversationModelConfig.isEndpointAllowed(URL(string: "ftp://example.com")!))
    }

    @Test func config_isConfigured_falseWhenEndpointIsDisallowedPlaintextRemote() {
        let config = ConversationModelConfig(endpoint: URL(string: "http://not-localhost.example.com"), apiKey: "key", modelName: "m")
        #expect(!config.isConfigured, "an insecure remote endpoint must fail closed to 'not configured', never attempt the connection")
    }

    @Test func reasoner_insecureEndpoint_neverAttemptsNetwork() {
        let fake = FakeConversationModelRequesting()
        let insecureConfig = ConversationModelConfig(endpoint: URL(string: "http://not-localhost.example.com")!, apiKey: "key", modelName: "m")
        let reasoner = ModelConversationReasoner(client: fake, config: insecureConfig)
        let result = reasoner.understand(transcript: "hello", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
        #expect(fake.sendCallCount == 0)
    }

    // MARK: - P2-M5V8.1 §3: provider readiness

    @Test func readiness_deterministicOnlyMode_reportsNotConfigured_neverAttemptsNetwork() {
        let fake = FakeConversationModelRequesting()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid"), apiKey: "key", modelName: "m", mode: .deterministicOnly)
        let report = ProviderReadinessChecker.check(config: config, client: fake)
        #expect(!report.providerConfigured)
        #expect(fake.sendCallCount == 0)
    }

    @Test func readiness_missingApiKey_reportsNotConfigured() {
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid"), apiKey: nil, modelName: "m")
        let report = ProviderReadinessChecker.check(config: config, client: FakeConversationModelRequesting())
        #expect(!report.providerConfigured)
        #expect(report.failureReason?.contains("API key") == true)
    }

    @Test func readiness_missingModelName_reportsNotConfigured() {
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid"), apiKey: "key", modelName: "")
        let report = ProviderReadinessChecker.check(config: config, client: FakeConversationModelRequesting())
        #expect(!report.providerConfigured)
    }

    @Test func readiness_insecureEndpoint_reportsNotConfigured_neverAttemptsNetwork() {
        let fake = FakeConversationModelRequesting()
        let config = ConversationModelConfig(endpoint: URL(string: "http://not-localhost.example.com")!, apiKey: "key", modelName: "m")
        let report = ProviderReadinessChecker.check(config: config, client: fake)
        #expect(!report.providerConfigured)
        #expect(fake.sendCallCount == 0)
    }

    @Test func readiness_validResponse_reportsSchemaCompatible_withMeasuredLatency() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: "{\"ok\":true}"))
        let report = ProviderReadinessChecker.check(config: fastConfig, client: fake)
        #expect(report.providerConfigured)
        #expect(report.schemaCompatible)
        #expect(report.requestLatencyMs != nil)
        #expect(report.endpointHost == fastConfig.endpoint?.host)
    }

    @Test func readiness_malformedResponse_reportsSchemaIncompatible() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("not json".data(using: .utf8)!)
        let report = ProviderReadinessChecker.check(config: fastConfig, client: fake)
        #expect(report.providerConfigured)
        #expect(!report.schemaCompatible)
    }

    @Test func readiness_timeout_reportsFailure_withinBoundedTime() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .neverCompletes
        let start = Date()
        let report = ProviderReadinessChecker.check(config: fastConfig, client: fake)
        #expect(!report.schemaCompatible)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test func readiness_neverSendsRealConversationContent() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        _ = ProviderReadinessChecker.check(config: fastConfig, client: fake)
        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("expected a request body")
            return
        }
        #expect(!bodyString.contains("transcript"))
        #expect(!bodyString.contains("conversationContext"))
    }

    // MARK: - P2-M5V8.1 §16: latency statistics

    @Test func latencyStatistics_emptySamples_returnsNil() {
        #expect(LatencyStatistics.compute(from: []) == nil)
    }

    @Test func latencyStatistics_computesMedianP95Max() {
        let samples = (1...100).map { Double($0) } // 1...100
        guard let stats = LatencyStatistics.compute(from: samples) else {
            Issue.record("expected statistics for a non-empty sample")
            return
        }
        #expect(stats.max == 100)
        #expect(stats.sampleCount == 100)
        #expect(stats.p95 >= 90 && stats.p95 <= 100)
        #expect(stats.median >= 45 && stats.median <= 55)
    }

    // MARK: - P2-M5V8.1 §19: differentiated temperature

    @Test func reasoningAndRealizationTemperatures_areDifferentByDefault() {
        let config = ConversationModelConfig.unconfigured
        #expect(config.reasoningTemperature != config.realizationTemperature)
        #expect(config.reasoningTemperature < config.realizationTemperature, "reasoning should be more conservative than realization")
    }

    @Test func requestBuilder_sendsTheConfiguredTemperature() {
        struct Probe: Decodable { let temperature: Double }
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "x", userPayloadJSON: "{}", modelName: "m", temperature: 0.15)
        guard let body, let probe = try? JSONDecoder().decode(Probe.self, from: body) else {
            Issue.record("expected a well-formed request body")
            return
        }
        #expect(probe.temperature == 0.15)
    }

    // MARK: - P2-M5V8.1 §20: token/context bounds

    @Test func requestBuilder_oversizedPayload_rejectedRatherThanSent() {
        let huge = String(repeating: "a", count: ConversationModelLimits.maxSerializedContextBytes * 2)
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "x", userPayloadJSON: huge, modelName: "m", temperature: 0.1)
        #expect(body == nil, "an oversized payload must never be sent — the caller falls back safely")
    }

    @Test func reasonerRequest_truncatesOversizedTranscript() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let hugeTranscript = String(repeating: "word ", count: 1000)
        _ = reasoner.understand(transcript: hugeTranscript, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("expected a request body")
            return
        }
        #expect(bodyString.count < hugeTranscript.count, "the transcript must be bounded, not sent verbatim at unlimited length")
    }

    @Test func reasonerRequest_boundsRecentTurnCount() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let manyTurns = (0..<50).map { ConversationTurn(taskID: "t\($0)", transcript: "turn \($0)", responseFamily: .genericSuccess, responseText: "Done.", purpose: .success) }
        _ = reasoner.understand(transcript: "test", recentTurns: manyTurns, context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], let userContent = messages.last?["content"] as? String,
              let userData = userContent.data(using: .utf8), let userJSON = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let conversationContext = userJSON["conversationContext"] as? [[String: Any]] else {
            Issue.record("expected a well-formed request with conversationContext")
            return
        }
        #expect(conversationContext.count <= ConversationModelLimits.maxRecentTurns)
    }

    // MARK: - Configuration (§3/§4/§32)

    @Test func config_notConfigured_whenEnvironmentEmpty() {
        let config = ConversationModelConfig.fromEnvironment([:])
        #expect(!config.isConfigured)
    }

    @Test func config_notConfigured_whenOnlyEndpointPresent() {
        let config = ConversationModelConfig.fromEnvironment(["FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://example.invalid"])
        #expect(!config.isConfigured)
    }

    @Test func config_notConfigured_whenModeIsDeterministicOnly_evenWithFullCredentials() {
        let config = ConversationModelConfig.fromEnvironment([
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://example.invalid",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "key",
            "FRIDAY_CONVERSATION_PROVIDER_MODE": "deterministic-only",
        ])
        #expect(!config.isConfigured)
    }

    @Test func config_configured_whenEndpointAndKeyBothPresent() {
        let config = ConversationModelConfig.fromEnvironment([
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://example.invalid",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "key",
        ])
        #expect(config.isConfigured)
    }

    @Test func config_unconfiguredDefault_neverAccidentallyConfigured() {
        #expect(!ConversationModelConfig.unconfigured.isConfigured)
        #expect(ConversationModelConfig.unconfigured.endpoint == nil)
        #expect(ConversationModelConfig.unconfigured.apiKey == nil)
    }

    // MARK: - ModelConversationReasoner: configuration gating, never attempts network when unconfigured

    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "t1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false
        )
    }

    @Test func reasoner_notConfigured_returnsMinimal_neverAttemptsNetwork() {
        let fake = FakeConversationModelRequesting()
        let reasoner = ModelConversationReasoner(client: fake, config: .unconfigured)
        let result = reasoner.understand(transcript: "hello", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
        #expect(fake.sendCallCount == 0)
    }

    // MARK: - Success path, structured decoding

    private func chatCompletionData(content: String) -> Data {
        let json = """
        {"choices":[{"message":{"content":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}
        """
        return json.data(using: .utf8)!
    }

    @Test func reasoner_validStructuredResponse_decodesSuccessfully() {
        let fake = FakeConversationModelRequesting()
        let wireJSON = """
        {"dialogueAct":"personalUpdate","interactionMode":"conversational","userGoal":null,"topic":"bug fix","continuationReference":false,"correctionTarget":null,"explicitConstraints":[],"recommendedSocialRegister":"casualFriendly","humorSuitability":0.4,"followUpNeed":true,"uncertainty":0.2}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result.dialogueAct == .personalUpdate)
        #expect(result.interactionMode == .conversational)
        #expect(result.topic == "bug fix")
        #expect(result.socialRegisterRecommendation == .casualFriendly)
        #expect(result.uncertainty == 0.2)
    }

    @Test func reasoner_unknownInteractionModeEnum_rejectsWholeResponse() {
        // InteractionMode has NO .unknown case -> an illegal value must
        // reject the ENTIRE response, not silently default.
        let fake = FakeConversationModelRequesting()
        let wireJSON = """
        {"dialogueAct":"command","interactionMode":"somethingIllegal","humorSuitability":0.1,"uncertainty":0.1}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
    }

    @Test func reasoner_unknownDialogueActEnum_safelyMapsToUnknownCase() {
        // DialogueAct DOES model .unknown -> an illegal value degrades
        // safely rather than rejecting the whole response.
        let fake = FakeConversationModelRequesting()
        let wireJSON = """
        {"dialogueAct":"somethingNeverSeenBefore","interactionMode":"actionRequest","humorSuitability":0.1,"uncertainty":0.1}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result.dialogueAct == .unknown)
        #expect(result.interactionMode == .actionRequest)
    }

    @Test func reasoner_outOfRangeNumericValues_clampedNotRejected() {
        let fake = FakeConversationModelRequesting()
        let wireJSON = """
        {"dialogueAct":"command","interactionMode":"actionRequest","humorSuitability":99.0,"uncertainty":-5.0}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result.humorSuitability == 1.0)
        #expect(result.uncertainty == 0.0)
    }

    @Test func reasoner_oversizedTopicString_truncated() {
        let fake = FakeConversationModelRequesting()
        let hugeString = String(repeating: "a", count: 5000)
        let wireJSON = """
        {"dialogueAct":"statement","interactionMode":"actionRequest","topic":"\(hugeString)","humorSuitability":0,"uncertainty":0.5}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect((result.topic?.count ?? 0) <= ConversationModelSchema.maxStringLength)
    }

    @Test func reasoner_oversizedConstraintArray_truncatedToLimit() {
        let fake = FakeConversationModelRequesting()
        let manyConstraints = Array(repeating: "\"doNotAct\"", count: 50).joined(separator: ",")
        let wireJSON = """
        {"dialogueAct":"prohibition","interactionMode":"constraint","explicitConstraints":[\(manyConstraints)],"humorSuitability":0,"uncertainty":0.3}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result.explicitConstraints.count <= ConversationModelSchema.maxArrayItems)
    }

    @Test func reasoner_malformedJSON_returnsMinimal() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("not valid json at all { { {".data(using: .utf8)!)
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
    }

    @Test func reasoner_emptyResponse_returnsMinimal() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(Data())
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
    }

    @Test func reasoner_networkError_returnsMinimal() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(URLError(.notConnectedToInternet))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal)
    }

    @Test func reasoner_timeout_returnsMinimal_withinBoundedTime() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .neverCompletes
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        let start = Date()
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == .minimal)
        #expect(elapsed < 1.0, "must never hang — bounded by config.overallDeadline (0.08s here)")
    }

    @Test func reasoner_lateCallbackAfterTimeout_neverAppliesStaleResult() {
        let fake = FakeConversationModelRequesting()
        let validJSON = """
        {"dialogueAct":"command","interactionMode":"actionRequest","humorSuitability":0,"uncertainty":0.1}
        """
        fake.behavior = .delayed(seconds: 0.3, then: .success(chatCompletionData(content: validJSON)))
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig) // overallDeadline 0.08s
        let start = Date()
        let result = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == .minimal, "the call must give up and use the safe default well before the late (0.3s) response arrives")
        #expect(elapsed < 0.25, "must return around the 0.08s deadline, not wait for the 0.3s-delayed callback")
    }

    // MARK: - Cancellation (§20/§21)

    @Test func reasoner_cancelOutstanding_callableWithoutCrashing_whenNothingInFlight() {
        let reasoner = ModelConversationReasoner(client: FakeConversationModelRequesting(), config: .unconfigured)
        reasoner.cancelOutstanding() // must be a harmless no-op
    }

    // MARK: - Schema never carries authoritative fields (§5/§7, structural)

    @Test func modelUnderstandingWire_hasNoAuthoritativeExecutionFields() {
        // Structural proof the model is never even ASKED for these —
        // Mirror-based, matching this codebase's own sec001/sec011-style
        // structural security tests.
        let wire = ModelUnderstandingWire(
            dialogueAct: "command", interactionMode: "actionRequest", userGoal: nil, topic: nil,
            continuationReference: nil, correctionTarget: nil, explicitConstraints: nil,
            recommendedSocialRegister: nil, humorSuitability: nil, followUpNeed: nil, uncertainty: nil
        )
        let fieldNames = Set(Mirror(reflecting: wire).children.compactMap(\.label))
        for forbidden in ["actionExecutionState", "failureReason", "retryability", "wasSuccess", "authorized", "permission", "identity"] {
            #expect(!fieldNames.contains(forbidden), "the model's structured schema must never even contain an authoritative execution field")
        }
    }

    // MARK: - ModelNaturalResponseRealizer

    private func minimalPlan(socialRegister: SocialRegister = .friendlyNeutral, humorAllowance: Bool = false) -> NaturalResponsePlan {
        NaturalResponsePlan(responseGoal: .success, socialRegister: socialRegister, warmth: 0.8, directness: 0.7, humorAllowance: humorAllowance, humorStrength: humorAllowance ? 0.3 : 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
    }

    @Test func realizer_notConfigured_returnsNil_neverAttemptsNetwork() {
        let fake = FakeConversationModelRequesting()
        let realizer = ModelNaturalResponseRealizer(client: fake, config: .unconfigured)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
        #expect(fake.sendCallCount == 0)
    }

    @Test func realizer_validResponse_extractsText() {
        let fake = FakeConversationModelRequesting()
        let wireJSON = """
        {"text":"Nice. What ended up causing it?","responseGoal":"success","socialRegister":"casualFriendly","humorUsed":false,"prosodyIntent":"casual"}
        """
        fake.behavior = .success(chatCompletionData(content: wireJSON))
        let realizer = ModelNaturalResponseRealizer(client: fake, config: fastConfig)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == "Nice. What ended up causing it?")
    }

    @Test func realizer_emptyText_returnsNil() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: "{\"text\":\"\"}"))
        let realizer = ModelNaturalResponseRealizer(client: fake, config: fastConfig)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
    }

    @Test func realizer_oversizedText_returnsNil() {
        let fake = FakeConversationModelRequesting()
        let huge = String(repeating: "a", count: DeterministicResponsePresenter.maxSpokenLength * 2)
        fake.behavior = .success(chatCompletionData(content: "{\"text\":\"\(huge)\"}"))
        let realizer = ModelNaturalResponseRealizer(client: fake, config: fastConfig)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
    }

    @Test func realizer_malformedJSON_returnsNil() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("garbage".data(using: .utf8)!)
        let realizer = ModelNaturalResponseRealizer(client: fake, config: fastConfig)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
    }

    @Test func realizer_timeout_returnsNil_withinBoundedTime() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .neverCompletes
        let realizer = ModelNaturalResponseRealizer(client: fake, config: fastConfig)
        let start = Date()
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // MARK: - Privacy (§22): request payload structural inspection

    @Test func requestPayload_containsOnlyExpectedTopLevelFields_forUnderstand() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // don't care about the response; just inspect the outgoing request
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        _ = reasoner.understand(transcript: "some transcript", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body")
            return
        }
        #expect(json["model"] != nil)
        #expect(json["messages"] != nil)
        // The system message must never contain the user's transcript verbatim (§17: structural separation).
        if let messages = json["messages"] as? [[String: Any]], let systemContent = messages.first?["content"] as? String {
            #expect(!systemContent.contains("some transcript"))
        }
    }

    @Test func requestPayload_neverContainsAPIKey() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let reasoner = ModelConversationReasoner(client: fake, config: fastConfig)
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("expected a well-formed outgoing request body")
            return
        }
        #expect(!bodyString.contains(fastConfig.apiKey!), "the API key belongs only in the Authorization header, never the JSON body")
    }

    // MARK: - Full presenter integration via .withModelProvider (§2/§4/§32)

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    @Test func presenter_withModelProvider_notConfigured_behavesIdenticallyToPlainDeterministic() {
        let modelPresenter = ConversationalResponsePresenter.withModelProvider(config: .unconfigured, client: FakeConversationModelRequesting())
        let plainPresenter = ConversationalResponsePresenter()
        for (outcome, text) in [("SUCCESS", "System status retrieved successfully."), ("EXECUTION_FAILED", "The action could not be completed.")] {
            let a = modelPresenter.response(for: .success(outcomeResult(outcome: outcome, text: text, taskID: "cmp-\(outcome)")))
            let b = plainPresenter.response(for: .success(outcomeResult(outcome: outcome, text: text, taskID: "cmp-\(outcome)")))
            #expect(a.text == b.text)
        }
    }

    @Test func presenter_withModelProvider_hallucinatingModel_stillRecomputesAuthorityLocally() {
        // The two-stage model contract structurally CANNOT carry
        // actionExecutionState/failureReason/retryability (they're not
        // even fields in ModelUnderstandingWire) — this proves the
        // end-to-end result for a genuine EXECUTION_FAILED stays
        // truthful even with a "confident," fully-configured model path.
        let understandFake = FakeConversationModelRequesting()
        understandFake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"command","interactionMode":"actionRequest","humorSuitability":0,"uncertainty":0.05}
        """))
        let realizeFake = FakeConversationModelRequesting()
        realizeFake.behavior = .success(chatCompletionData(content: """
        {"text":"That didn't go through."}
        """))
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: understandFake, config: fastConfig), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizeFake, config: fastConfig), secondary: DeterministicNaturalResponseRealizer())
        )
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "model-1")))
        #expect(!response.wasSuccess)
        #expect(!response.text.localizedCaseInsensitiveContains("try again"), "retryability was never even sent to or returned by the model — still correctly .unknown")
    }

    // MARK: - §26: explicit seriousness immediately suppresses humor

    @Test func explicitSeriousness_immediatelySuppressesHumor_evenWithoutExplicitUrgency() {
        let reasoner = DeterministicConversationReasoner()
        let playful = reasoner.understand(transcript: "Can you launch a spaceship?", recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(playful.humorAppropriateness)
        let serious = reasoner.understand(transcript: "I'm serious.", recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(!serious.humorAppropriateness)
        #expect(!serious.explicitUrgency, "seriousness and urgency are different dimensions — this must not also claim urgency")
    }

    @Test func scenario_lowStakesPlayfulThenSerious_endToEnd_humorStopsOnSecondTurn() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "serious-1")),
            transcript: "Can you launch a spaceship?", acoustics: .unavailable, explicitUserStatements: []
        )
        let secondTurn = presenter.response(
            for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "serious-2")),
            transcript: "I'm serious.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(DeterministicResponseRealizer.unsupportedIntentVariants.contains(secondTurn.text), "humor must be fully gone — only the flat, non-humorous variant set remains reachable")
    }

    @Test func presenter_withModelProvider_modelClassifiesConstraint_actionExecutionStateStillForcedNotRequested_regardlessOfAttachedOutcome() {
        // Simulates a real model UNDERSTAND response correctly
        // recognizing a constraint utterance (interactionMode is
        // legitimately reasoner-derived, §8 of P2-M5V7) — proves the
        // presenter still forces `.notRequested`/never claims success
        // through the FULL model-integration path (not just the generic
        // hallucinating-reasoner fake already covered in
        // `ArchitecturalInvariantsTests`), using a synthetic SUCCESS
        // outcome exactly like the mission's own "harness supplies a
        // synthetic result" scenario.
        let understandFake = FakeConversationModelRequesting()
        understandFake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"prohibition","interactionMode":"constraint","explicitConstraints":["doNotModify"],"humorSuitability":0,"uncertainty":0.1}
        """))
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: understandFake, config: fastConfig), secondary: DeterministicConversationReasoner()),
            naturalRealizer: nil
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "model-constraint-1")),
            transcript: "This is important. Don't change anything yet.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.wasSuccess)
        #expect(!response.text.contains("Done"))
        #expect(response.text == "Got it. I won't change anything.")
    }

    // MARK: - P2-M5V8.1-HW §9: OpenAI transport compatibility (token-limit encoding)
    //
    // Root cause, proven live: OpenAI's newer models (e.g. `gpt-5.6-sol`)
    // reject the legacy `max_tokens` field with HTTP 400 `unsupported_parameter`
    // and require `max_completion_tokens` instead. `ConversationModelRequestBuilder.encode`
    // never sent EITHER field before this pass (confirmed via source read,
    // not guessed) — these tests prove the new, explicit, provider-
    // configured encoding, never a model-name string hack.

    private func openAIStyleConfig(
        tokenLimitEncoding: CompletionTokenLimitEncoding, apiKey: String = "test-key",
        temperatureEncoding: TemperatureEncoding = .explicit
    ) -> ConversationModelConfig {
        ConversationModelConfig(
            endpoint: fastConfig.endpoint, apiKey: apiKey, modelName: "gpt-5.6-sol",
            connectTimeout: fastConfig.connectTimeout, requestTimeout: fastConfig.requestTimeout, overallDeadline: fastConfig.overallDeadline,
            tokenLimitEncoding: tokenLimitEncoding, temperatureEncoding: temperatureEncoding
        )
    }

    @Test func tokenLimitEncoding_environmentValue_mapsCorrectly() {
        #expect(CompletionTokenLimitEncoding(environmentValue: nil) == .none)
        #expect(CompletionTokenLimitEncoding(environmentValue: "") == .none)
        #expect(CompletionTokenLimitEncoding(environmentValue: "max_tokens") == .maxTokens)
        #expect(CompletionTokenLimitEncoding(environmentValue: "max_completion_tokens") == .maxCompletionTokens)
        #expect(CompletionTokenLimitEncoding(environmentValue: "banana") == .none, "an unrecognized value must fail closed to .none, never silently pick an encoding")
    }

    // A. OpenAI-style capability emits max_completion_tokens.
    @Test func tokenLimitEncoding_maxCompletionTokens_emitsThatField() {
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "gpt-5.6-sol", temperature: 0.1, tokenLimitEncoding: .maxCompletionTokens)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(json["max_completion_tokens"] as? Int == ConversationModelLimits.maxCompletionTokens)
    }

    // B. ...and it does NOT emit max_tokens.
    @Test func tokenLimitEncoding_maxCompletionTokens_neverAlsoEmitsLegacyMaxTokens() {
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "gpt-5.6-sol", temperature: 0.1, tokenLimitEncoding: .maxCompletionTokens)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(json["max_tokens"] == nil, "the exact field OpenAI's newer models reject with HTTP 400 unsupported_parameter must never be sent")
    }

    // C. legacy/other capability can still emit max_tokens.
    @Test func tokenLimitEncoding_maxTokens_stillSupportedForOtherProviders() {
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "some-groq-or-legacy-model", temperature: 0.1, tokenLimitEncoding: .maxTokens)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(json["max_tokens"] as? Int == ConversationModelLimits.maxCompletionTokens)
        #expect(json["max_completion_tokens"] == nil)
    }

    // D. neither path ever emits both simultaneously (including .none, which emits neither).
    @Test func tokenLimitEncoding_neverEmitsBothFieldsSimultaneously_forAnyEncoding() {
        for encoding: CompletionTokenLimitEncoding in [.none, .maxTokens, .maxCompletionTokens] {
            let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "m", temperature: 0.1, tokenLimitEncoding: encoding)
            guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Issue.record("expected a well-formed request body for \(encoding)"); continue
            }
            let hasMaxTokens = json["max_tokens"] != nil
            let hasMaxCompletionTokens = json["max_completion_tokens"] != nil
            #expect(!(hasMaxTokens && hasMaxCompletionTokens), "\(encoding) must never emit both fields at once")
            if encoding == .none {
                #expect(!hasMaxTokens && !hasMaxCompletionTokens, ".none must emit neither field — today's pre-existing, still-default behavior")
            }
        }
    }

    // E. the real reasoner's outgoing request uses the configured encoding.
    @Test func reasoner_usesConfiguredTokenLimitEncoding_inOutgoingRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // don't care about the response; just inspect the outgoing request
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens))
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["max_completion_tokens"] != nil)
        #expect(json["max_tokens"] == nil)
    }

    // F. the real realizer's outgoing request uses the configured encoding.
    @Test func realizer_usesConfiguredTokenLimitEncoding_inOutgoingRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let realizer = ModelNaturalResponseRealizer(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens))
        _ = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["max_completion_tokens"] != nil)
        #expect(json["max_tokens"] == nil)
    }

    // G. API key remains header-only, never in the body, even with the new fields present.
    @Test func requestWithTokenLimitEncoding_apiKeyRemainsHeaderOnly_neverInBody() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let secretKey = "sk-test-should-never-appear-in-body"
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, apiKey: secretKey))
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(!bodyString.contains(secretKey))
    }

    // H. request diagnostics never expose the API key, including the new
    // classified-failure-detail path added for readiness reporting.
    @Test func diagnosticsSnapshot_neverExposesAPIKey_evenWithClassifiedFailureDetail() {
        let fake = FakeConversationModelRequesting()
        let secretKey = "sk-test-should-never-appear-in-diagnostics"
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: "{\"error\":{\"message\":\"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.\",\"code\":\"unsupported_parameter\"}}"))
        let recorder = WakeDiagnosticsRecorder()
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxTokens, apiKey: secretKey), diagnostics: recorder)
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let rendered = WakeDiagnosticsFormatter.render(recorder.snapshot(), includeTranscript: true)
        #expect(!rendered.contains(secretKey))
    }

    // MARK: - P2-M5V8.1-HW (sampling-capability fix) §10: temperature encoding
    //
    // Root cause, proven live: the SAME provider (`gpt-5.6-sol`) that
    // required `max_completion_tokens` ALSO rejects any explicit,
    // non-default `temperature` value: "Unsupported value: 'temperature'
    // does not support 0 with this model. Only the default (1) value is
    // supported." `TemperatureEncoding.omit` lets FRIDAY send no
    // `temperature` field at all, while `reasoningTemperature`/
    // `realizationTemperature` remain fully intact as logical settings
    // (§5) for providers that DO support explicit sampling.

    @Test func temperatureEncoding_environmentValue_mapsCorrectly() {
        #expect(TemperatureEncoding(environmentValue: nil) == .explicit)
        #expect(TemperatureEncoding(environmentValue: "") == .explicit)
        #expect(TemperatureEncoding(environmentValue: "omit") == .omit)
        #expect(TemperatureEncoding(environmentValue: "explicit") == .explicit)
    }

    // H. invalid temperature-encoding config fails safely (closed to the
    // pre-existing "always send it" behavior — never silently starts
    // omitting a field every existing deployment/test relies on).
    @Test func temperatureEncoding_invalidGarbageValue_failsClosedToExplicit() {
        #expect(TemperatureEncoding(environmentValue: "banana") == .explicit)
        #expect(TemperatureEncoding(environmentValue: "OMIT_TYPO") == .explicit)
    }

    @Test func config_fromEnvironment_readsTemperatureEncodingVariable() {
        let config = ConversationModelConfig.fromEnvironment([
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://example.invalid",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "key",
            "FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING": "omit",
        ])
        #expect(config.temperatureEncoding == .omit)
    }

    // A. temperatureEncoding=.omit → no "temperature" key exists.
    @Test func temperatureEncoding_omit_emitsNoTemperatureField() {
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "gpt-5.6-sol", temperature: 0.1, temperatureEncoding: .omit)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(json["temperature"] == nil, "gpt-5.6-sol rejects ANY explicit temperature value — the field must be entirely absent, not null")
    }

    // B. temperatureEncoding=.explicit → the correct configured temperature exists.
    @Test func temperatureEncoding_explicit_emitsConfiguredTemperature() {
        let body = ConversationModelRequestBuilder.encode(systemPolicy: "sys", userPayloadJSON: "{}", modelName: "m", temperature: 0.37, temperatureEncoding: .explicit)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(json["temperature"] as? Double == 0.37)
    }

    // C. readiness uses .omit when configured — and never encodes a
    // probe-specific temperature independent of production configuration.
    @Test func readiness_usesConfiguredTemperatureEncoding_omit_inSyntheticProbeRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        _ = ProviderReadinessChecker.check(config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit), client: fake)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed synthetic probe request body"); return
        }
        #expect(json["temperature"] == nil, "readiness must probe with the SAME temperature encoding the real reasoner/realizer will use — no independent probe-specific shape")
    }

    // D. reasoner uses .omit when configured.
    @Test func reasoner_usesConfiguredTemperatureEncoding_omit_inOutgoingRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit))
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["temperature"] == nil)
        #expect(json["max_completion_tokens"] != nil, "the token-limit fix from the previous pass must remain intact alongside this one")
    }

    // E. realizer uses .omit when configured.
    @Test func realizer_usesConfiguredTemperatureEncoding_omit_inOutgoingRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let realizer = ModelNaturalResponseRealizer(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit))
        _ = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["temperature"] == nil)
    }

    // F. explicit reasoning temperature still supports 0.1 (logical setting preserved, §5).
    @Test func reasoner_explicitTemperatureEncoding_stillSendsLogicalReasoningTemperature() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = openAIStyleConfig(tokenLimitEncoding: .none, temperatureEncoding: .explicit)
        #expect(config.reasoningTemperature == 0.1)
        let reasoner = ModelConversationReasoner(client: fake, config: config)
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["temperature"] as? Double == 0.1)
    }

    // G. explicit realization temperature still supports 0.4 (logical setting preserved, §5).
    @Test func realizer_explicitTemperatureEncoding_stillSendsLogicalRealizationTemperature() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = openAIStyleConfig(tokenLimitEncoding: .none, temperatureEncoding: .explicit)
        #expect(config.realizationTemperature == 0.4)
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config)
        _ = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["temperature"] as? Double == 0.4)
    }

    // I. API key remains header-only even with temperature omitted.
    @Test func requestWithTemperatureOmitted_apiKeyRemainsHeaderOnly_neverInBody() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let secretKey = "sk-test-should-never-appear-in-body-omit-case"
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, apiKey: secretKey, temperatureEncoding: .omit))
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        guard let body = fake.lastRequestBody(), let bodyString = String(data: body, encoding: .utf8) else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(!bodyString.contains(secretKey))
    }

    // J. no secret diagnostics regression with the new live provider-error
    // shape this pass was built to handle (an "unsupported value" temperature
    // rejection, distinct from the prior pass's "unsupported parameter"
    // token-limit rejection).
    @Test func diagnosticsSnapshot_neverExposesAPIKey_forTemperatureRejectionErrorShape() {
        let fake = FakeConversationModelRequesting()
        let secretKey = "sk-test-should-never-appear-temp-rejection"
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: "{\"error\":{\"message\":\"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported.\",\"param\":\"temperature\",\"code\":\"unsupported_value\"}}"))
        let recorder = WakeDiagnosticsRecorder()
        let reasoner = ModelConversationReasoner(client: fake, config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, apiKey: secretKey, temperatureEncoding: .explicit), diagnostics: recorder)
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let rendered = WakeDiagnosticsFormatter.render(recorder.snapshot(), includeTranscript: true)
        #expect(!rendered.contains(secretKey))
    }

    // §8/§9 — the readiness path surfaces THIS specific real error shape
    // precisely (proving the classification mechanism from the previous
    // pass generalizes to a different field/error code, not just the
    // token-limit one it was built for).
    @Test func readiness_surfacesActualProviderErrorBody_whenTemperatureIsRejected() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: "{\"error\":{\"message\":\"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported.\",\"param\":\"temperature\",\"code\":\"unsupported_value\"}}"))
        let report = ProviderReadinessChecker.check(config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .explicit), client: fake)
        #expect(!report.schemaCompatible)
        #expect(report.failureReason?.contains("temperature") == true)
        #expect(report.failureReason?.contains("unsupported_value") == true)
    }

    // Never emits both a temperature field AND omits it inconsistently
    // across the two real stages when both are configured identically —
    // structural proof the encoding is applied uniformly.
    @Test func temperatureEncoding_appliesUniformly_acrossReasonerAndRealizer() {
        let reasonerFake = FakeConversationModelRequesting()
        reasonerFake.behavior = .failure(ConversationModelError.emptyResponse)
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit)

        let reasoner = ModelConversationReasoner(client: reasonerFake, config: config)
        _ = reasoner.understand(transcript: "test", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let realizer = ModelNaturalResponseRealizer(client: realizerFake, config: config)
        _ = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)

        for fake in [reasonerFake, realizerFake] {
            guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Issue.record("expected a well-formed outgoing request body"); continue
            }
            #expect(json["temperature"] == nil)
        }
    }

    // §6/§10/§13: readiness now surfaces the ACTUAL sanitized provider
    // error (e.g. OpenAI's own unsupported_parameter message) instead of
    // the previous, always-vague "no response" bucket — and the synthetic
    // probe itself uses the SAME configured encoding the real reasoner/
    // realizer would send, so this exact incompatibility is caught before
    // either real stage wastes a call on it.
    @Test func readiness_surfacesActualProviderErrorBody_whenTokenParameterIsRejected() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: "{\"error\":{\"message\":\"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.\",\"param\":\"max_tokens\",\"code\":\"unsupported_parameter\"}}"))
        let report = ProviderReadinessChecker.check(config: openAIStyleConfig(tokenLimitEncoding: .maxTokens), client: fake)
        #expect(!report.schemaCompatible)
        #expect(report.failureReason?.contains("unsupported_parameter") == true, "the owner must see the ACTUAL classification, not a vague bucket")
        #expect(report.failureReason?.contains("max_tokens") == true)
    }

    @Test func readiness_usesConfiguredTokenLimitEncoding_inSyntheticProbeRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        _ = ProviderReadinessChecker.check(config: openAIStyleConfig(tokenLimitEncoding: .maxCompletionTokens), client: fake)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed synthetic probe request body"); return
        }
        #expect(json["max_completion_tokens"] != nil, "readiness must probe with the SAME encoding the real reasoner/realizer will use")
        #expect(json["max_tokens"] == nil)
    }
}
