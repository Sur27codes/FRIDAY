import Foundation

/// P2-M5V8.1 §3 — the result of one readiness probe. Never carries the
/// API key or anything credential-shaped — `endpointHost` is the HOST
/// only (e.g. `"api.example.com"`), never the full URL (which could
/// carry a query-string token for some providers) and never a header.
public struct ProviderReadinessReport: Sendable, Equatable {
    public let providerConfigured: Bool
    public let endpointHost: String?
    public let modelName: String
    public let requestLatencyMs: Double?
    public let schemaCompatible: Bool
    public let failureReason: String?
}

/// P2-M5V8.1 §3 — a bounded, real probe that exercises the ACTUAL
/// transport/schema path (`ConversationModelRequestExecutor` +
/// `ConversationModelRequestBuilder`, the same machinery the real
/// reasoner/realizer use) with a MINIMAL SYNTHETIC request — never real
/// conversation history, transcript, or memory content (§3: "do NOT send
/// personal conversation history in readiness probe. Use a minimal
/// synthetic request").
public enum ProviderReadinessChecker {
    /// A fixed, content-free synthetic prompt — the same every time,
    /// carrying no user data at all.
    private static let syntheticSystemPolicy = "Respond ONLY with a single JSON object: {\"ok\": true}. No other keys, no prose."
    private static let syntheticUserPayload = "{}"

    private struct ReadinessWire: Decodable { let ok: Bool }

    public static func check(config: ConversationModelConfig, client: ConversationModelRequesting) -> ProviderReadinessReport {
        guard config.mode != .deterministicOnly else {
            return ProviderReadinessReport(providerConfigured: false, endpointHost: config.endpoint?.host, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "mode is deterministic-only")
        }
        guard let endpoint = config.endpoint else {
            return ProviderReadinessReport(providerConfigured: false, endpointHost: nil, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "no endpoint configured")
        }
        guard ConversationModelConfig.isEndpointAllowed(endpoint) else {
            return ProviderReadinessReport(providerConfigured: false, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "endpoint rejected — HTTPS required except explicit localhost")
        }
        guard !(config.apiKey ?? "").isEmpty else {
            return ProviderReadinessReport(providerConfigured: false, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "no API key configured")
        }
        guard !config.modelName.isEmpty, config.modelName != "unspecified" else {
            return ProviderReadinessReport(providerConfigured: false, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "no model name configured")
        }
        // P2-M5V8.1-HW §6/§10 (token-limit fix) + sampling-capability fix
        // §6: the synthetic probe uses the SAME `tokenLimitEncoding` AND
        // `temperatureEncoding` the real reasoner will send — never an
        // independent, probe-specific request shape (previously a
        // hardcoded `temperature: 0.0`, which is exactly the kind of
        // explicit-non-default value a provider can reject even though
        // production's own `.omit` configuration would never send it) —
        // so a transport incompatibility is caught HERE, before either
        // real stage ever wastes a call on it.
        //
        // P2-PROD-BOOTSTRAP-R2.2 §1/§3/§9 — ARCHITECTURE-AWARE parity fix:
        // since P2-PROD-BOOTSTRAP-R2 made `.unifiedOneCall` the production
        // native default, `reasoningTemperature`/`maxCompletionTokens`
        // (the TWO-STAGE reasoner's own values) were no longer what the
        // REAL production call (`ModelUnifiedConversationProvider`, which
        // sends `config.unifiedTemperature` + the larger unified token/byte
        // budgets) actually sends — a probe/production drift identical in
        // kind to the exact bug this type's own doc comment above already
        // records fixing once. Every `.twoStage` config (the default, and
        // every existing test's config) is completely unaffected — only a
        // `.unifiedOneCall` config now picks the matching representative
        // values.
        let temperature = config.architecture == .unifiedOneCall ? config.unifiedTemperature : config.reasoningTemperature
        let completionTokenBudget = config.architecture == .unifiedOneCall ? ConversationModelLimits.maxUnifiedCompletionTokens : ConversationModelLimits.maxCompletionTokens
        let maxSerializedContextBytes = config.architecture == .unifiedOneCall ? ConversationModelLimits.maxUnifiedSerializedContextBytes : ConversationModelLimits.maxSerializedContextBytes
        guard let requestBody = ConversationModelRequestBuilder.encode(
            systemPolicy: syntheticSystemPolicy, userPayloadJSON: syntheticUserPayload, modelName: config.modelName, temperature: temperature,
            tokenLimitEncoding: config.tokenLimitEncoding, temperatureEncoding: config.temperatureEncoding,
            completionTokenBudget: completionTokenBudget, maxSerializedContextBytes: maxSerializedContextBytes
        ) else {
            return ProviderReadinessReport(providerConfigured: true, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: nil, schemaCompatible: false, failureReason: "failed to build synthetic request")
        }

        let executor = ConversationModelRequestExecutor(client: client, config: config)
        let start = Date()
        let outcome = executor.executeDetailed(requestBody: requestBody)
        let latencyMs = Date().timeIntervalSince(start) * 1000

        guard let responseData = outcome.data else {
            // §6/§10/§13: report the ACTUAL sanitized provider error when
            // one is available (e.g. "HTTP 400: {"error":{"code":"unsupported_parameter",...}}")
            // instead of the previous, always-vague "no response" bucket.
            return ProviderReadinessReport(providerConfigured: true, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: latencyMs, schemaCompatible: false, failureReason: outcome.failureDetail ?? "no response (timeout, network error, or non-2xx)")
        }
        let compatible = ConversationModelRequestBuilder.decodeChatCompletion(responseData, as: ReadinessWire.self) != nil
        return ProviderReadinessReport(
            providerConfigured: true, endpointHost: endpoint.host, modelName: config.modelName, requestLatencyMs: latencyMs,
            schemaCompatible: compatible, failureReason: compatible ? nil : "response did not match the expected chat-completions JSON shape"
        )
    }
}

/// P2-M5V8.1 §16 — real, computed latency statistics; never fabricated.
/// `compute` returns `nil` for an empty sample set rather than a
/// misleading zero.
public struct LatencyStatistics: Sendable, Equatable {
    public let median: Double
    public let p95: Double
    public let max: Double
    public let sampleCount: Int
    /// P2-M5V8.1-O.6 §8 — additive: `min`/`p25`/`p75` give a fuller spread
    /// picture than median/p95/max alone, needed to distinguish ordinary
    /// architecture overhead (a tight, low-variance band) from genuine
    /// provider-side stochastic variance (a wide p25-p75 spread even
    /// among structurally identical repeated requests).
    public let min: Double
    public let p25: Double
    public let p75: Double

    public static func compute(from samples: [Double]) -> LatencyStatistics? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = Swift.min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        let p25Index = Swift.min(sorted.count - 1, Int((Double(sorted.count) * 0.25).rounded(.down)))
        let p75Index = Swift.min(sorted.count - 1, Int((Double(sorted.count) * 0.75).rounded(.down)))
        return LatencyStatistics(
            median: median, p95: sorted[p95Index], max: sorted[sorted.count - 1], sampleCount: sorted.count,
            min: sorted[0], p25: sorted[p25Index], p75: sorted[p75Index]
        )
    }
}
