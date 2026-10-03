import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-PROD-BOOTSTRAP-R2.2 — real owner evidence: a genuinely-configured
/// OpenAI GPT-5.x conversation credential got HTTP 400 ("Unsupported
/// value: 'temperature' does not support 0.1 with this model") from Test
/// Connection. Root cause (proven, not guessed): `ConversationProviderProbe`
/// built its OWN request using `config.reasoningTemperature` (the
/// TWO-STAGE reasoner's field) instead of reusing the canonical,
/// pre-existing `ProviderReadinessChecker`, AND `conversationModelConfigFromNativeSources`
/// never carried the frozen `temperatureEncoding = .omit` /
/// `tokenLimitEncoding = .maxCompletionTokens` policy proven correct live
/// against `gpt-5.6-sol` (see `ModelProviderTests.swift`). This suite
/// proves the fix from both ends: config construction AND wire
/// serialization, plus probe/production parity.
@Suite struct ProdBootstrapR22Tests {

    // MARK: - §2/§3/§6 native config now carries the frozen OpenAI policy

    @Test func nativeOpenAIConfig_getsTemperatureOmit_andMaxCompletionTokens() {
        let store = FakeCredentialStore()
        try? store.save("sk-real-owner-key", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "openai"
        settings.conversationEndpoint = "https://api.openai.com/v1/chat/completions"
        settings.conversationModel = "gpt-5.6-sol"

        let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: settings, processEnvironment: [:])
        #expect(config.isConfigured)
        #expect(config.temperatureEncoding == .omit, "§4 — the frozen OpenAI GPT-5.x policy must reach the native path")
        #expect(config.tokenLimitEncoding == .maxCompletionTokens, "§5 — same for the token-limit field GPT-5.x actually accepts")
    }

    @Test func nativeOpenAICompatibleConfig_keepsOrdinaryDefaults_notForcedToOmit() {
        // A DIFFERENT explicit provider choice (Groq/local/other) must NOT
        // silently inherit OpenAI-GPT-5.x-specific serialization — §7:
        // "provider behavior belongs in explicit configuration," keyed on
        // the owner's own provider choice, never a hidden model-name rule.
        let store = FakeCredentialStore()
        try? store.save("gsk-real-owner-key", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "openai-compatible"
        settings.conversationEndpoint = "https://api.groq.com/openai/v1/chat/completions"
        settings.conversationModel = "llama-3.3-70b-versatile"

        let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: settings, processEnvironment: [:])
        #expect(config.isConfigured)
        #expect(config.temperatureEncoding == .explicit, "unrelated providers keep the ordinary default, unaffected by the OpenAI-specific fix")
        #expect(config.tokenLimitEncoding == .none)
    }

    @Test func nativeConfig_envOverride_stillWinsOverOpenAIDefault() {
        let store = FakeCredentialStore()
        try? store.save("sk-real-owner-key", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "openai"
        settings.conversationEndpoint = "https://api.openai.com/v1/chat/completions"
        settings.conversationModel = "gpt-5.6-sol"

        let config = conversationModelConfigFromNativeSources(
            credentialStore: store, settings: settings,
            processEnvironment: ["FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING": "explicit", "FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING": "max_tokens"]
        )
        #expect(config.temperatureEncoding == .explicit, "an explicit developer override always wins over the native default")
        #expect(config.tokenLimitEncoding == .maxTokens)
    }

    // MARK: - §2 NATIVE == FROZEN semantic-parity table (credentials excluded)

    @Test func nativeConfig_semanticParity_withFrozenEnvEquivalent() {
        let envEquivalent = ConversationModelConfig.fromEnvironment([
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "https://api.openai.com/v1/chat/completions",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "sk-anything",
            "FRIDAY_CONVERSATION_MODEL_NAME": "gpt-5.6-sol",
            "FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING": "omit",
            "FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING": "max_completion_tokens",
            "FRIDAY_CONVERSATION_MODEL_ARCHITECTURE": "unified-one-call",
        ])

        let store = FakeCredentialStore()
        try? store.save("sk-owner-real-key", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "openai"
        settings.conversationEndpoint = "https://api.openai.com/v1/chat/completions"
        settings.conversationModel = "gpt-5.6-sol"
        let native = conversationModelConfigFromNativeSources(credentialStore: store, settings: settings, processEnvironment: [:])

        #expect(native.endpoint == envEquivalent.endpoint)
        #expect(native.modelName == envEquivalent.modelName)
        #expect(native.temperatureEncoding == envEquivalent.temperatureEncoding)
        #expect(native.tokenLimitEncoding == envEquivalent.tokenLimitEncoding)
        #expect(native.architecture == envEquivalent.architecture)
        // Credentials are deliberately excluded from this comparison (§2).
    }

    // MARK: - §4 serialization: temperature is ABSENT, not 0/1/null

    @Test func serialization_temperatureEncodingOmit_keyAbsentFromJSON() {
        let body = ConversationModelRequestBuilder.encode(
            systemPolicy: "sys", userPayloadJSON: "{}", modelName: "gpt-5.6-sol", temperature: 0.1, temperatureEncoding: .omit
        )
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed request body"); return
        }
        #expect(!json.keys.contains("temperature"), "the field itself must not exist — not 0.1, not 1, not 0, not null")
    }

    // MARK: - §8/§9 probe uses the canonical builder — no probe-specific temperature default

    @Test func probe_forOneCallConfig_usesUnifiedTemperatureField_notReasoningTemperature() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(#"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#.data(using: .utf8)!)
        // temperatureEncoding left at the default (.explicit) so the field
        // IS present — this test is about WHICH value gets sent, not
        // whether it's sent at all (that's covered separately below).
        let config = ConversationModelConfig(
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "m",
            architecture: .unifiedOneCall
        )
        _ = ConversationProviderProbe(client: fake).probeBlocking(config: config)
        #expect(fake.sendCallCount == 1)
        let json = (try? JSONSerialization.jsonObject(with: fake.lastRequestBody() ?? Data())) as? [String: Any]
        #expect(json?["temperature"] as? Double == config.unifiedTemperature,
                "the probe for a one-call config must send the SAME temperature field production actually sends — not reasoningTemperature")
    }

    @Test func probe_temperatureEncodingOmit_sendsNoTemperatureField() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(#"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#.data(using: .utf8)!)
        let config = ConversationModelConfig(
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "gpt-5.6-sol",
            temperatureEncoding: .omit, architecture: .unifiedOneCall
        )
        let result = ConversationProviderProbe(client: fake).probeBlocking(config: config)
        let json = (try? JSONSerialization.jsonObject(with: fake.lastRequestBody() ?? Data())) as? [String: Any]
        #expect(json?["temperature"] == nil)
        #expect(json?["max_completion_tokens"] == nil, "tokenLimitEncoding defaults to .none unless explicitly set")
        #expect(result.isConnected)
    }

    // MARK: - §9 probe / production PARITY — the most important assertion

    @Test func probeAndProduction_agreeOnTemperatureFieldPresence_forTheSameConfig() {
        let openAIConfig = ConversationModelConfig(
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "sk-x", modelName: "gpt-5.6-sol",
            tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit, architecture: .unifiedOneCall
        )

        // A. probe request.
        let probeFake = FakeConversationModelRequesting()
        probeFake.behavior = .success(#"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#.data(using: .utf8)!)
        _ = ConversationProviderProbe(client: probeFake).probeBlocking(config: openAIConfig)
        let probeJSON = (try? JSONSerialization.jsonObject(with: probeFake.lastRequestBody() ?? Data())) as? [String: Any]

        // B. production one-call request (same helper `ResponseScopeTests` uses).
        let prodFake = FakeConversationModelRequesting()
        prodFake.behavior = .failure(ConversationModelError.emptyResponse) // outcome doesn't matter — only the OUTBOUND request
        let provider = ModelUnifiedConversationProvider(client: prodFake, config: openAIConfig)
        let ctx = ConversationContext(
            interactionID: "t1", taskID: "t1", outcomeCode: "SUCCESS", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "hello", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "hello", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        let prodJSON = (try? JSONSerialization.jsonObject(with: prodFake.lastRequestBody() ?? Data())) as? [String: Any]

        #expect(probeJSON?["temperature"] == nil, "probe: temperature absent")
        #expect(prodJSON?["temperature"] == nil, "production: temperature absent")
        #expect(probeJSON?["model"] as? String == prodJSON?["model"] as? String)
        #expect(probeJSON?["max_completion_tokens"] != nil)
        #expect(prodJSON?["max_completion_tokens"] != nil)
        #expect(probeJSON?["max_tokens"] == nil)
        #expect(prodJSON?["max_tokens"] == nil)
    }

    // MARK: - §11 error classification — sanitized, actionable, no raw provider body in the visible line

    @Test func connectivityResult_authenticationFailed_displayLineNeverIncludesRawBody() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(401, body: #"{"error":{"message":"Incorrect API key provided: sk-***"}}"#))
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let result = ConversationProviderProbe(client: fake).probeBlocking(config: config)
        #expect(result == .authenticationFailed)
        #expect(result.displayLine == "Authentication failed. Replace the API key and try again.")
        #expect(!result.displayLine.contains("{"), "the visible line must never contain raw provider JSON")
    }

    @Test func connectivityResult_requestFormatError_classifiedAsProviderRejected_notShownRaw() {
        // Reproduces the EXACT real owner failure shape.
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.1 with this model. Only the default value is supported.","type":"invalid_request_error"}}"#))
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "gpt-5.6-sol", temperatureEncoding: .explicit, architecture: .unifiedOneCall)
        let result = ConversationProviderProbe(client: fake).probeBlocking(config: config)
        if case .providerRejectedRequest = result {} else { Issue.record("expected .providerRejectedRequest, got \(result)") }
        #expect(result.displayLine == "Provider rejected configuration. Check the selected model/settings.")
        #expect(!result.displayLine.contains("temperature"), "the raw provider error text must never reach the visible label")
        #expect(!result.displayLine.contains("{"))
        // The bounded detail is still available for developer diagnostics.
        #expect(result.diagnosticDetail?.contains("400") == true)
    }

    @Test func connectivityResult_networkError_classifiedNeverAsAuthOrRequestFormat() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let result = ConversationProviderProbe(client: fake).probeBlocking(config: config)
        #expect(result == .networkUnavailable)
    }

    // MARK: - §10 one-call contract still holds after the serializer fix

    @Test func oneCallContract_stillHolds_afterSerializerFix_normalTurn() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(#"{"choices":[{"message":{"content":"{\"reasoning\":{\"dialogueAct\":\"acknowledgment\",\"interactionMode\":\"conversational\"},\"response\":{\"text\":\"Sounds good.\"}}"}}]}"#.data(using: .utf8)!)
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "gpt-5.6-sol", tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit, architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, client: fake, diagnostics: recorder)
        _ = presenter.response(for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "t", correlationID: "t", taskID: "t", outcome: "SUCCESS", text: "Done.")), transcript: "sounds good, thanks")
        #expect(fake.sendCallCount == 1, "§10 — providerCallCount <= 1 for a normal turn")
    }

    @Test func oneCallContract_rejectedCandidate_noRepairCall() {
        let fake = FakeConversationModelRequesting()
        // Schema-invalid content -> local ResponseValidation must reject it without a second call.
        fake.behavior = .success(#"{"choices":[{"message":{"content":"not valid json"}}]}"#.data(using: .utf8)!)
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: "k", modelName: "gpt-5.6-sol", tokenLimitEncoding: .maxCompletionTokens, temperatureEncoding: .omit, architecture: .unifiedOneCall)
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, client: fake)
        _ = presenter.response(for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "t2", correlationID: "t2", taskID: "t2", outcome: "SUCCESS", text: "Done.")), transcript: "ok")
        #expect(fake.sendCallCount == 1, "a rejected candidate must fall back locally, never retry the provider")
    }

    // MARK: - §13 owner Keychain safety — this pass never writes/deletes credentials

    @Test func nativeSourceResolvers_neverWriteOrDeleteCredentials() {
        final class GuardedStore: CredentialStoring, @unchecked Sendable {
            let inner = FakeCredentialStore()
            private(set) var saveCallCount = 0
            private(set) var deleteCallCount = 0
            func save(_ value: String, for identifier: CredentialIdentifier) throws { saveCallCount += 1; try inner.save(value, for: identifier) }
            func read(_ identifier: CredentialIdentifier) throws -> String? { try inner.read(identifier) }
            func delete(_ identifier: CredentialIdentifier) throws { deleteCallCount += 1; try inner.delete(identifier) }
            func status(_ identifier: CredentialIdentifier) -> CredentialStatus { inner.status(identifier) }
        }
        let store = GuardedStore()
        try? store.inner.save("sk-owner-real-key", for: .conversationProvider)
        try? store.inner.save("sk_car_owner_real_key", for: .cartesiaVoiceProvider)

        _ = conversationModelConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: [:])
        _ = premiumVoiceProviderConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: [:])
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        _ = ConversationProviderProbe(client: fake).probeBlocking(config: conversationModelConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: [:]))

        #expect(store.saveCallCount == 0, "resolving config for production/Test-Connection must never write a credential")
        #expect(store.deleteCallCount == 0, "…and must never delete one either")
        #expect((try? store.read(.conversationProvider)) == "sk-owner-real-key", "the owner's real credential must survive untouched")
    }
}
