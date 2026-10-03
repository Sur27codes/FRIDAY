import Foundation

/// P2-M5-FINAL-CLOSURE-R1 §2 — the native (Keychain + `ProductionSettings`)
/// source for the conversation-model configuration, mirroring exactly
/// how the Cartesia voice credential is resolved.
///
/// CONTRACT (proven, not guessed — see the R1 report):
///   - `friday-daemon` (the Go binary) takes NO conversation-model
///     credential/endpoint/model config at all. Its `--help` exposes
///     only socket/store/actor flags; `strings` shows no
///     `FRIDAY_CONVERSATION_*`, no LLM endpoint, no key handling. It is
///     the capability-execution + policy + runtime-store engine, not an
///     LLM client.
///   - The conversation-model contract is entirely Swift-side, read by
///     `ConversationModelConfig.fromEnvironment(_:)` from these keys:
///       FRIDAY_CONVERSATION_MODEL_ENDPOINT
///       FRIDAY_CONVERSATION_MODEL_API_KEY   (the credential)
///       FRIDAY_CONVERSATION_MODEL_NAME
///       FRIDAY_CONVERSATION_MODEL_MODE / FRIDAY_CONVERSATION_PROVIDER_MODE
///       FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING
///       FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING
///       FRIDAY_CONVERSATION_MODEL_ARCHITECTURE
///
/// This function assembles those keys from the Keychain credential and
/// the non-secret `ProductionSettings`, then hands them to the SAME,
/// completely unmodified `ConversationModelConfig.fromEnvironment(_:)`
/// parser — so a config built this way is byte-identical to one built
/// from real environment variables. Real shell env vars still take
/// priority (developer/CI mode) when present.
///
/// P2-PROD-BOOTSTRAP-R2 §2 — this resolver is now WIRED into production:
/// `AppDelegate.continueLaunching` calls it, and when the returned config
/// `isConfigured`, the production response path is
/// `ConversationalResponsePresenter.withUnifiedModelProvider(config:)` —
/// the already-frozen one-call conversational brain. When it is NOT
/// configured (no credential, or `mode == .deterministicOnly`), the
/// production path stays the fully-deterministic
/// `DeterministicResponsePresenter`, fail-closed, exactly as before.
///
/// Real shell env vars still win when fully valid (developer / CI mode);
/// production prefers native sources (Keychain + `ProductionSettings`).
///
/// - Parameter productionDefaultArchitecture: the architecture applied to
///   the NATIVE (Keychain-sourced) path when the owner's
///   `ProductionSettings` did not pin one. Defaults to `.unifiedOneCall`
///   — production must never silently run the older two-call flow
///   (P2-PROD-BOOTSTRAP-R2 §2.3). The env-var path is untouched: a
///   developer setting `FRIDAY_CONVERSATION_MODEL_*` still gets
///   `ConversationModelConfig.fromEnvironment`'s own `.twoStage` default
///   unless they set `FRIDAY_CONVERSATION_MODEL_ARCHITECTURE` too.
public func conversationModelConfigFromNativeSources(
    credentialStore: CredentialStoring,
    settings: ProductionSettings,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    productionDefaultArchitecture: ConversationModelArchitecture = .unifiedOneCall
) -> ConversationModelConfig {
    let envConfig = ConversationModelConfig.fromEnvironment(processEnvironment)
    if envConfig.isConfigured { return envConfig }

    guard let apiKey = try? credentialStore.read(.conversationProvider), !apiKey.isEmpty else {
        return envConfig // still unconfigured -> deterministic-only, exactly as today
    }

    var synthetic: [String: String] = ["FRIDAY_CONVERSATION_MODEL_API_KEY": apiKey]
    if let endpoint = settings.conversationEndpoint, !endpoint.isEmpty {
        synthetic["FRIDAY_CONVERSATION_MODEL_ENDPOINT"] = endpoint
    }
    if settings.conversationModel != "unspecified", !settings.conversationModel.isEmpty {
        synthetic["FRIDAY_CONVERSATION_MODEL_NAME"] = settings.conversationModel
    }
    // §2.3 — the native production path is one-call unless the owner
    // explicitly pinned an architecture (a future settings field); an
    // env var, if somehow set without the rest of a valid env config,
    // still wins here for developer parity.
    if let envArchitecture = processEnvironment["FRIDAY_CONVERSATION_MODEL_ARCHITECTURE"], !envArchitecture.isEmpty {
        synthetic["FRIDAY_CONVERSATION_MODEL_ARCHITECTURE"] = envArchitecture
    } else {
        synthetic["FRIDAY_CONVERSATION_MODEL_ARCHITECTURE"] = productionDefaultArchitecture.rawValue
    }
    // P2-PROD-BOOTSTRAP-R2.2 §2/§4/§5/§7 — PARITY FIX. `ConversationModelConfig.fromEnvironment`'s
    // own defaults (`temperatureEncoding: .explicit`, `tokenLimitEncoding: .none`)
    // are correct for the ENV/developer path (where a developer who needs
    // a different wire shape is expected to set the two encoding env vars
    // explicitly — unchanged here). The NATIVE path had NO way to express
    // that same explicit choice at all, so a real owner request against
    // OpenAI's gpt-5.x family failed with HTTP 400 ("Unsupported value:
    // 'temperature' does not support 0.1/0.2 with this model") — this is
    // config DRIFT between the frozen/env-tested configuration (which set
    // `FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING=omit` explicitly,
    // proven correct live against `gpt-5.6-sol` — see `ConversationModelConfig.swift`'s
    // own doc comments and `ModelProviderTests`) and the native path,
    // which silently reverted to the generic defaults.
    //
    // This branches on `settings.conversationProvider` — the OWNER'S OWN
    // EXPLICIT CHOICE from the FRIDAY Setup provider popup, already
    // persisted, non-secret configuration — the SAME kind of provider-
    // identity branch `PremiumVoiceProviderConfig.isCartesia` already uses
    // for voice (§7: "provider behavior belongs in explicit configuration,"
    // never a hidden `model.hasPrefix(...)` string hack). "OpenAI" is
    // the only choice this applies to; "OpenAI-compatible" (Groq / local /
    // other) keeps `fromEnvironment`'s ordinary defaults, since those
    // providers are documented elsewhere in this codebase as working fine
    // with the legacy `max_tokens` field and an explicit temperature.
    // An env override (developer mode) always still wins.
    // NOTE: these are the literal wire-format strings `TemperatureEncoding.init(environmentValue:)`/
    // `CompletionTokenLimitEncoding.init(environmentValue:)` actually parse
    // (snake_case) — NOT `.rawValue` (Swift's synthesized camelCase case
    // name), which would silently fail closed to the wrong default here.
    if let envValue = processEnvironment["FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING"] {
        synthetic["FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING"] = envValue
    } else if settings.conversationProvider == "openai" {
        synthetic["FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING"] = "omit"
    }
    if let envValue = processEnvironment["FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING"] {
        synthetic["FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING"] = envValue
    } else if settings.conversationProvider == "openai" {
        synthetic["FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING"] = "max_completion_tokens"
    }
    return ConversationModelConfig.fromEnvironment(synthetic)
}

/// P2-M5V9-B.3C / P2-PROD-BOOTSTRAP §B4 — the native (Keychain +
/// `ProductionSettings`) source for the Cartesia voice-provider config,
/// exactly mirroring `conversationModelConfigFromNativeSources` above.
/// Real `FRIDAY_VOICE_PROVIDER_*` shell env vars still win when set
/// (developer / CI); production prefers the Keychain credential + the
/// frozen, owner-accepted FRIDAY Voice V1 Skylar identity (Cartesia
/// `sonic-3.6`, voice `db6b0ed5-d5d3-463d-ae85-518a07d3c2b4`, en-US).
///
/// This is the single definition both `AppDelegate` (production wiring)
/// and `SetupWindowController` (the "Test Connection" probe) call — the
/// frozen identity constants live here, once.
public enum FridayVoiceV1Identity {
    public static let providerName = "cartesia"
    public static let endpoint = "wss://api.cartesia.ai/tts/websocket"
    public static let model = "sonic-3.6"
    public static let voiceID = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
    public static let voiceDisplayName = "Skylar"
    public static let locale = "en-US"
    public static let apiVersion = "2026-08-14"
}

public func premiumVoiceProviderConfigFromNativeSources(
    credentialStore: CredentialStoring,
    settings: ProductionSettings,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
) -> PremiumVoiceProviderConfig {
    let envConfig = PremiumVoiceProviderConfig.fromEnvironment(processEnvironment)
    if envConfig.isConfigured { return envConfig }

    guard let apiKey = try? credentialStore.read(.cartesiaVoiceProvider), !apiKey.isEmpty else {
        return envConfig // still unconfigured -> Samantha/Chatterbox fallback, exactly as before
    }
    let synthetic: [String: String] = [
        "FRIDAY_VOICE_PROVIDER_NAME": FridayVoiceV1Identity.providerName,
        "FRIDAY_VOICE_PROVIDER_ENDPOINT": FridayVoiceV1Identity.endpoint,
        "FRIDAY_VOICE_PROVIDER_API_KEY": apiKey,
        "FRIDAY_VOICE_PROVIDER_MODEL": FridayVoiceV1Identity.model,
        "FRIDAY_VOICE_PROVIDER_VOICE_ID": FridayVoiceV1Identity.voiceID,
        "FRIDAY_VOICE_PROVIDER_LOCALE": FridayVoiceV1Identity.locale,
        "FRIDAY_VOICE_PROVIDER_API_VERSION": FridayVoiceV1Identity.apiVersion,
    ]
    return PremiumVoiceProviderConfig.fromEnvironment(synthetic)
}
