import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-PROD-BOOTSTRAP-R2 — wiring the frozen one-call conversational brain
/// into production, the native provider-config bridges, and the real
/// connectivity probes. Network-free: every provider call goes through a
/// fake.
@Suite struct ProdBootstrapR2Tests {

    // MARK: - §2.2 ResponsePresenting.response(for:transcript:)

    private func successOutcome(_ taskID: String = "t1") -> CommandRuntimeOutcome {
        .success(RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: "SUCCESS", text: "Done."))
    }

    @Test func responsePresenting_transcriptOverload_defaultsToForwardingToOutcomeOnlyMethod() {
        // A presenter that only implements the base requirement still
        // compiles and behaves — the transcript-aware call forwards.
        let presenter = DeterministicResponsePresenter()
        let a = presenter.response(for: successOutcome())
        let b = presenter.response(for: successOutcome(), transcript: "anything at all")
        #expect(a.text == b.text)
        #expect(a.wasSuccess == b.wasSuccess)
    }

    @Test func conversationalPresenter_transcriptOverload_reachesTheModelRequest() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // only the OUTBOUND request matters
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.example.invalid/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, client: fake)

        _ = presenter.response(for: successOutcome("turn-9"), transcript: "why is the sky red at sunset")
        #expect(fake.sendCallCount == 1, "the one-call path makes exactly one provider request per turn")
        let body = String(data: fake.capturedRequestBodies.first ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("why is the sky red at sunset"), "the transcript must actually be carried into the request")
    }

    @Test func conversationalPresenter_transcriptOverload_whenProviderFails_fallsBackDeterministically_noSecondCall() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(500, body: "server error"))
        let recorder = WakeDiagnosticsRecorder()
        let config = ConversationModelConfig(endpoint: URL(string: "https://api.example.invalid/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, client: fake, diagnostics: recorder)

        let response = presenter.response(for: successOutcome("turn-x"), transcript: "run a status check")
        #expect(fake.sendCallCount == 1, "§2.3 — NEVER a second provider repair request after a failed/rejected response")
        #expect(!response.text.isEmpty)
        let d = recorder.snapshot()
        #expect(d.lastFinalResponseSource == .deterministicFallback)
        #expect(d.lastProviderArchitecture == "unifiedOneCall")
    }

    // MARK: - §2 / §2.3 conversationModelConfigFromNativeSources

    @Test func nativeConversationConfig_keychainPath_forcesOneCallArchitecture() {
        let store = FakeCredentialStore()
        try? store.save("sk-native-test", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "openai"
        settings.conversationEndpoint = "https://api.openai.com/v1/chat/completions"
        settings.conversationModel = "gpt-4o"

        let config = conversationModelConfigFromNativeSources(
            credentialStore: store, settings: settings, processEnvironment: [:]
        )
        #expect(config.isConfigured)
        #expect(config.architecture == .unifiedOneCall, "§2.3 — production native path must be one-call, never the old two-call flow")
        #expect(config.modelName == "gpt-4o")
        #expect(config.endpoint?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func nativeConversationConfig_noKeychainCredential_returnsUnconfigured_soProductionStaysDeterministic() {
        let store = FakeCredentialStore()
        let config = conversationModelConfigFromNativeSources(
            credentialStore: store, settings: .safeDefault, processEnvironment: [:]
        )
        #expect(!config.isConfigured, "no credential -> fail closed to the deterministic response path")
    }

    @Test func nativeConversationConfig_fullyValidShellEnv_winsOverKeychain_andKeepsItsOwnArchitectureDefault() {
        let store = FakeCredentialStore()
        try? store.save("sk-keychain", for: .conversationProvider)
        let env = [
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "http://127.0.0.1:8080/v1/chat/completions",
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "sk-shell",
            "FRIDAY_CONVERSATION_MODEL_NAME": "local-model",
        ]
        let envOnly = ConversationModelConfig.fromEnvironment(env)
        #expect(envOnly.isConfigured)
        let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: env)
        #expect(config.modelName == "local-model", "a fully-valid shell env config still wins (developer/CI parity)")
        #expect(config.architecture == .twoStage, "the env path keeps ConversationModelConfig.fromEnvironment's own default; only the native path is forced to one-call")
    }

    @Test func nativeConversationConfig_envArchitectureOverridePropagatesThroughNativePath() {
        let store = FakeCredentialStore()
        try? store.save("sk-native", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationEndpoint = "https://api.openai.com/v1/chat/completions"
        settings.conversationModel = "gpt-4o"
        let config = conversationModelConfigFromNativeSources(
            credentialStore: store, settings: settings,
            processEnvironment: ["FRIDAY_CONVERSATION_MODEL_ARCHITECTURE": "two-stage"]
        )
        #expect(config.architecture == .twoStage, "an explicit env architecture is still honored on the native path")
    }

    // MARK: - §2 premiumVoiceProviderConfigFromNativeSources

    @Test func nativeVoiceConfig_keychainPath_yieldsFrozenSkylarIdentity() {
        let store = FakeCredentialStore()
        try? store.save("sk_car_test", for: .cartesiaVoiceProvider)
        let config = premiumVoiceProviderConfigFromNativeSources(
            credentialStore: store, settings: .safeDefault, processEnvironment: [:]
        )
        #expect(config.isConfigured)
        #expect(config.isCartesia)
        #expect(config.modelName == "sonic-3.6")
        #expect(config.voiceID == "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4")
        #expect(config.locale == "en-US")
        #expect(config.apiVersion == "2026-08-14")
    }

    @Test func nativeVoiceConfig_noCredential_isUnconfigured() {
        let config = premiumVoiceProviderConfigFromNativeSources(
            credentialStore: FakeCredentialStore(), settings: .safeDefault, processEnvironment: [:]
        )
        #expect(!config.isConfigured)
    }

    // MARK: - §2.7 ConversationProviderProbe

    private func configuredConversationConfig() -> ConversationModelConfig {
        ConversationModelConfig(endpoint: URL(string: "https://api.example.invalid/v1/chat/completions")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
    }

    @Test func conversationProbe_notConfigured_reportsConfigurationIncomplete() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            ConversationProviderProbe(client: FakeConversationModelRequesting())
                .probe(config: .unconfigured) { cont.resume(returning: $0) }
        }
        if case .configurationIncomplete = result {} else { Issue.record("expected .configurationIncomplete, got \(result)") }
    }

    @Test func conversationProbe_validEnvelope_reportsConnected() async {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(#"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#.data(using: .utf8)!)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            ConversationProviderProbe(client: fake).probe(config: configuredConversationConfig()) { cont.resume(returning: $0) }
        }
        #expect(result.isConnected)
    }

    @Test func conversationProbe_http401_reportsAuthenticationFailed() async {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(401, body: #"{"error":{"message":"invalid api key"}}"#))
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            ConversationProviderProbe(client: fake).probe(config: configuredConversationConfig()) { cont.resume(returning: $0) }
        }
        #expect(result == .authenticationFailed)
    }

    @Test func conversationProbe_http400_reportsProviderRejected_withBoundedDetail() async {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.httpStatus(400, body: #"{"error":{"code":"model_not_found"}}"#))
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            ConversationProviderProbe(client: fake).probe(config: configuredConversationConfig()) { cont.resume(returning: $0) }
        }
        if case .providerRejectedRequest(let detail) = result {
            #expect(detail.contains("400"))
            #expect(detail.count <= 200)
        } else { Issue.record("expected .providerRejectedRequest, got \(result)") }
    }

    @Test func conversationProbe_offline_reportsNetworkUnavailable() async {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            ConversationProviderProbe(client: fake).probe(config: configuredConversationConfig()) { cont.resume(returning: $0) }
        }
        #expect(result == .networkUnavailable)
    }

    @Test func connectivityResult_displayLines_areActionable_neverBareConnectionFailed() {
        #expect(ProviderConnectivityResult.authenticationFailed.displayLine.contains("Replace the API key"))
        #expect(ProviderConnectivityResult.networkUnavailable.displayLine.contains("reach the provider"))
        #expect(!ProviderConnectivityResult.timedOut.displayLine.isEmpty)
    }

    // MARK: - §2.7 VoiceProviderProbe (guards only — real HTTP is owner/hardware territory)

    @Test func voiceProbe_notConfigured_reportsConfigurationIncomplete() async {
        let config = PremiumVoiceProviderConfig(endpoint: nil, apiKey: nil)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ProviderConnectivityResult, Never>) in
            VoiceProviderProbe().probe(config: config) { cont.resume(returning: $0) }
        }
        if case .configurationIncomplete = result {} else { Issue.record("expected .configurationIncomplete, got \(result)") }
    }

    // MARK: - §2.2 WakeCoordinator actually delivers the transcript to the presenter

    private final class TranscriptCapturingPresenter: ResponsePresenting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seenTranscripts: [String?] = []
        func response(for outcome: CommandRuntimeOutcome) -> SpokenResponse {
            record(nil)
            return SpokenResponse(text: "ok", wasSuccess: true, category: .information)
        }
        func response(for outcome: CommandRuntimeOutcome, transcript: String?) -> SpokenResponse {
            record(transcript)
            return SpokenResponse(text: "ok", wasSuccess: true, category: .information)
        }
        private func record(_ t: String?) { lock.lock(); seenTranscripts.append(t); lock.unlock() }
    }

    @Test func wakeCoordinator_deliversValidatedTranscriptToPresenter_notNil() async {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let transcriber = FakeSpeechTranscriber()
        let submitter = FakeCommandRuntimeSubmitting()
        let synthesizer = FakeSpeechSynthesizer()
        let presenter = TranscriptCapturingPresenter()
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "Status ok.")

        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: FakeMicrophonePermission(status: .authorized),
            transcriber: transcriber, runtimeSubmitter: submitter,
            synthesizer: synthesizer, responsePresenter: presenter,
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 0.3, cooldown: 0.05))
        )

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 60_000_000)
        transcriber.simulateResult(.finalized("what is the weather like tomorrow"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(presenter.seenTranscripts.count == 1)
        #expect(presenter.seenTranscripts.first == "what is the weather like tomorrow",
                "P2-PROD-BOOTSTRAP-R2 §2.2 — the presenter must receive the real transcript, not nil")
    }
}
