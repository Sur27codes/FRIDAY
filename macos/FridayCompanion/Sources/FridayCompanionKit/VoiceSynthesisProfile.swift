import AVFoundation
import Foundation

/// P2-M5V9-B §2 — the provider-neutral voice identity/config abstraction
/// the mission asks for ("VoiceIdentity / VoiceProvider / VoiceModel /
/// VoiceSynthesisProfile"). Deliberately a COMPOSITION of types V9-A
/// already built and already tested (`PremiumVoiceProfile` for the
/// stable identity, `PremiumSpeechCapabilities` for what the engine
/// actually supports) rather than a fourth, parallel identity concept —
/// §10's "do not rebuild from scratch" applies here as much as to the
/// streaming machinery. No core presentation code branches on `provider`/
/// `model` strings directly (§2: "do not hard-code one cloud vendor into
/// core speech architecture") — those two fields exist purely for
/// diagnostics/config selection; every actual behavioral decision still
/// goes through `PremiumSpeechCapabilities`.
public struct VoiceSynthesisProfile: Sendable, Equatable {
    /// Free-form, diagnostics-only vendor label (e.g. "generic-http",
    /// "local") — never switched on by presentation logic.
    public let provider: String
    /// Free-form, diagnostics-only model/engine label.
    public let model: String
    /// The stable, versioned voice selection (§72 of P2-M5V9 — never a
    /// mutable display name).
    public let voiceIdentity: PremiumVoiceProfile
    public let locale: String
    /// The engine's own baseline speaking rate, expressed on the SAME
    /// `AVSpeechUtterance.rate` scale `VoiceProfile` already uses, so a
    /// caller wiring this into `ProsodyPlan`/`VoiceProfile` never needs a
    /// second unit system.
    public let speakingRateBaseline: Float
    /// What this specific engine/voice combination actually supports —
    /// queried, never assumed (§31 of P2-M5V9).
    public let capabilities: PremiumSpeechCapabilities

    public init(provider: String, model: String, voiceIdentity: PremiumVoiceProfile, locale: String, speakingRateBaseline: Float, capabilities: PremiumSpeechCapabilities) {
        self.provider = provider
        self.model = model
        self.voiceIdentity = voiceIdentity
        self.locale = locale
        self.speakingRateBaseline = VoiceProfile.clampRate(speakingRateBaseline)
        self.capabilities = capabilities
    }

    /// The safe, zero-configuration default — describes "no premium
    /// engine selected," mirroring `PremiumVoiceProfile`'s own
    /// `unconfigured` shape used by `PremiumNeuralSpeechSynthesizer`'s
    /// default initializer. Never used to attempt a real synthesis call.
    public static let unconfigured = VoiceSynthesisProfile(
        provider: "none", model: "none",
        voiceIdentity: PremiumVoiceProfile(voiceProfileID: "unconfigured", providerID: "none", providerVoiceID: "none", profileVersion: "0"),
        locale: "en-US", speakingRateBaseline: AVSpeechUtteranceDefaultSpeechRate, capabilities: .none
    )
}

/// P2-M5V9-B §2/§16/§17 — provider configuration, read ONLY from
/// environment variables (mirrors `ConversationModelConfig`'s own,
/// already-established convention exactly — same env-var-only sourcing,
/// same `isConfigured` fail-closed gate, same HTTPS/localhost allow-list)
/// so a real cloud neural voice can be wired in later with ZERO code
/// changes anywhere else, purely by setting environment variables. Absent
/// by default: every existing call site (`PremiumNeuralSpeechSynthesizer()`,
/// `ConversationalResponsePresenter()`, `AppDelegate`'s own production
/// wiring before this milestone) keeps behaving exactly as before unless
/// a caller explicitly opts into `.fromEnvironment()`.
public struct PremiumVoiceProviderConfig: Sendable, Equatable {
    public let endpoint: URL?
    public let apiKey: String?
    public let providerName: String
    public let modelName: String
    public let voiceID: String
    public let locale: String
    public let connectTimeout: TimeInterval
    public let requestTimeout: TimeInterval
    /// P2-M5V9-B.1 §10 — additional candidate voice ids for audition,
    /// beyond the single primary `voiceID` above (which stays the
    /// production selection every OTHER call site uses unchanged). Empty
    /// unless the engine genuinely exposes more than one synthetic
    /// speaker AND the owner has listed them — never a guess, never
    /// auto-populated. `auditionCandidateVoiceIDs` (below) is the
    /// correct thing to iterate for a 3-5-candidate audition; this field
    /// alone is never mutually exclusive with `voiceID` — if empty,
    /// `voiceID` is still the one real candidate.
    public let additionalCandidateVoiceIDs: [String]
    /// P2-M5V9-B.2 §6 — a provider-specific version pin (e.g. Cartesia's
    /// `Cartesia-Version` header), stored generically here rather than
    /// as a Cartesia-only field so the config type stays provider-
    /// neutral (§26) — an unrelated provider simply never reads it.
    public let apiVersion: String?

    public init(
        endpoint: URL?, apiKey: String?, providerName: String = "unspecified", modelName: String = "unspecified",
        voiceID: String = "unspecified", locale: String = "en-US", connectTimeout: TimeInterval = 3.0, requestTimeout: TimeInterval = 10.0,
        additionalCandidateVoiceIDs: [String] = [], apiVersion: String? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.providerName = providerName
        self.modelName = modelName
        self.voiceID = voiceID
        self.locale = locale
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.additionalCandidateVoiceIDs = additionalCandidateVoiceIDs
        self.apiVersion = apiVersion
    }

    /// True only when a real network attempt would actually be made —
    /// same fail-closed shape as `ConversationModelConfig.isConfigured`.
    ///
    /// P2-M5V9-B.2A §1/§3 — CONFIRMED ROOT CAUSE of the reported bug: this
    /// used to delegate unconditionally to `ConversationModelConfig.isEndpointAllowed`,
    /// which was written for a synchronous REST LLM API and correctly
    /// never allows `wss://` — reusing it here silently rejected a
    /// genuinely valid, fully-credentialed Cartesia realtime endpoint
    /// (`wss://api.cartesia.ai/tts/websocket`), because `wss` was never
    /// in that function's allow-list. Proven directly (not guessed):
    /// `ConversationModelConfig.isEndpointAllowed(URL(string: "wss://api.cartesia.ai/tts/websocket")!)`
    /// returns `false`. Fixed by routing through the new, provider-aware
    /// `isEndpointAllowed(_:isCartesia:)` below instead.
    public var isConfigured: Bool {
        guard let endpoint, !(apiKey ?? "").isEmpty else { return false }
        return Self.isEndpointAllowed(endpoint, isCartesia: isCartesia)
    }

    /// P2-M5V9-B.2A §3 — scheme validation appropriate to EACH provider
    /// type, not one shared REST-only rule for everyone. Cartesia's
    /// realtime path is a WebSocket endpoint — `wss://` is its correct,
    /// secure scheme (the WebSocket analogue of `https://`), never a
    /// plaintext-remote loophole; `ws://` is allowed only for the same
    /// local-development-loopback exception `http://` already gets.
    /// Any OTHER provider's validation is UNCHANGED — this narrows new
    /// scheme acceptance to Cartesia specifically rather than loosening
    /// the shared `ConversationModelConfig.isEndpointAllowed` validator
    /// (still used, untouched, by the LLM conversation-model config).
    public static func isEndpointAllowed(_ url: URL, isCartesia: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if isCartesia {
            if scheme == "wss" { return true }
            if scheme == "ws" {
                let localDevelopmentHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
                return localDevelopmentHosts.contains(host)
            }
            // Falls through below — a Cartesia config MAY also point at
            // Cartesia's REST bytes endpoint (§3 of P2-M5V9-B.2: "use it
            // for connectivity test/audition/diagnostics"), which is a
            // plain `https://` URL exactly like any other REST provider.
        }
        return ConversationModelConfig.isEndpointAllowed(url)
    }

    /// §10/§12 — the full ordered candidate list an audition should
    /// iterate: the primary `voiceID` first, then every additional id,
    /// with exact duplicates removed (never auditioning the same voice
    /// id against itself twice). Empty when `voiceID` itself is the
    /// unconfigured placeholder.
    public var auditionCandidateVoiceIDs: [String] {
        guard voiceID != "unspecified" else { return [] }
        var seen = Set<String>()
        return ([voiceID] + additionalCandidateVoiceIDs).filter { seen.insert($0).inserted }
    }

    public static let unconfigured = PremiumVoiceProviderConfig(endpoint: nil, apiKey: nil)

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PremiumVoiceProviderConfig {
        let additionalVoiceIDs = (environment["FRIDAY_VOICE_PROVIDER_VOICE_IDS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return PremiumVoiceProviderConfig(
            endpoint: environment["FRIDAY_VOICE_PROVIDER_ENDPOINT"].flatMap(URL.init(string:)),
            apiKey: environment["FRIDAY_VOICE_PROVIDER_API_KEY"],
            providerName: environment["FRIDAY_VOICE_PROVIDER_NAME"] ?? "unspecified",
            modelName: environment["FRIDAY_VOICE_PROVIDER_MODEL"] ?? "unspecified",
            voiceID: environment["FRIDAY_VOICE_PROVIDER_VOICE_ID"] ?? "unspecified",
            locale: environment["FRIDAY_VOICE_PROVIDER_LOCALE"] ?? "en-US",
            additionalCandidateVoiceIDs: additionalVoiceIDs,
            apiVersion: environment["FRIDAY_VOICE_PROVIDER_API_VERSION"]
        )
    }

    /// True only for the specific provider name this milestone's Cartesia
    /// adapter is written for — a plain string comparison kept in exactly
    /// ONE place (§7 of P2-M5V9-B.2: "no provider-specific branching
    /// scattered through presenter code"). Any OTHER `providerName`
    /// value is simply never routed to `CartesiaSpeechStreamProvider`.
    public var isCartesia: Bool { providerName.lowercased() == "cartesia" }
}

/// P2-M5V9-B.2A §4 — replaces the misleading catch-all
/// "BLOCKED — OWNER CARTESIA CREDENTIAL REQUIRED" (which fired even when
/// every credential was genuinely present, per §3's endpoint-scheme bug)
/// with an EXACT, sanitized reason. Never includes the API key's value —
/// only whether it is present. Kept as its own small, directly-testable
/// type (rather than inline in `VoiceAuditionTool`) so each specific
/// failure mode has its own regression test (§8 of this milestone).
public enum CartesiaConfigurationDiagnostic {
    /// `nil` means genuinely ready to attempt a real Cartesia connection.
    /// Otherwise, a short, exact, owner-facing reason — never the secret
    /// itself, never a raw header, never a length/hash of the key.
    public static func blockingReason(_ config: PremiumVoiceProviderConfig) -> String? {
        guard config.isCartesia else { return "provider name is not cartesia" }
        guard let endpoint = config.endpoint else { return "Cartesia endpoint missing" }
        guard PremiumVoiceProviderConfig.isEndpointAllowed(endpoint, isCartesia: true) else { return "invalid Cartesia endpoint scheme" }
        guard !(config.apiKey ?? "").isEmpty else { return "FRIDAY_VOICE_PROVIDER_API_KEY missing" }
        guard !config.modelName.isEmpty, config.modelName != "unspecified" else { return "Cartesia model missing" }
        guard !config.voiceID.isEmpty, config.voiceID != "unspecified" else { return "Cartesia voice ID missing" }
        // §2: locale defaults to en-US and apiVersion has no required
        // default — neither can ever block readiness; `FRIDAY_VOICE_PROVIDER_VOICE_IDS`
        // is optional multi-candidate audition data, never checked here.
        return nil
    }
}

/// P2-M5V9-B.1 §25/§26 — the persisted, stable FRIDAY voice identity,
/// deliberately INDEPENDENT of any provider's own API-side naming (§26:
/// "do not equate FRIDAY voice identity with provider API name"), so a
/// future migration to a different cloud provider, a local neural model,
/// or a custom-trained model can carry the SAME conceptual identity
/// (`identityID`/`version`) forward with zero conversation-code changes —
/// only this record's own `provider`/`model`/`providerVoiceID` fields
/// would ever need to change. NEVER carries a credential/secret (§25's
/// own explicit "do not persist secret credentials here" — this record
/// is safe to log, store in a plain config file, or check in). `nil`
/// until an owner has actually AUDITIONED and SELECTED a candidate —
/// this milestone builds the mechanism; it does not itself choose a
/// winner (§31: "STOP... owner has NOT YET selected candidate").
public struct FridayVoiceIdentityLock: Sendable, Equatable, Codable {
    public let identityID: String
    public let version: String
    public let provider: String
    public let model: String
    public let providerVoiceID: String
    public let locale: String
    public let baseRate: Float
    public let basePitch: Float
    public let baseVolume: Float

    public init(identityID: String, version: String, provider: String, model: String, providerVoiceID: String, locale: String, baseRate: Float, basePitch: Float, baseVolume: Float) {
        self.identityID = identityID
        self.version = version
        self.provider = provider
        self.model = model
        self.providerVoiceID = providerVoiceID
        self.locale = locale
        self.baseRate = baseRate
        self.basePitch = basePitch
        self.baseVolume = baseVolume
    }

    /// The mission's own named V1 identity/version (§25), pre-filled so
    /// locking is a one-line call once an owner selects a candidate —
    /// never auto-invoked by any code in this repository.
    public static func v1(provider: String, model: String, providerVoiceID: String, locale: String, base: VoiceProfile) -> FridayVoiceIdentityLock {
        FridayVoiceIdentityLock(
            identityID: "friday-original-01", version: "1.0", provider: provider, model: model,
            providerVoiceID: providerVoiceID, locale: locale, baseRate: base.rate, basePitch: base.pitchMultiplier, baseVolume: base.volume
        )
    }
}
