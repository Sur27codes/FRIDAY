import Foundation

/// P2-M5V8 §3/§4/§32, extended by P2-M5V8.1 §2/§4/§20 — provider
/// configuration, read ONLY from environment variables (matching this
/// codebase's existing `FRIDAY_WAKE_DIAGNOSTICS`-style convention in
/// `AppDelegate.swift`) — never hardcoded, never a literal default
/// endpoint/key, never committed anywhere. `isConfigured` is `false`
/// unless an endpoint and API key are genuinely present, the mode allows
/// network use, AND the endpoint passes the HTTPS/localhost gate (§4) —
/// which is exactly the condition `ModelConversationReasoner`/`ModelNaturalResponseRealizer`
/// use to decide whether to attempt a real network call at all — the
/// provider is fully optional by construction (§4 of P2-M5V8: "FRIDAY
/// must continue working with zero model credentials").
///
/// This type deliberately targets the widely-supported OpenAI-compatible
/// "chat completions" HTTP shape (`POST {endpoint}`, `Authorization:
/// Bearer {apiKey}`, a `model` field, a `messages` array) rather than any
/// single vendor's proprietary SDK — many providers (including
/// self-hosted/local inference servers) implement this exact shape, so
/// "provider-neutral" here means "one widely-adopted wire format," per
/// §3's own instruction to build "provider-neutral HTTP/model-client
/// infrastructure" rather than hard-wiring one vendor.
public struct ConversationModelConfig: Sendable, Equatable {
    public let endpoint: URL?
    public let apiKey: String?
    public let modelName: String
    /// §19 of P2-M5V8 — three independently bounded timeouts, never
    /// infinite.
    public let connectTimeout: TimeInterval
    public let requestTimeout: TimeInterval
    public let overallDeadline: TimeInterval
    /// §32 of P2-M5V8 / §2 of P2-M5V8.1 — the explicit, non-hidden
    /// developer switch. `.deterministicOnly` means
    /// `ModelConversationReasoner`/`ModelNaturalResponseRealizer` are
    /// never even attempted, regardless of whether credentials are
    /// present — a genuine kill switch independent of configuration.
    public let mode: ConversationProviderMode
    /// P2-M5V8.1 §19 — conservative, documented, explicitly DIFFERENT
    /// per stage (reasoning wants highly consistent, low-variability
    /// output; realization may vary modestly for natural-sounding
    /// phrasing) — never left to a provider's own undocumented default.
    public let reasoningTemperature: Double
    public let realizationTemperature: Double
    /// P2-M5V8.1-HW — which wire field (if any) carries the requested
    /// completion-token budget. See `CompletionTokenLimitEncoding`'s own
    /// doc comment for why this defaults to `.none` (today's pre-existing
    /// behavior) rather than guessing per provider/model.
    public let tokenLimitEncoding: CompletionTokenLimitEncoding
    /// P2-M5V8.1-HW (sampling-capability fix) — whether the outgoing
    /// request's `temperature` field is sent at all. See `TemperatureEncoding`'s
    /// own doc comment.
    public let temperatureEncoding: TemperatureEncoding
    /// P2-M5V8.1-O §18 — the controlled, explicit mode switch between the
    /// original two-call architecture and the new one-call architecture.
    /// See `ConversationModelArchitecture`'s own doc comment for the
    /// fail-closed default.
    public let architecture: ConversationModelArchitecture
    /// P2-M5V8.1-O §17 — a SEPARATE, repository-consistent sampling value
    /// used ONLY by the one-call (`architecture == .unifiedOneCall`) path,
    /// never assumed to be either `reasoningTemperature` or
    /// `realizationTemperature` (§17: "do not assume the old reasoner
    /// temperature and realizer temperature can both apply"). Defaults to
    /// a low/moderate deterministic-leaning value, closer to
    /// `reasoningTemperature`'s conservative end (schema reliability
    /// matters most, since a rejected/invalid unified response loses the
    /// ENTIRE turn's provider contribution, not just one stage) while
    /// still leaving room for natural-sounding candidate wording.
    public let unifiedTemperature: Double

    /// True only when a real network attempt would actually be made:
    /// mode allows it, both credentials are present, AND the endpoint
    /// passes `ConversationModelConfig.isEndpointAllowed` (§4 of
    /// P2-M5V8.1 — HTTPS required for any non-localhost endpoint; a
    /// disallowed plaintext-remote-HTTP endpoint is treated identically
    /// to "not configured," failing closed to the deterministic path
    /// with zero extra code anywhere else in the pipeline).
    public var isConfigured: Bool {
        guard mode != .deterministicOnly, let endpoint, !(apiKey ?? "").isEmpty else { return false }
        return Self.isEndpointAllowed(endpoint)
    }

    public init(
        endpoint: URL?, apiKey: String?, modelName: String,
        // P2-M5V8.1-R §6 — requestTimeout/overallDeadline raised from
        // 6.0/8.0, REAL evidence (not guessed): of 6 real, live calls run
        // in the same forensic pass, the 5 short-answer turns all
        // succeeded well within the old deadlines, but the one genuinely
        // longer-output turn (the mission's own "explain machine learning
        // in five sentences" acceptance phrase — real, structured,
        // reasoning-model generation of a combined reasoning+response
        // document, further lengthened by this pass's own
        // `maxUnifiedCompletionTokens` increase) hit `providerTransportResult:
        // timeout`. connectTimeout is untouched — the connection itself
        // was never the slow part. Every existing test that cares about a
        // SPECIFIC (short) timeout value already constructs its own
        // explicit override (e.g. `UnifiedConversationArchitectureTests
        // .fastUnifiedConfig`), so this default change is invisible to
        // them; only real network calls using the unmodified default are
        // affected, and only by being given more real time to finish
        // before being treated as a genuine failure — never less.
        connectTimeout: TimeInterval = 3.0, requestTimeout: TimeInterval = 14.0, overallDeadline: TimeInterval = 18.0,
        mode: ConversationProviderMode = .modelPreferredWithFallback,
        reasoningTemperature: Double = 0.1, realizationTemperature: Double = 0.4,
        tokenLimitEncoding: CompletionTokenLimitEncoding = .none,
        temperatureEncoding: TemperatureEncoding = .explicit,
        architecture: ConversationModelArchitecture = .twoStage,
        unifiedTemperature: Double = 0.2
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelName = modelName
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.overallDeadline = overallDeadline
        self.mode = mode
        self.reasoningTemperature = reasoningTemperature
        self.realizationTemperature = realizationTemperature
        self.tokenLimitEncoding = tokenLimitEncoding
        self.temperatureEncoding = temperatureEncoding
        self.architecture = architecture
        self.unifiedTemperature = unifiedTemperature
    }

    /// P2-M5V8.1-O §19 — a small, pure convenience for the A/B harness
    /// (`VoiceAuditionTool`): returns a copy of this config with only
    /// `architecture` changed, every other field (credentials, timeouts,
    /// token/temperature encoding) preserved exactly — lets the harness
    /// compare TWO-STAGE and ONE-CALL against the SAME owner-configured
    /// credentials in a single run, without the owner re-invoking the
    /// tool with a different environment variable.
    public func withArchitecture(_ architecture: ConversationModelArchitecture) -> ConversationModelConfig {
        ConversationModelConfig(
            endpoint: endpoint, apiKey: apiKey, modelName: modelName,
            connectTimeout: connectTimeout, requestTimeout: requestTimeout, overallDeadline: overallDeadline,
            mode: mode, reasoningTemperature: reasoningTemperature, realizationTemperature: realizationTemperature,
            tokenLimitEncoding: tokenLimitEncoding, temperatureEncoding: temperatureEncoding,
            architecture: architecture, unifiedTemperature: unifiedTemperature
        )
    }

    /// Reads `FRIDAY_CONVERSATION_MODEL_ENDPOINT`/`_API_KEY`/`_NAME`/`_MODE`
    /// from the process environment — the SAME mechanism `AppDelegate.swift`
    /// already uses for `FRIDAY_WAKE_DIAGNOSTICS`. Absent any of these,
    /// `isConfigured` is `false` and every conversational behavior is
    /// byte-identical to P2-M5V7 (deterministic-only). **No default
    /// endpoint or key is ever substituted** — an owner who wants to
    /// evaluate a real provider must explicitly set these.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ConversationModelConfig {
        let endpoint = environment["FRIDAY_CONVERSATION_MODEL_ENDPOINT"].flatMap(URL.init(string:))
        let apiKey = environment["FRIDAY_CONVERSATION_MODEL_API_KEY"]
        let modelName = environment["FRIDAY_CONVERSATION_MODEL_NAME"] ?? "unspecified"
        let mode = ConversationProviderMode(environmentValue: environment["FRIDAY_CONVERSATION_MODEL_MODE"] ?? environment["FRIDAY_CONVERSATION_PROVIDER_MODE"])
        let tokenLimitEncoding = CompletionTokenLimitEncoding(environmentValue: environment["FRIDAY_CONVERSATION_MODEL_TOKEN_LIMIT_ENCODING"])
        let temperatureEncoding = TemperatureEncoding(environmentValue: environment["FRIDAY_CONVERSATION_MODEL_TEMPERATURE_ENCODING"])
        let architecture = ConversationModelArchitecture(environmentValue: environment["FRIDAY_CONVERSATION_MODEL_ARCHITECTURE"])
        return ConversationModelConfig(
            endpoint: endpoint, apiKey: apiKey, modelName: modelName, mode: mode,
            tokenLimitEncoding: tokenLimitEncoding, temperatureEncoding: temperatureEncoding, architecture: architecture
        )
    }

    /// The safe, zero-credential default — used whenever a caller
    /// doesn't explicitly ask for environment-derived configuration
    /// (e.g. every existing test, and `ConversationalResponsePresenter`'s
    /// own default construction) so behavior never silently depends on
    /// whatever happens to be in the calling process's environment.
    public static let unconfigured = ConversationModelConfig(endpoint: nil, apiKey: nil, modelName: "unspecified")

    /// P2-M5V8.1 §4 — "do not permit arbitrary remote plaintext HTTP."
    /// HTTPS is required for any endpoint EXCEPT an explicit local
    /// development loopback address (127.0.0.1 / localhost / ::1),
    /// which may use plain HTTP (a common shape for a local inference
    /// server during development). Any other scheme, or a remote host
    /// over `http://`, is rejected outright.
    public static func isEndpointAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            let localDevelopmentHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
            return localDevelopmentHosts.contains(host)
        }
        return false
    }
}

/// P2-M5V8 §32 / P2-M5V8.1 §2 — explicit, documented, never a "hidden
/// magic flag." Read directly from `FRIDAY_CONVERSATION_MODEL_MODE`
/// (falling back to the older `FRIDAY_CONVERSATION_PROVIDER_MODE` name
/// for compatibility with P2-M5V8's own documented variable). An
/// EXPLICITLY-SET but unrecognized value fails CLOSED to `.deterministicOnly`
/// (§2 of P2-M5V8.1: "invalid mode -> fail closed to deterministic-only")
/// — a typo in this env var must never silently enable network calls. An
/// ABSENT value (the variable was never set at all) is a different case —
/// it keeps P2-M5V8's own established default, `.modelPreferredWithFallback`,
/// which only matters once credentials also exist (an absent mode plus no
/// credentials is still fully inert).
public enum ConversationProviderMode: Sendable, Equatable {
    case deterministicOnly
    case modelPreferredWithFallback
    /// P2-M5V8.1 §2 — "run deterministic and model paths for comparison;
    /// do NOT alter production preference." Distinct from
    /// `.modelPreferredWithFallback` for callers (like the
    /// `provider-dialogue` harness) that want to make this intent
    /// explicit; `ConversationModelConfig.isConfigured`/`ModelConversationReasoner`/
    /// `ModelNaturalResponseRealizer` treat it identically to
    /// `.modelPreferredWithFallback` for the purpose of "is a network
    /// attempt allowed at all" — the actual A/B comparison behavior
    /// (running BOTH paths and presenting both) lives in the harness
    /// itself, not in this enum, since `ConversationReasoning`/
    /// `NaturalConversationRealizing` each only ever produce ONE result
    /// per call by protocol design (§0: preserve those signatures).
    case modelEvaluation

    init(environmentValue: String?) {
        guard let environmentValue, !environmentValue.isEmpty else {
            self = .modelPreferredWithFallback
            return
        }
        switch environmentValue.lowercased() {
        case "deterministic-only", "deterministic": self = .deterministicOnly
        case "model-preferred-with-fallback", "model-preferred": self = .modelPreferredWithFallback
        case "model-evaluation", "evaluation": self = .modelEvaluation
        default: self = .deterministicOnly // fail closed — never silently model-preferred on a typo
        }
    }
}

/// P2-M5V8.1-HW — OpenAI transport compatibility fix. Which wire field (if
/// any) carries the requested completion-token budget. This is PROVIDER
/// CONFIGURATION, never inferred from a model-name substring: a live owner
/// probe against `gpt-5.6-sol` proved `max_tokens` is REJECTED (HTTP 400
/// `unsupported_parameter`) while `max_completion_tokens` is ACCEPTED
/// (HTTP 200) on that specific provider/model. Rather than guessing this
/// for every model, FRIDAY defaults to sending NEITHER field (`.none` —
/// today's actual, already-tested behavior) unless the owner explicitly
/// opts a configured provider into one specific encoding. Neither
/// `ConversationReasoning` nor `NaturalConversationRealizing` implementations
/// ever see or reason about this — it is a wire-level concern owned
/// entirely by `ConversationModelRequestBuilder`.
public enum CompletionTokenLimitEncoding: String, Sendable, Equatable {
    /// Sends neither field — the pre-existing, still-default behavior.
    /// Correct for any provider/model not yet proven to need an explicit
    /// completion-token cap.
    case none
    /// The long-standing OpenAI-compatible field name — still correct for
    /// most OpenAI-compatible providers (e.g. Groq) and older OpenAI models.
    case maxTokens
    /// Required by newer OpenAI models — proven live against `gpt-5.6-sol`:
    /// `max_tokens` → HTTP 400 `unsupported_parameter`; `max_completion_tokens`
    /// → HTTP 200.
    case maxCompletionTokens

    /// An explicitly-set but unrecognized value fails CLOSED to `.none`
    /// — the same "a typo must never silently change wire behavior" rule
    /// `ConversationProviderMode` already applies to its own env var. An
    /// absent variable also resolves to `.none`, so every existing
    /// deployment/test keeps its exact current request shape unless the
    /// owner explicitly opts in.
    public init(environmentValue: String?) {
        guard let raw = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            self = .none
            return
        }
        switch raw {
        case "max_tokens", "max-tokens": self = .maxTokens
        case "max_completion_tokens", "max-completion-tokens": self = .maxCompletionTokens
        default: self = .none
        }
    }
}

/// P2-M5V8.1-HW (sampling-capability fix) — whether the outgoing request's
/// `temperature` field is sent at all. This is PROVIDER CONFIGURATION,
/// never inferred from a model-name substring: a live owner probe against
/// `gpt-5.6-sol` proved the provider REJECTS an explicit, non-default
/// temperature outright ("Unsupported value: 'temperature' does not
/// support 0 with this model. Only the default (1) value is supported.").
/// Rather than guessing a magic "supported" value per model, FRIDAY omits
/// the field entirely when told to — letting the provider use its own
/// default — and otherwise sends FRIDAY's own logical, documented
/// `reasoningTemperature`/`realizationTemperature` unchanged (§5: "preserve
/// logical temperature settings" — those values still exist and are still
/// meaningful for providers that DO support explicit sampling; this enum
/// only decides whether the wire carries them).
public enum TemperatureEncoding: String, Sendable, Equatable {
    /// Sends no `temperature` field at all — the provider uses its own
    /// default. Correct for a provider/model proven to reject explicit
    /// sampling control (e.g. `gpt-5.6-sol`).
    case omit
    /// Sends the caller's configured logical temperature value — the
    /// pre-existing, still-default behavior, correct for the many
    /// OpenAI-compatible providers/models that DO support explicit
    /// sampling control.
    case explicit

    /// An explicitly-set but unrecognized value fails CLOSED to `.explicit`
    /// — the pre-existing behavior, so a typo can never silently start
    /// omitting a field every existing deployment/test currently relies on
    /// being sent. An absent variable resolves to the same `.explicit`
    /// default for the identical reason (mirrors `CompletionTokenLimitEncoding`'s
    /// own "absent and invalid both preserve today's exact behavior" rule).
    public init(environmentValue: String?) {
        guard let raw = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            self = .explicit
            return
        }
        switch raw {
        case "omit": self = .omit
        case "explicit": self = .explicit
        default: self = .explicit
        }
    }
}

/// P2-M5V8.1-O §18 — the explicit, non-hidden switch between the
/// ORIGINAL two-call architecture (separate `ModelConversationReasoner` +
/// `ModelNaturalResponseRealizer` network round trips — `.twoStage`) and
/// the new one-call architecture (§1: a single provider round trip
/// carrying both a reasoning proposal and candidate wording —
/// `.unifiedOneCall`). Read directly from `FRIDAY_CONVERSATION_MODEL_ARCHITECTURE`.
/// Fails CLOSED to `.twoStage` on any absent/unrecognized value — the
/// SAME "typo must never silently change production behavior" discipline
/// every other provider-configuration enum in this file already applies
/// (§18: "default during evaluation should remain safe/explicit; do not
/// silently change production behavior") — `.twoStage` is exactly today's
/// existing, already-proven, unchanged behavior.
public enum ConversationModelArchitecture: String, Sendable, Equatable {
    case twoStage
    case unifiedOneCall

    public init(environmentValue: String?) {
        guard let raw = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            self = .twoStage
            return
        }
        switch raw {
        case "two-stage", "two_stage", "twostage": self = .twoStage
        case "unified-one-call", "unified_one_call", "unifiedonecall", "one-call", "onecall": self = .unifiedOneCall
        default: self = .twoStage
        }
    }
}

/// P2-M5V8.1 §20 — explicit, documented request-size bounds. Every
/// number here is a real, enforced limit (see `ModelConversationReasoner`/
/// `ModelNaturalResponseRealizer`'s request builders), not aspirational
/// documentation — a payload that would exceed `maxSerializedContextBytes`
/// after every other truncation is rejected outright (the request is
/// never sent), which safely degrades to the deterministic fallback via
/// the same `nil`-return contract every other request-building failure
/// already uses.
public enum ConversationModelLimits {
    public static let maxTranscriptCharacters = 500
    public static let maxRecentTurns = 5
    public static let maxCharactersPerHistoricalTurn = 300
    public static let maxSerializedContextBytes = 8000
    /// P2-M5V8.1-O.3 §6/§7 — the ONE-CALL path's own, LARGER request-size
    /// ceiling. Root cause: fixing the live `continuationReference`/
    /// `humorSuitability`/`uncertainty` type-contract bug required adding
    /// explicit JSON-type instructions to the unified system prompt
    /// (SECTION C) — this alone pushed the COMBINED system prompt (already
    /// larger than either single-stage prompt, by design — it teaches
    /// BOTH the reasoning vocabulary AND the realization persona in one
    /// text) past the shared `maxSerializedContextBytes` ceiling, so
    /// EVERY unified request started failing locally, before any network
    /// attempt — never touching a token/completion budget at all. A
    /// dedicated, still-bounded (not "unbounded") ceiling for the unified
    /// path alone leaves `maxSerializedContextBytes` completely UNCHANGED
    /// for `ModelConversationReasoner`/`ModelNaturalResponseRealizer`.
    public static let maxUnifiedSerializedContextBytes = 12000
    /// Reuses the SAME bound `DeterministicResponsePresenter`/
    /// `ConversationModelSchema` already enforce on spoken text — one
    /// number, never two competing limits for "how long can FRIDAY's
    /// spoken response be."
    public static let maxModelOutputCharacters = DeterministicResponsePresenter.maxSpokenLength
    /// P2-M5V8.1-HW — the completion-token budget requested when
    /// `ConversationModelConfig.tokenLimitEncoding` is anything other than
    /// `.none`. Conservative — matches the "concise, not verbose" persona
    /// requirement and keeps latency/cost bounded even though the expected
    /// response is small structured JSON, not free-form prose.
    public static let maxCompletionTokens = 400
    /// P2-M5V8.1-O.1 §7/§23 — the ONE-CALL path's own, LARGER completion-
    /// token budget. Root-cause analysis of the live 21/21 unified
    /// failure (see `ModelUnifiedConversationProvider`'s own doc comment)
    /// found the unified request was reusing `maxCompletionTokens` (400)
    /// UNCHANGED even though its response combines TWO objects
    /// (`reasoning` + `response`) into one JSON document — structurally
    /// larger than either single-stage payload — while ALSO being sent
    /// to a reasoning-capable model, which (per OpenAI's own documented
    /// behavior) can spend part of that SAME budget on invisible
    /// reasoning tokens before any visible content is produced. This
    /// value is deliberately still bounded (not "unbounded" — §7's own
    /// explicit constraint), just proportioned to what a combined
    /// payload structurally needs; it does NOT change `maxCompletionTokens`
    /// itself, so `ModelConversationReasoner`/`ModelNaturalResponseRealizer`
    /// (neither of which reference this constant) are completely unaffected.
    ///
    /// P2-M5V8.1-R §6 — raised from 900, REAL evidence (not guessed):
    /// real runs of the mission's own acceptance phrase repeatedly
    /// produced malformedResponse/timeout outcomes even for a genuinely
    /// correct, well-formed candidate (confirmed once by inspecting the
    /// actual raw content — a real, on-topic five-sentence answer,
    /// visibly cut off mid-generation) — exactly the invisible-reasoning-
    /// token risk this constant's own doc comment above already
    /// disclosed, now compounded by `maxSpokenLength`'s own increase (a
    /// longer permitted response needs more visible-token headroom too,
    /// on top of the same unpredictable reasoning-token tax). Still a
    /// real, bounded ceiling, not "unbounded."
    public static let maxUnifiedCompletionTokens = 2000

    static func truncated(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// P2-M5V8.1-O.6 §5/§6 — a single, shared history-cost measurement
    /// used by all three request builders' diagnostics (reasoner/
    /// realizer/unified), so "how much history was sent" is computed
    /// ONE way, not three independently-maintained copies that could
    /// silently drift from what `truncated(_:to:)`/`maxRecentTurns`
    /// actually enforce in the real request. Pure/read-only — never
    /// consulted by request-building itself, diagnostics only.
    static func historyStats(for recentTurns: [ConversationTurn]) -> (turnCount: Int, bytes: Int) {
        let sent = recentTurns.suffix(maxRecentTurns)
        let bytes = sent.reduce(0) { total, turn in
            total + truncated(turn.responseText, to: maxCharactersPerHistoricalTurn).utf8.count
                + (turn.transcript.map { truncated($0, to: maxCharactersPerHistoricalTurn).utf8.count } ?? 0)
        }
        return (sent.count, bytes)
    }
}
