import Foundation

/// P2-PROD-BOOTSTRAP-R2 §2.7 — a REAL, minimal, sanitized connectivity
/// check for a configured provider. Replaces the old "HEAD a marketing
/// URL and call it reachable" behavior: this actually authenticates and
/// exercises the configured model / voice, then reports a bounded,
/// secret-free result the setup UI can render as an actionable line.
///
/// Never surfaces, in the OWNER-FACING `displayLine`: the `Authorization` /
/// `X-API-Key` header, the API key, or any provider response body —
/// P2-PROD-BOOTSTRAP-R2.2 §11 hardening: the setup UI previously rendered
/// `detail` (a bounded slice of the provider's own raw error JSON, e.g.
/// `HTTP 400: {"error":{"message":"Unsupported value: 'temperature'…"}}`)
/// directly in a visible label — a real "raw provider-style JSON/error
/// block in first-run UI" the mission-required review caught. `detail` on
/// each case still carries that bounded, secret-free (the key never
/// appears in it — it travels only in the request header) information,
/// but it is now exposed ONLY via `diagnosticDetail`, for developer
/// surfaces (logs), never the visible `displayLine`.
public enum ProviderConnectivityResult: Sendable, Equatable {
    /// Authenticated and got a valid response. `detail` is a short
    /// sanitized note (e.g. "model replied (schema OK)").
    case connected(detail: String)
    /// The provider explicitly rejected the credential (HTTP 401/403).
    case authenticationFailed
    /// Reached and authenticated, but the provider rejected the request
    /// itself (bad model name, unsupported parameter, 4xx/5xx other than
    /// auth). `detail` is a bounded, secret-free slice of the reason —
    /// developer-diagnostics only, see `diagnosticDetail`.
    case providerRejectedRequest(detail: String)
    /// The request never reached the provider (offline, DNS failure,
    /// connection dropped).
    case networkUnavailable
    /// The request reached the network but no response arrived in time.
    case timedOut
    /// Not enough native configuration to even attempt a request.
    case configurationIncomplete(detail: String)

    /// A one-line, owner-facing rendering — a concise, actionable
    /// CATEGORY, never generic "Connection failed" (§5.2) and never a raw
    /// provider error body (§11).
    public var displayLine: String {
        switch self {
        case .connected(let detail): return "Connected — \(detail)"
        case .authenticationFailed: return "Authentication failed. Replace the API key and try again."
        case .providerRejectedRequest: return "Provider rejected configuration. Check the selected model/settings."
        case .networkUnavailable: return "Network unavailable — could not reach the provider."
        case .timedOut: return "Provider temporarily unavailable — request timed out."
        case .configurationIncomplete: return "Invalid provider configuration — finish setup above."
        }
    }

    /// Bounded, secret-free detail for DEVELOPER diagnostics only (e.g. a
    /// log line) — never for the visible setup UI. Still never contains a
    /// credential, header, or unbounded provider body.
    public var diagnosticDetail: String? {
        switch self {
        case .connected(let detail), .providerRejectedRequest(let detail), .configurationIncomplete(let detail):
            return detail
        case .authenticationFailed, .networkUnavailable, .timedOut:
            return nil
        }
    }

    public var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

private func classifyTransportError(_ error: Error) -> ProviderConnectivityResult? {
    if let modelError = error as? ConversationModelError {
        switch modelError {
        case .notConfigured:
            return .configurationIncomplete(detail: "endpoint or credential missing")
        case .timeout:
            return .timedOut
        case .cancelled:
            return .networkUnavailable
        case .httpStatus(let code, let body):
            if code == 401 || code == 403 { return .authenticationFailed }
            let slice = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = slice.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(String(slice.prefix(160)))"
            return .providerRejectedRequest(detail: bounded)
        case .emptyResponse:
            return .providerRejectedRequest(detail: "empty response body")
        case .schemaViolation:
            return .providerRejectedRequest(detail: "unexpected response shape")
        }
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed, NSURLErrorCannotLoadFromNetwork:
            return .networkUnavailable
        default:
            return .providerRejectedRequest(detail: "network error (URLError \(ns.code))")
        }
    }
    return nil
}

/// Conversation-model connectivity.
///
/// P2-PROD-BOOTSTRAP-R2.2 §1/§3/§8 — this used to build its OWN request
/// via `ConversationModelRequestBuilder.encode(...)` directly, picking
/// `config.reasoningTemperature` (the TWO-STAGE reasoner's field) as a
/// literal parameter. That was a real, live-reproduced bug: production's
/// actual one-call path uses `config.unifiedTemperature`, AND the native
/// config never carried the frozen `temperatureEncoding = .omit` policy
/// GPT-5.x needs — so Test Connection sent an explicit
/// `"temperature": 0.1` the provider rejected with HTTP 400, even though
/// the request "reached the provider" (not an auth failure). This is
/// EXACTLY the duplicate-serializer failure mode `ProviderReadinessChecker`
/// (P2-M5V8.1 §3, pre-existing) was built to prevent for the two-stage
/// reasoner/realizer — this probe now DELEGATES to that SAME canonical,
/// already-hardened prober instead of maintaining a second one. There is
/// exactly one place in this codebase that decides "what does a readiness
/// request for this config look like": `ProviderReadinessChecker.check`.
public struct ConversationProviderProbe: Sendable {
    private let client: ConversationModelRequesting

    public init(client: ConversationModelRequesting = URLSessionConversationModelClient()) {
        self.client = client
    }

    /// `ProviderReadinessChecker.check` blocks the calling thread (bounded
    /// by `config.overallDeadline`) — this method is safe to call from a
    /// background thread/task only. `SetupWindowController` hops off the
    /// main actor before calling it, exactly like `WakeCoordinator.beginProcessing`
    /// already does for its own blocking runtime call.
    public func probeBlocking(config: ConversationModelConfig) -> ProviderConnectivityResult {
        let report = ProviderReadinessChecker.check(config: config, client: client)
        guard report.providerConfigured else {
            return .configurationIncomplete(detail: report.failureReason ?? "conversation provider not configured")
        }
        if report.schemaCompatible {
            let latency = report.requestLatencyMs.map { String(format: ", %.0fms", $0) } ?? ""
            return .connected(detail: "model replied (schema OK\(latency))")
        }
        return Self.classify(report.failureReason ?? "provider rejected the request")
    }

    public func probe(config: ConversationModelConfig, completion: @escaping @Sendable (ProviderConnectivityResult) -> Void) {
        // Never block the caller's thread (very likely @MainActor, e.g. a
        // button handler) — `ProviderReadinessChecker.check` is
        // synchronous/blocking underneath.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.probeBlocking(config: config)
            completion(result)
        }
    }

    /// Sanitized classification of `ProviderReadinessReport.failureReason`
    /// — already a bounded, secret-free string (`ConversationModelRequestExecutor.describe`
    /// never includes a credential; the API key travels only in the
    /// request header, never in `ConversationModelError`'s associated
    /// data). This only maps that string onto one of the small set of
    /// actionable, sanitized UI categories (§11) — it never invents new
    /// detail the executor didn't already produce.
    private static func classify(_ reason: String) -> ProviderConnectivityResult {
        if reason.contains("HTTP 401") || reason.contains("HTTP 403") { return .authenticationFailed }
        if reason.hasPrefix("HTTP ") { return .providerRejectedRequest(detail: String(reason.prefix(200))) }
        if reason.contains("timed out") || reason.contains("timeout") { return .timedOut }
        if reason == "not configured" || reason == "no API key configured" || reason == "no endpoint configured" || reason == "no model name configured" {
            return .configurationIncomplete(detail: reason)
        }
        if reason == "endpoint rejected — HTTPS required except explicit localhost" { return .configurationIncomplete(detail: reason) }
        if reason.contains("response did not match the expected chat-completions JSON shape") || reason == "failed to build synthetic request" || reason == "empty response" || reason == "schema violation" {
            return .providerRejectedRequest(detail: reason)
        }
        // "transport error: ..." / "cancelled" / anything else transport-shaped.
        return .networkUnavailable
    }
}

/// Voice-provider connectivity: a minimal authenticated read against the
/// configured Cartesia voice. Retrieves voice metadata (name / language)
/// for the configured `voiceID` — this proves the credential is accepted
/// AND the configured voice exists, WITHOUT generating (and being billed
/// for) any audio.
public struct VoiceProviderProbe: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func probe(config: PremiumVoiceProviderConfig, completion: @escaping @Sendable (ProviderConnectivityResult) -> Void) {
        guard config.isConfigured, let apiKey = config.apiKey, !apiKey.isEmpty else {
            completion(.configurationIncomplete(detail: "no voice endpoint + credential configured"))
            return
        }
        guard config.isCartesia else {
            completion(.configurationIncomplete(detail: "connectivity check is implemented for Cartesia only; provider is '\(config.providerName)'"))
            return
        }
        // Cartesia's realtime endpoint is a wss:// socket; its REST API
        // shares the same host over https://. A GET of the configured
        // voice is the cheapest authenticated call that returns real
        // metadata.
        let host = config.endpoint?.host ?? "api.cartesia.ai"
        let voicePath = config.voiceID == "unspecified" ? "voices" : "voices/\(config.voiceID)"
        guard let url = URL(string: "https://\(host)/\(voicePath)") else {
            completion(.configurationIncomplete(detail: "could not derive a REST URL from the configured endpoint"))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(config.apiVersion ?? "2024-06-10", forHTTPHeaderField: "Cartesia-Version")

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(classifyTransportError(error) ?? .networkUnavailable)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.providerRejectedRequest(detail: "no HTTP response"))
                return
            }
            switch http.statusCode {
            case 200...299:
                var detail = "voice reachable (HTTP \(http.statusCode))"
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let name = obj["name"] as? String { detail = "voice \"\(name)\" reachable (HTTP \(http.statusCode))" }
                    else if obj["data"] != nil { detail = "voice list reachable (HTTP \(http.statusCode))" }
                }
                completion(.connected(detail: detail))
            case 401, 403:
                completion(.authenticationFailed)
            case 404:
                completion(.providerRejectedRequest(detail: "configured voice ID not found (HTTP 404)"))
            default:
                let slice = data.flatMap { String(data: $0.prefix(160), encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.providerRejectedRequest(detail: slice.map { "HTTP \(http.statusCode): \($0)" } ?? "HTTP \(http.statusCode)"))
            }
        }
        task.resume()
    }
}
