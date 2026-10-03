import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.1 — real premium voice realization/audition coverage. Every
/// test here exercises code NEW to this milestone (multi-candidate voice
/// config, the FRIDAY voice identity lock record); everything else this
/// milestone needed (streaming, fallback, metrics, capability
/// negotiation) is ALREADY covered by `PremiumVoiceV9BTests.swift`/
/// `PremiumSpeechInfrastructureTests.swift`, preserved unchanged per §29.
/// No live provider call is made anywhere in this file — this
/// environment has zero premium voice credentials configured (verified:
/// no `FRIDAY_VOICE_PROVIDER_*` environment variable is set), so §2's
/// "real audible output" requirement is honestly reported as BLOCKED in
/// this pass's own STOP report rather than faked here.
@Suite struct PremiumVoiceV9B1Tests {
    // MARK: - §10/§12: multi-candidate voice config

    @Test func auditionCandidates_empty_whenUnconfigured() {
        #expect(PremiumVoiceProviderConfig.unconfigured.auditionCandidateVoiceIDs.isEmpty)
    }

    @Test func auditionCandidates_primaryOnly_whenNoAdditionalListed() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "https://tts.example.com"), apiKey: "k", voiceID: "voice-a")
        #expect(config.auditionCandidateVoiceIDs == ["voice-a"])
    }

    @Test func auditionCandidates_includesAdditionalIDs_primaryFirst() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "https://tts.example.com"), apiKey: "k", voiceID: "voice-a", additionalCandidateVoiceIDs: ["voice-b", "voice-c"])
        #expect(config.auditionCandidateVoiceIDs == ["voice-a", "voice-b", "voice-c"])
    }

    @Test func auditionCandidates_removesExactDuplicates() {
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "https://tts.example.com"), apiKey: "k", voiceID: "voice-a", additionalCandidateVoiceIDs: ["voice-a", "voice-b", "voice-b"])
        #expect(config.auditionCandidateVoiceIDs == ["voice-a", "voice-b"])
    }

    @Test func fromEnvironment_parsesCommaSeparatedAdditionalVoiceIDs() {
        let env = [
            "FRIDAY_VOICE_PROVIDER_ENDPOINT": "https://tts.example.com/speak",
            "FRIDAY_VOICE_PROVIDER_API_KEY": "secret",
            "FRIDAY_VOICE_PROVIDER_VOICE_ID": "ava",
            "FRIDAY_VOICE_PROVIDER_VOICE_IDS": " maya, jordan ,,sam",
        ]
        let config = PremiumVoiceProviderConfig.fromEnvironment(env)
        #expect(config.additionalCandidateVoiceIDs == ["maya", "jordan", "sam"], "must trim whitespace and drop empty entries")
        #expect(config.auditionCandidateVoiceIDs == ["ava", "maya", "jordan", "sam"])
    }

    @Test func fromEnvironment_noVoiceIDsVar_yieldsNoAdditionalCandidates() {
        let env = ["FRIDAY_VOICE_PROVIDER_ENDPOINT": "https://tts.example.com/speak", "FRIDAY_VOICE_PROVIDER_API_KEY": "secret"]
        #expect(PremiumVoiceProviderConfig.fromEnvironment(env).additionalCandidateVoiceIDs.isEmpty)
    }

    @Test func thisEnvironment_hasNoRealPremiumVoiceCredentialsConfigured() {
        // Documents the actual, honestly-verified state of THIS sandbox
        // (§9: "if real premium credentials are not available, do not
        // fake pass") — re-checked directly via the real environment,
        // not assumed.
        #expect(!PremiumVoiceProviderConfig.fromEnvironment().isConfigured)
    }

    // MARK: - §25/§26: FridayVoiceIdentityLock

    @Test func voiceIdentityLock_v1_usesMissionNamedIdentityAndVersion() {
        let lock = FridayVoiceIdentityLock.v1(provider: "acme-tts", model: "acme-neural-v2", providerVoiceID: "ava", locale: "en-US", base: .friday)
        #expect(lock.identityID == "friday-original-01")
        #expect(lock.version == "1.0")
        #expect(lock.provider == "acme-tts")
        #expect(lock.providerVoiceID == "ava")
    }

    @Test func voiceIdentityLock_neverCarriesACredentialField() {
        // Structural proof, not just a doc comment: the type has no
        // property that could hold a secret at all.
        let mirror = Mirror(reflecting: FridayVoiceIdentityLock.v1(provider: "p", model: "m", providerVoiceID: "v", locale: "en-US", base: .friday))
        let fieldNames = mirror.children.compactMap(\.label)
        for name in fieldNames {
            #expect(!name.lowercased().contains("key") && !name.lowercased().contains("secret") && !name.lowercased().contains("credential"), "field \(name) must not exist on a persisted, safe-to-log identity record")
        }
    }

    @Test func voiceIdentityLock_isCodable_forPersistence() {
        let lock = FridayVoiceIdentityLock.v1(provider: "acme-tts", model: "acme-neural-v2", providerVoiceID: "ava", locale: "en-US", base: .friday)
        let data = try? JSONEncoder().encode(lock)
        #expect(data != nil)
        let decoded = data.flatMap { try? JSONDecoder().decode(FridayVoiceIdentityLock.self, from: $0) }
        #expect(decoded == lock)
    }

    @Test func voiceIdentityLock_encodedForm_neverContainsTheWordKeyOrSecret() {
        let lock = FridayVoiceIdentityLock.v1(provider: "acme-tts", model: "acme-neural-v2", providerVoiceID: "ava", locale: "en-US", base: .friday)
        guard let data = try? JSONEncoder().encode(lock), let json = String(data: data, encoding: .utf8) else {
            Issue.record("failed to encode"); return
        }
        #expect(!json.lowercased().contains("apikey"))
        #expect(!json.lowercased().contains("secret"))
    }
}
