import Testing
@testable import FridayCompanionKit
import AVFoundation
import Foundation

/// P2-M5V9-B — original FRIDAY neural voice architecture coverage. Every
/// test here exercises code NEW to this milestone; the underlying V9-A
/// streaming/buffer/circuit-breaker/identity-guard machinery keeps its
/// OWN, unchanged, preserved coverage in `PremiumSpeechInfrastructureTests.swift`
/// (§27: "preserve existing... add: ..."). Nothing here touches the
/// conversational brain — every fixture is either speech-layer-only or a
/// hand-built `ConversationUnderstanding`/`NaturalResponsePlan` value,
/// never a live provider call (no credentials exist in this environment;
/// `URLSessionPremiumSpeechStreamProvider` is exercised only via a fake
/// `PremiumSpeechRequesting`, matching this codebase's established
/// "fakes only, never real network calls in tests" discipline).
@Suite struct PremiumVoiceV9BTests {
    // MARK: - §2: VoiceSynthesisProfile / PremiumVoiceProviderConfig

    @Test func voiceSynthesisProfile_unconfigured_reportsNoCapabilities() {
        let profile = VoiceSynthesisProfile.unconfigured
        #expect(profile.capabilities == .none)
        #expect(profile.voiceIdentity.providerID == "none")
    }

    @Test func voiceSynthesisProfile_clampsRateToSafeBounds() {
        let profile = VoiceSynthesisProfile(
            provider: "test", model: "test-model", voiceIdentity: PremiumVoiceProfile(voiceProfileID: "v", providerID: "p", providerVoiceID: "voice", profileVersion: "1"),
            locale: "en-US", speakingRateBaseline: 99.0, capabilities: .none
        )
        #expect(profile.speakingRateBaseline <= AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test func providerConfig_unconfigured_byDefault() {
        #expect(!PremiumVoiceProviderConfig.unconfigured.isConfigured)
    }

    @Test func providerConfig_notConfigured_withoutBothCredentials() {
        let onlyEndpoint = PremiumVoiceProviderConfig(endpoint: URL(string: "https://example.com/tts"), apiKey: nil)
        #expect(!onlyEndpoint.isConfigured)
        let onlyKey = PremiumVoiceProviderConfig(endpoint: nil, apiKey: "secret")
        #expect(!onlyKey.isConfigured)
    }

    @Test func providerConfig_configured_withHTTPSEndpointAndKey() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "https://tts.example.com/v1/speak")!, apiKey: "secret")
        #expect(config.isConfigured)
    }

    @Test func providerConfig_rejectsPlaintextRemoteHTTP() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "http://tts.example.com/v1/speak")!, apiKey: "secret")
        #expect(!config.isConfigured, "a remote plaintext endpoint must never count as configured")
    }

    @Test func providerConfig_allowsLocalhostPlaintext() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "http://127.0.0.1:8080/speak")!, apiKey: "secret")
        #expect(config.isConfigured)
    }

    @Test func providerConfig_fromEnvironment_absentByDefault() {
        // The real behavior every production call site relies on: an
        // environment with none of the FRIDAY_VOICE_PROVIDER_* keys set
        // must produce an unconfigured config, never a crash or a guess.
        #expect(!PremiumVoiceProviderConfig.fromEnvironment([:]).isConfigured)
    }

    @Test func providerConfig_fromEnvironment_readsAllFields() {
        let env = [
            "FRIDAY_VOICE_PROVIDER_ENDPOINT": "https://tts.example.com/speak",
            "FRIDAY_VOICE_PROVIDER_API_KEY": "secret",
            "FRIDAY_VOICE_PROVIDER_NAME": "acme-tts",
            "FRIDAY_VOICE_PROVIDER_MODEL": "acme-neural-v2",
            "FRIDAY_VOICE_PROVIDER_VOICE_ID": "ava",
            "FRIDAY_VOICE_PROVIDER_LOCALE": "en-GB",
        ]
        let config = PremiumVoiceProviderConfig.fromEnvironment(env)
        #expect(config.isConfigured)
        #expect(config.providerName == "acme-tts")
        #expect(config.modelName == "acme-neural-v2")
        #expect(config.voiceID == "ava")
        #expect(config.locale == "en-GB")
    }

    // MARK: - §5/§6/§7: SpeechDeliveryMode mapping

    private func plan(register: SocialRegister, humorAllowance: Bool = false) -> NaturalResponsePlan {
        NaturalResponsePlan(
            responseGoal: .success, socialRegister: register, warmth: 0.5, directness: 0.5, humorAllowance: humorAllowance,
            humorStrength: 0, formality: 0.5, verbosity: .concise, reassurance: 0.5, urgency: 0.2,
            followUpMode: .none, prosodyIntent: .information
        )
    }

    @Test func deliveryMode_professionalRegister_mapsToProfessional() {
        let planner = DeterministicSpeechDeliveryPlanner()
        #expect(planner.mode(forSocialRegister: .professional, explanationRequested: false, humorAllowed: false) == .professional)
    }

    @Test func deliveryMode_focusedAndUrgent_mapToFocused() {
        let planner = DeterministicSpeechDeliveryPlanner()
        #expect(planner.mode(forSocialRegister: .focused, explanationRequested: false, humorAllowed: false) == .focused)
        #expect(planner.mode(forSocialRegister: .urgent, explanationRequested: false, humorAllowed: false) == .focused)
    }

    @Test func deliveryMode_seriousAndWarning_mapToSerious() {
        let planner = DeterministicSpeechDeliveryPlanner()
        #expect(planner.mode(forSocialRegister: .serious, explanationRequested: false, humorAllowed: false) == .serious)
        #expect(planner.mode(forSocialRegister: .warning, explanationRequested: false, humorAllowed: false) == .serious)
    }

    @Test func deliveryMode_casualFriendly_splitsOnHumorAllowance() {
        let planner = DeterministicSpeechDeliveryPlanner()
        #expect(planner.mode(forSocialRegister: .casualFriendly, explanationRequested: false, humorAllowed: true) == .lightPlayful)
        #expect(planner.mode(forSocialRegister: .casualFriendly, explanationRequested: false, humorAllowed: false) == .friendly, "casual without humor allowance must never become lightPlayful on its own")
    }

    @Test func deliveryMode_friendlyNeutralAndReassuring_mapToFriendly() {
        let planner = DeterministicSpeechDeliveryPlanner()
        #expect(planner.mode(forSocialRegister: .friendlyNeutral, explanationRequested: false, humorAllowed: false) == .friendly)
        #expect(planner.mode(forSocialRegister: .reassuring, explanationRequested: false, humorAllowed: false) == .friendly)
    }

    @Test func deliveryMode_explanationRequested_alwaysWinsRegardlessOfRegister() {
        let planner = DeterministicSpeechDeliveryPlanner()
        for register in SocialRegister.allCases {
            #expect(planner.mode(forSocialRegister: register, explanationRequested: true, humorAllowed: false) == .explanatory, "explanationRequested must override every register, including \(register)")
        }
    }

    @Test func deliveryPlan_neverAltersProsodyComputation_onlyAddsMode() {
        // The `prosody` field must be BYTE-IDENTICAL to calling the
        // existing, unchanged `AdaptiveProsodyPlanning.prosodyPlan` -
        // proving `SpeechDeliveryPlan` is purely additive, never a second
        // competing source of numeric adjustment.
        let planner = DeterministicSpeechDeliveryPlanner()
        let base = VoiceProfile.friday
        let context = ConversationContext(
            interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
        )
        let understanding = DeterministicConversationReasoner().understand(transcript: "Create a note called groceries.", recentTurns: [], context: context, acoustics: .unavailable, explicitUserStatements: [])
        let responsePlan = plan(register: .friendlyNeutral)
        let delivery = planner.deliveryPlan(plan: responsePlan, understanding: understanding, persona: .friday, acoustics: .unavailable, base: base)
        let directProsody = planner.prosodyPlan(persona: .friday, plan: responsePlan, acoustics: .unavailable, base: base)
        #expect(delivery.prosody == directProsody)
    }

    // MARK: - §14/§15: Pronunciation intelligence extensions

    @Test func pronunciationDictionary_coversMissionNamedTerms() {
        for word in ["JSON", "GPT", "HTTP", "HTTPS", "Swift", "Python", "GitHub", "URL"] {
            #expect(PronunciationDictionary.override(forWord: word) != nil, "\(word) must be a recognized pronunciation entry")
        }
    }

    @Test func textNormalizer_expandsCommonAbbreviations() {
        #expect(SpeechTextNormalizer.normalize("e.g. this").contains("for example"))
        #expect(SpeechTextNormalizer.normalize("i.e. that").contains("that is"))
        #expect(SpeechTextNormalizer.normalize("and so on, etc.").contains("et cetera"))
    }

    @Test func ssmlSafety_allowsSubTag_forPronunciationSubstitution() {
        #expect(SSMLSafety.allowedTags.contains("sub"))
    }

    @Test func wrapWithPronunciationHints_wrapsKnownWords_leavesOthersPlain() {
        let wrapped = SSMLSafety.wrapWithPronunciationHints("Check the API docs.")
        #expect(wrapped.contains("<speak>"))
        #expect(wrapped.contains("<sub alias=\"A-P-I\">API</sub>"))
        #expect(wrapped.contains("docs"))
    }

    @Test func wrapWithPronunciationHints_neverCorruptsOverlappingAcronyms() {
        // HTTP is a literal substring of HTTPS — a naive substring
        // replace would corrupt whichever is substituted first.
        let wrapped = SSMLSafety.wrapWithPronunciationHints("Use HTTPS not HTTP.")
        #expect(wrapped.contains("<sub alias=\"H-T-T-P-S\">HTTPS</sub>"))
        #expect(wrapped.contains("<sub alias=\"H-T-T-P\">HTTP</sub>"))
        #expect(!wrapped.contains("H-T-T-PS"), "HTTP's substitution must never bleed into HTTPS's own tag")
    }

    @Test func wrapWithPronunciationHints_escapesUntrustedMarkupFirst() {
        let wrapped = SSMLSafety.wrapWithPronunciationHints("<script>alert(1)</script>")
        #expect(!wrapped.contains("<script>"), "untrusted input must never become live markup")
        #expect(wrapped.contains("&lt;script&gt;"))
    }

    // MARK: - §2/§8/§17: URLSessionPremiumSpeechStreamProvider via a fake requester

    private final class FakePremiumSpeechRequesting: PremiumSpeechRequesting, @unchecked Sendable {
        var scriptedChunks: [Data] = []
        var scriptedResult: Result<Void, PremiumSpeechTransportError> = .success(())
        private(set) var lastRequestBody: Data?
        private(set) var sendCallCount = 0
        private(set) var cancelCallCount = 0

        func send(requestBody: Data, config: PremiumVoiceProviderConfig, onChunk: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Result<Void, PremiumSpeechTransportError>) -> Void) -> SpeechProviderCancelToken {
            sendCallCount += 1
            lastRequestBody = requestBody
            for chunk in scriptedChunks { onChunk(chunk) }
            completion(scriptedResult)
            return SpeechProviderCancelToken(cancelAction: { [weak self] in self?.cancelCallCount += 1 })
        }
    }

    private func makeRequest() -> SpeechSynthesisRequest {
        SpeechSynthesisRequest(interactionID: "i1", utteranceID: "u1", text: "Hello there", voiceID: "voice-1", language: "en-US", prosody: ProsodyPlan(rate: 0.5, pitchMultiplier: 1, volume: 1, preUtteranceDelay: 0, postUtteranceDelay: 0, emphasisStrength: 0, energy: 0.5))
    }

    @Test func urlSessionProvider_streamsChunks_thenCompletes() {
        let fake = FakePremiumSpeechRequesting()
        fake.scriptedChunks = [Data(repeating: 1, count: 100), Data(repeating: 2, count: 100)]
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        var events: [SpeechSynthesisEvent] = []
        _ = provider.synthesize(makeRequest()) { events.append($0) }
        #expect(events.first == .started(interactionID: "i1", utteranceID: "u1"))
        #expect(events.last == .completed(interactionID: "i1", utteranceID: "u1"))
        let chunkCount = events.filter { if case .audioChunk = $0 { return true } else { return false } }.count
        #expect(chunkCount == 2)
    }

    @Test func urlSessionProvider_sequenceNumbersAreOrderedFromZero() {
        let fake = FakePremiumSpeechRequesting()
        fake.scriptedChunks = [Data([1]), Data([2]), Data([3])]
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        var sequences: [Int] = []
        _ = provider.synthesize(makeRequest()) { event in
            if case .audioChunk(_, _, _, let sequence) = event { sequences.append(sequence) }
        }
        #expect(sequences == [0, 1, 2])
    }

    @Test func urlSessionProvider_cancellation_reportsCancelledEvent() {
        let fake = FakePremiumSpeechRequesting()
        fake.scriptedResult = .failure(.cancelled)
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        var events: [SpeechSynthesisEvent] = []
        _ = provider.synthesize(makeRequest()) { events.append($0) }
        #expect(events.contains(.cancelled(interactionID: "i1", utteranceID: "u1")))
    }

    @Test func urlSessionProvider_notConfigured_mapsToConfigurationFailure() {
        let fake = FakePremiumSpeechRequesting()
        fake.scriptedResult = .failure(.notConfigured)
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        var events: [SpeechSynthesisEvent] = []
        _ = provider.synthesize(makeRequest()) { events.append($0) }
        #expect(events.contains(.failed(interactionID: "i1", utteranceID: "u1", category: .configuration)))
    }

    @Test func urlSessionProvider_httpStatusCodes_mapToSanitizedCategories_neverLeakingRawStatus() {
        let cases: [(Int, SpeechProviderFailureCategory)] = [(401, .authentication), (403, .authorization), (404, .unsupportedVoice), (429, .rateLimit), (500, .server)]
        for (status, expected) in cases {
            let fake = FakePremiumSpeechRequesting()
            fake.scriptedResult = .failure(.httpStatus(status))
            let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
            var events: [SpeechSynthesisEvent] = []
            _ = provider.synthesize(makeRequest()) { events.append($0) }
            #expect(events.contains(.failed(interactionID: "i1", utteranceID: "u1", category: expected)), "HTTP \(status) must map to \(expected)")
        }
    }

    @Test func urlSessionProvider_networkError_mapsToNetworkCategory() {
        let fake = FakePremiumSpeechRequesting()
        fake.scriptedResult = .failure(.network("connection reset"))
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        var events: [SpeechSynthesisEvent] = []
        _ = provider.synthesize(makeRequest()) { events.append($0) }
        #expect(events.contains(.failed(interactionID: "i1", utteranceID: "u1", category: .network)))
    }

    @Test func urlSessionProvider_ssmlDisabledByDefault_sendsPlainText() {
        // The default capabilities this provider ships with report
        // `ssml: false` — the request body must carry the plain text
        // unchanged, never markup, matching that negotiated capability.
        let fake = FakePremiumSpeechRequesting()
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured)
        _ = provider.synthesize(makeRequest()) { _ in }
        let body = fake.lastRequestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(body?["text"] as? String == "Hello there")
    }

    @Test func urlSessionProvider_ssmlEnabled_wrapsTextWithPronunciationHints() {
        let capabilities = PremiumSpeechCapabilities(
            streaming: true, cancellation: true, nativeProsody: false, speakingStyles: false, pronunciationControl: true,
            ssml: true, wordTimestamps: false, sentenceTimestamps: false, sampleRates: [24000], audioFormats: ["pcm_s16le"],
            voiceSelection: true, customVoice: false, localeSupport: ["en-US"]
        )
        let fake = FakePremiumSpeechRequesting()
        let provider = URLSessionPremiumSpeechStreamProvider(requester: fake, config: .unconfigured, capabilities: capabilities)
        let request = SpeechSynthesisRequest(interactionID: "i2", utteranceID: "u2", text: "Check the API.", voiceID: "voice-1", language: "en-US", prosody: ProsodyPlan(rate: 0.5, pitchMultiplier: 1, volume: 1, preUtteranceDelay: 0, postUtteranceDelay: 0, emphasisStrength: 0, energy: 0.5))
        _ = provider.synthesize(request) { _ in }
        let body = fake.lastRequestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect((body?["text"] as? String)?.contains("<sub alias=") == true)
    }

    // MARK: - §25: premium voice session metrics (WakeDiagnosticsRecorder)

    @Test func diagnostics_recordsPremiumAttemptAndChunksAndFirstAudioByte() {
        let diagnostics = WakeDiagnosticsRecorder()
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .started(interactionID: i, utteranceID: u) }),
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .completed(interactionID: i, utteranceID: u) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, diagnostics: diagnostics)
        try? synth.speak("hello", category: .information, onFinished: { _ in })
        let snapshot = diagnostics.snapshot()
        #expect(snapshot.premiumAttemptCount == 1)
        #expect(snapshot.premiumChunksReceivedCount == 1)
        #expect(snapshot.lastPremiumFirstAudioByteMs != nil)
    }

    @Test func diagnostics_recordsCancellation() {
        let diagnostics = WakeDiagnosticsRecorder()
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [(0, { i, u in .cancelled(interactionID: i, utteranceID: u) })]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, diagnostics: diagnostics)
        try? synth.speak("hello", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().premiumCancellationCount == 1)
    }

    @Test func diagnostics_samanthaFallback_recordedOnlyWhenSecondaryActuallySpeaks_notMerelyConfigured() {
        let diagnostics = WakeDiagnosticsRecorder()
        // Success path: premium never fails, secondary must never be
        // asked to speak, so the fallback counter must stay at zero.
        let successFake = FakePremiumSpeechStreamProvider()
        successFake.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let premiumOK = PremiumNeuralSpeechSynthesizer(provider: successFake, diagnostics: diagnostics)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premiumOK, secondary: secondary, diagnostics: diagnostics)
        try? fallback.speak("hello", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().samanthaFallbackCount == 0)
        #expect(secondary.speakCallCount == 0)
    }

    @Test func diagnostics_samanthaFallback_recordedExactlyOnce_onPrePlaybackFailure() {
        let diagnostics = WakeDiagnosticsRecorder()
        let failFake = FakePremiumSpeechStreamProvider()
        failFake.scriptedEvents = [(0, { i, u in .failed(interactionID: i, utteranceID: u, category: .network) })]
        let premiumFail = PremiumNeuralSpeechSynthesizer(provider: failFake, diagnostics: diagnostics)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premiumFail, secondary: secondary, diagnostics: diagnostics)
        try? fallback.speak("hello", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().samanthaFallbackCount == 1)
        #expect(secondary.speakCallCount == 1)
        #expect(diagnostics.snapshot().premiumFallbackBeforePlaybackCount == 1)
        #expect(diagnostics.snapshot().premiumInterruptionAfterPlaybackCount == 0)
    }

    @Test func diagnostics_samanthaFallback_neverRecorded_onPostPlaybackInterruption() {
        // §24: after premium already spoke part of the response, the
        // secondary must NEVER be asked to replay it — the fallback
        // counter must stay at zero, and the interruption must be
        // attributed to "after playback," not "before playback."
        let diagnostics = WakeDiagnosticsRecorder()
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .failed(interactionID: i, utteranceID: u, category: .streamInterrupted) }),
        ]
        let premium = PremiumNeuralSpeechSynthesizer(provider: fake, diagnostics: diagnostics)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premium, secondary: secondary, diagnostics: diagnostics)
        try? fallback.speak("hello", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().samanthaFallbackCount == 0)
        #expect(secondary.speakCallCount == 0)
        #expect(diagnostics.snapshot().premiumInterruptionAfterPlaybackCount == 1)
        #expect(diagnostics.snapshot().premiumFallbackBeforePlaybackCount == 0)
    }

    @Test func diagnostics_samanthaFallbackRate_isNilUntilAnyAttemptRecorded() {
        #expect(WakeDiagnosticsRecorder().snapshot().samanthaFallbackRate == nil)
    }

    @Test func diagnostics_samanthaFallbackRate_computesRatioCorrectly() {
        let diagnostics = WakeDiagnosticsRecorder()
        let failFake = FakePremiumSpeechStreamProvider()
        failFake.scriptedEvents = [(0, { i, u in .failed(interactionID: i, utteranceID: u, category: .network) })]
        for _ in 0..<3 {
            let premium = PremiumNeuralSpeechSynthesizer(provider: failFake, diagnostics: diagnostics)
            let fallback = FallbackSpeechSynthesizer(primary: premium, secondary: FakeSpeechSynthesizer(), diagnostics: diagnostics)
            try? fallback.speak("hello", category: .information, onFinished: { _ in })
        }
        #expect(diagnostics.snapshot().samanthaFallbackRate == 1.0, "every attempt failed before playback, so the rate must be exactly 1.0")
    }

    // MARK: - §13/§29: production wiring composition proof (Samantha fallback-only)

    @Test func productionWiring_unconfiguredPremium_fallsThroughToSecondaryEveryTime() {
        // Reproduces AppDelegate's exact composition
        // (`FallbackSpeechSynthesizer(primary: PremiumNeuralSpeechSynthesizer(unconfigured), secondary: samantha)`)
        // with a fake standing in for Samantha, proving every utterance
        // still completes today with zero premium credentials configured.
        let diagnostics = WakeDiagnosticsRecorder()
        let premium = PremiumNeuralSpeechSynthesizer(provider: nil, diagnostics: diagnostics)
        let samantha = FakeSpeechSynthesizer()
        let synthesizer = FallbackSpeechSynthesizer(primary: premium, secondary: samantha, diagnostics: diagnostics)
        var outcome: SpeechSynthesisOutcome?
        try? synthesizer.speak("Your note is ready.", category: .success, onFinished: { outcome = $0 })
        #expect(outcome == .finished)
        #expect(samantha.speakCallCount == 1)
        #expect(diagnostics.snapshot().samanthaFallbackCount == 1)
        #expect(diagnostics.snapshot().premiumAttemptCount == 0, "an unconfigured premium engine never even reaches a network attempt")
    }

    // MARK: - §22: long-run voice test (30 sequential responses)

    @Test func longRun_thirtySequentialUtterances_noStaleAudio_noCrash_stableIdentity() {
        let representativeLines = [
            "Hi there.", "Your note's ready.", "That's not something I can do yet.", "I don't have permission to do that.",
            "I couldn't reach the service that time.", "I couldn't complete that, and I don't know why yet.",
            "That's taken care of.", "Sure, I'll add that.", "This needs manual review.", "Got it.",
        ]
        let diagnostics = WakeDiagnosticsRecorder()
        let premium = PremiumNeuralSpeechSynthesizer(provider: nil, diagnostics: diagnostics)
        let secondary = FakeSpeechSynthesizer()
        let synthesizer = FallbackSpeechSynthesizer(primary: premium, secondary: secondary, diagnostics: diagnostics)
        var outcomes: [SpeechSynthesisOutcome] = []
        let identifierBefore = synthesizer.engineIdentifier
        for i in 0..<30 {
            let text = representativeLines[i % representativeLines.count]
            var outcome: SpeechSynthesisOutcome?
            try? synthesizer.speak(text, category: .information, onFinished: { outcome = $0 })
            if let outcome { outcomes.append(outcome) }
        }
        #expect(outcomes.count == 30, "every one of 30 sequential utterances must terminate exactly once — no hang, no crash")
        #expect(outcomes.allSatisfy { $0 == .finished })
        #expect(synthesizer.engineIdentifier == identifierBefore, "speaker identity/engine composition must never drift across repeated calls")
        #expect(secondary.speakCallCount == 30)
        #expect(diagnostics.snapshot().samanthaFallbackCount == 30)
    }
}
