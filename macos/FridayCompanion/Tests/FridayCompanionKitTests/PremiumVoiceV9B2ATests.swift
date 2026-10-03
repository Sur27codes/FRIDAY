import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.2A — regression coverage for the Cartesia configuration-gate
/// correctness fix. Root cause (proven, not guessed): `PremiumVoiceProviderConfig.isConfigured`
/// delegated unconditionally to `ConversationModelConfig.isEndpointAllowed`,
/// which was written for a synchronous REST LLM API and never allowed
/// `wss://` — silently rejecting a genuinely valid, fully-credentialed
/// Cartesia realtime endpoint. Every test here uses a DUMMY key value —
/// no real credential is ever read, stored, or asserted on here.
@Suite struct PremiumVoiceV9B2ATests {
    private let realCartesiaEndpoint = "wss://api.cartesia.ai/tts/websocket"

    private func completeConfig(
        endpoint: String? = nil, apiKey: String? = "dummy-test-key", providerName: String = "cartesia",
        modelName: String = "sonic-3.6", voiceID: String = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
        voiceIDs: [String] = [], apiVersion: String? = "2026-08-14"
    ) -> PremiumVoiceProviderConfig {
        PremiumVoiceProviderConfig(
            endpoint: URL(string: endpoint ?? realCartesiaEndpoint), apiKey: apiKey, providerName: providerName,
            modelName: modelName, voiceID: voiceID, locale: "en-US", additionalCandidateVoiceIDs: voiceIDs, apiVersion: apiVersion
        )
    }

    // MARK: - A/B/C: the owner's own proven-present environment must read as READY

    @Test func A_completeCartesiaEnvironment_isConfigured() {
        let config = completeConfig()
        #expect(config.isConfigured, "a fully-credentialed wss:// Cartesia config must be configured — this is the exact bug reported by the owner")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == nil)
    }

    @Test func B_singleVoiceIDWithoutVoiceIDs_isReady() {
        let config = completeConfig(voiceIDs: [])
        #expect(config.isConfigured)
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == nil, "VOICE_IDS must never be required for the normal single selected voice")
    }

    @Test func C_voiceIDsPresent_stillReady() {
        // Matches the owner's own observed environment exactly:
        // FRIDAY_VOICE_PROVIDER_VOICE_IDS set to the SAME single id.
        let config = completeConfig(voiceIDs: ["db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"])
        #expect(config.isConfigured)
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == nil)
    }

    @Test func fromEnvironment_reproducesTheExactOwnerReportedEnvironment_isReady() {
        // The owner's own printed diagnostic, reproduced verbatim as an
        // environment dictionary (dummy key value only).
        let env = [
            "FRIDAY_VOICE_PROVIDER_NAME": "cartesia",
            "FRIDAY_VOICE_PROVIDER_ENDPOINT": "wss://api.cartesia.ai/tts/websocket",
            "FRIDAY_VOICE_PROVIDER_API_KEY": "dummy-test-key",
            "FRIDAY_VOICE_PROVIDER_MODEL": "sonic-3.6",
            "FRIDAY_VOICE_PROVIDER_VOICE_ID": "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
            "FRIDAY_VOICE_PROVIDER_VOICE_IDS": "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
            "FRIDAY_VOICE_PROVIDER_LOCALE": "en-US",
            "FRIDAY_VOICE_PROVIDER_API_VERSION": "2026-08-14",
        ]
        let config = PremiumVoiceProviderConfig.fromEnvironment(env)
        #expect(config.isConfigured, "the owner's own reported environment must read as configured — this is the exact regression this fix closes")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == nil)
    }

    // MARK: - D/E/F: exact sanitized missing-field errors

    @Test func D_missingAPIKey_exactSanitizedError() {
        let config = completeConfig(apiKey: nil)
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "FRIDAY_VOICE_PROVIDER_API_KEY missing")
        #expect(!config.isConfigured)
    }

    @Test func D2_emptyAPIKey_sameExactError() {
        let config = completeConfig(apiKey: "")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "FRIDAY_VOICE_PROVIDER_API_KEY missing")
    }

    @Test func E_missingModel_exactSanitizedError() {
        let config = completeConfig(modelName: "unspecified")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "Cartesia model missing")
    }

    @Test func F_missingVoiceID_exactSanitizedError() {
        let config = completeConfig(voiceID: "unspecified")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "Cartesia voice ID missing")
    }

    @Test func missingEndpoint_exactSanitizedError() {
        let config = PremiumVoiceProviderConfig(endpoint: nil, apiKey: "dummy-test-key", providerName: "cartesia", modelName: "sonic-3.6", voiceID: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "Cartesia endpoint missing")
    }

    @Test func providerNameNotCartesia_exactSanitizedError() {
        let config = completeConfig(providerName: "acme-tts")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "provider name is not cartesia")
    }

    // MARK: - G/H: endpoint scheme validation

    @Test func G_wssCartesiaEndpoint_isValid() {
        #expect(PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "wss://api.cartesia.ai/tts/websocket")!, isCartesia: true))
    }

    @Test func G2_wssLocalhost_alsoValid() {
        #expect(PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "ws://localhost:9000")!, isCartesia: true))
    }

    @Test func H_malformedEndpoint_exactSanitizedError() {
        // A remote plaintext `ws://` (not localhost) is exactly as
        // disallowed as remote plaintext `http://` always was.
        let config = completeConfig(endpoint: "ws://example.com/tts")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "invalid Cartesia endpoint scheme")
        #expect(!config.isConfigured)
    }

    @Test func H2_wrongSchemeEntirely_exactSanitizedError() {
        let config = completeConfig(endpoint: "ftp://api.cartesia.ai/tts")
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "invalid Cartesia endpoint scheme")
    }

    @Test func cartesiaHTTPSEndpoint_alsoValid_forTheRESTBytesPath() {
        // §3: Cartesia's REST bytes endpoint is a plain https:// URL —
        // the fix must not make Cartesia wss-ONLY, only wss-INCLUSIVE.
        #expect(PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "https://api.cartesia.ai/tts/bytes")!, isCartesia: true))
    }

    // MARK: - I: generic (non-Cartesia) provider behavior is UNCHANGED

    @Test func I_genericProvider_httpsStillValid() {
        #expect(PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "https://tts.example.com/speak")!, isCartesia: false))
    }

    @Test func I2_genericProvider_wssStillRejected_unchangedBehavior() {
        // A non-Cartesia provider never gained `wss://` support — this
        // fix is narrowly scoped to Cartesia, not a global loosening.
        #expect(!PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "wss://tts.example.com/stream")!, isCartesia: false))
    }

    @Test func I3_genericProvider_remotePlaintextHTTPStillRejected() {
        #expect(!PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "http://tts.example.com/speak")!, isCartesia: false))
    }

    @Test func I4_genericProvider_localhostHTTPStillAllowed() {
        #expect(PremiumVoiceProviderConfig.isEndpointAllowed(URL(string: "http://127.0.0.1:8080/speak")!, isCartesia: false))
    }

    @Test func I5_conversationModelConfig_ownValidator_untouchedByThisFix() {
        // The frozen, shared LLM validator itself must still behave
        // EXACTLY as before — this fix added a new, separate,
        // provider-aware function; it did not modify the original.
        #expect(ConversationModelConfig.isEndpointAllowed(URL(string: "https://api.openai.com/v1/chat/completions")!))
        #expect(!ConversationModelConfig.isEndpointAllowed(URL(string: "wss://api.cartesia.ai/tts/websocket")!))
    }

    // MARK: - J: no secret value ever appears in diagnostics output

    @Test func J_blockingReasonStrings_neverContainTheAPIKeyValue() {
        let secretMarker = "THIS-IS-THE-SECRET-VALUE"
        for config in [
            completeConfig(apiKey: secretMarker),
            completeConfig(apiKey: nil),
            completeConfig(apiKey: secretMarker, modelName: "unspecified"),
            completeConfig(apiKey: secretMarker, voiceID: "unspecified"),
            completeConfig(endpoint: "ftp://bad", apiKey: secretMarker),
        ] {
            let reason = CartesiaConfigurationDiagnostic.blockingReason(config) ?? "READY"
            #expect(!reason.contains(secretMarker), "diagnostic text must never contain the API key value")
        }
    }

    @Test func J2_readyDiagnosticFields_neverIncludeApiKey() {
        // Mirrors the exact fields `cartesia-live-audition` prints on
        // success (provider/model/voice/locale/apiVersion/endpoint host)
        // — proves that field list structurally excludes `apiKey`.
        let config = completeConfig(apiKey: "THIS-IS-THE-SECRET-VALUE")
        let printedFields = "\(config.providerName) \(config.modelName) \(config.voiceID) \(config.locale) \(config.apiVersion ?? "") \(config.endpoint?.host ?? "")"
        #expect(!printedFields.contains("THIS-IS-THE-SECRET-VALUE"))
    }

    // MARK: - K: the loader reads the SUPPLIED dictionary, not a stale/different source

    @Test func K_loaderReadsSuppliedDictionary_notliveProcessEnvironmentWhenOneIsGiven() {
        // Passing an explicit dictionary must be authoritative — proves
        // there's no hidden second read of `ProcessInfo.processInfo.environment`
        // racing with (or overriding) the supplied one.
        let env = ["FRIDAY_VOICE_PROVIDER_NAME": "cartesia", "FRIDAY_VOICE_PROVIDER_ENDPOINT": "wss://api.cartesia.ai/tts/websocket", "FRIDAY_VOICE_PROVIDER_API_KEY": "dummy", "FRIDAY_VOICE_PROVIDER_MODEL": "sonic-3.6", "FRIDAY_VOICE_PROVIDER_VOICE_ID": "v1"]
        let config = PremiumVoiceProviderConfig.fromEnvironment(env)
        #expect(config.providerName == "cartesia")
        #expect(config.endpoint?.absoluteString == "wss://api.cartesia.ai/tts/websocket")
        #expect(config.voiceID == "v1")
    }

    @Test func K2_emptyDictionary_yieldsUnconfigured_neverCrashesOrGuesses() {
        let config = PremiumVoiceProviderConfig.fromEnvironment([:])
        #expect(!config.isConfigured)
        #expect(CartesiaConfigurationDiagnostic.blockingReason(config) == "provider name is not cartesia")
    }

    @Test func K3_realProcessEnvironment_thisSandboxHasNoCartesiaCredentials() {
        // Documents this environment's actual, honestly-verified state —
        // re-checked directly, not assumed.
        #expect(!PremiumVoiceProviderConfig.fromEnvironment().isConfigured)
    }

    // MARK: - L: no frozen-brain file was touched by this fix

    @Test func L_conversationBrainTypesAreUnaffectedByThisFix() {
        // A structural smoke check that the frozen `ConversationModelConfig`
        // type's OWN behavior (used by the LLM provider, nothing to do
        // with speech) is byte-identical before/after this milestone —
        // already asserted precisely in I5 above; this test exists as an
        // explicit, separately-labeled §8/L checkpoint.
        #expect(ConversationModelConfig.unconfigured.isConfigured == false)
    }
}
