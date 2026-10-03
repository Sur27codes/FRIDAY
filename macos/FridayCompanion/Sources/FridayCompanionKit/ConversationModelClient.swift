import Foundation

public enum ConversationModelError: Error, Equatable, Sendable {
    case notConfigured
    case emptyResponse
    /// P2-M5V8.1-HW §6/§10/§13 — `body` is a BOUNDED (see
    /// `URLSessionConversationModelClient`'s own capture site) slice of the
    /// provider's own error response, so a genuine incompatibility (e.g.
    /// OpenAI's `{"error":{"code":"unsupported_parameter","param":"max_tokens"}}`)
    /// can be classified precisely instead of collapsing every non-2xx
    /// into one opaque bucket. This is the PROVIDER'S response body, which
    /// by construction never echoes back a credential FRIDAY sent it (the
    /// API key travels only in the outgoing `Authorization` header) — safe
    /// to surface in diagnostics/readiness reports.
    case httpStatus(Int, body: String?)
    case schemaViolation
    case timeout
    case cancelled
}

/// P2-M5V8.1-S2 §2/§3/§9 — a developer-only, precise classification of
/// WHERE in the reasoner/realizer lifecycle a provider attempt stopped
/// short of producing a usable result. `ConversationModelError` (above)
/// only covers TRANSPORT-layer failures; this spans the FULL lifecycle,
/// including stages that type has no concept of at all (structured-JSON
/// extraction, message-content presence, schema/enum validation). Exists
/// so a live diagnostic can say exactly which stage rejected a request
/// ("schemaValidationFailure" vs. a vague "provider rejected"), per §9's
/// explicit requirement. Never carries a credential, header, full prompt,
/// or raw transcript — only a stage label and, where present, an
/// ALREADY-bounded/sanitized string (reusing the same bounded provider-
/// error-body capture `ConversationModelError.httpStatus` already
/// established as safe — the provider's own response body never echoes
/// back a credential FRIDAY sent it).
public enum ProviderStageOutcome: Equatable, Sendable {
    case success
    case notConfigured
    case transportFailure(String)
    case httpFailure(Int, String?)
    /// P2-M5V8.1-O.1 §3/§25 — a RICHER sibling of `httpFailure`, used
    /// whenever the HTTP error body successfully parses as the STANDARD
    /// OpenAI-compatible error envelope (`{"error": {"message", "type",
    /// "param", "code"}}`) — the exact same already-bounded (≤300 char)
    /// body string `httpFailure` already carries, just structured instead
    /// of opaque, so a genuine provider/schema/parameter incompatibility
    /// (exactly like the earlier, real, live `max_tokens`/`temperature`
    /// incompatibilities this codebase already root-caused) is visible
    /// precisely instead of requiring a human to re-read a raw string.
    /// Never a new capture point — see `ProviderStageOutcome.parseOpenAIErrorBody(_:)`,
    /// which only re-parses data `URLSessionConversationModelClient` was
    /// already capturing and already proven safe (never echoes a
    /// credential FRIDAY sent it).
    case providerRejected(statusCode: Int, errorType: String?, errorCode: String?, errorParam: String?, sanitizedMessage: String?)
    case timeout
    case cancelled
    case stale
    case envelopeDecodeFailure
    case missingContent
    /// P2-M5V8.1-O.1 §2/§25 — distinct from `missingContent`: the
    /// envelope decoded and a `choices[0]` entry exists, but
    /// `finish_reason == "length"` — the STANDARD, documented OpenAI-
    /// compatible signal that the model was cut off by the completion-
    /// token budget before finishing (a reasoning-capable model may
    /// spend some/all of that budget on invisible reasoning tokens before
    /// any visible content, per OpenAI's own documented behavior for
    /// `response_format: json_object` with a bounded token budget) —
    /// never conflated with a genuinely malformed/absent envelope.
    case responseTruncatedByLength
    /// P2-M5V8.1-O.2 §2 — now carries a BOUNDED, precise description of
    /// the ACTUAL `DecodingError` that occurred (`kind`/`codingPath`/
    /// `debugDescription` — see `ConversationModelRequestBuilder.classifyDecodeFailure`'s
    /// own doc comment) instead of being a bare, contentless case. Root
    /// cause of a real live 21/21 unified failure: this used to discard
    /// the actual `DecodingError` via `try?`, so a live "structuredDecodeFailure"
    /// gave no way to tell "missing key" from "wrong type" from "illegal
    /// enum" apart.
    case structuredDecodeFailure(String)
    case schemaValidationFailure(String)
    case semanticValidationFailure
    case responseRejected
    case unknownFailure(String)

    public var isSuccess: Bool { self == .success }

    /// Classifies the SAME bounded failure-detail string
    /// `ConversationModelRequestExecutor.executeDetailed`'s `describe(_:)`
    /// already produces — never re-derives or re-formats a credential,
    /// only recognizes the fixed set of prefixes that function itself emits.
    public static func classifyTransportFailure(_ detail: String?) -> ProviderStageOutcome {
        guard let detail else { return .unknownFailure("no failure detail available") }
        if detail.hasPrefix("HTTP ") {
            let afterPrefix = detail.dropFirst(5)
            let codeDigits = afterPrefix.prefix(while: { $0.isNumber })
            if let code = Int(codeDigits) {
                if let colonRange = detail.range(of: ": ") {
                    let body = String(detail[colonRange.upperBound...])
                    if let parsed = Self.parseOpenAIErrorBody(body) {
                        return .providerRejected(statusCode: code, errorType: parsed.type, errorCode: parsed.code, errorParam: parsed.param, sanitizedMessage: parsed.message)
                    }
                    return .httpFailure(code, body)
                }
                return .httpFailure(code, nil)
            }
        }
        if detail.contains("timed out") { return .timeout }
        if detail == "cancelled" { return .cancelled }
        if detail == "not configured" { return .notConfigured }
        return .transportFailure(detail)
    }

    /// P2-M5V8.1-O.1 §3 — bounded, sanitized parse of the STANDARD
    /// OpenAI-compatible error envelope. Returns `nil` (falls back to the
    /// plain `httpFailure(_:body:)` case) for any body that isn't valid
    /// JSON in this exact shape — never guesses, never partially applies.
    /// `sanitizedMessage` is length-capped independently of the caller's
    /// own 300-char body bound, since a provider's `message` field can
    /// itself be verbose.
    private static func parseOpenAIErrorBody(_ body: String) -> (type: String?, code: String?, param: String?, message: String?)? {
        struct ErrorEnvelope: Decodable {
            struct Detail: Decodable { let message: String?; let type: String?; let param: String?; let code: String? }
            let error: Detail
        }
        guard let data = body.data(using: .utf8), let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { return nil }
        return (envelope.error.type, envelope.error.code, envelope.error.param, envelope.error.message.map { String($0.prefix(200)) })
    }
}

/// P2-M5V8.1-S2.1 §2/§3 — the ONE new concept this pass adds: WHICH
/// SOURCE actually produced the text spoken to the user, as distinct
/// from whether the model's own network inference succeeded.
/// `ProviderStageOutcome`/`realizerProviderSucceeded` (via
/// `WakeDiagnosticsRecorder.recordModelProviderRequest`) answer "did the
/// provider produce a genuinely usable structured result" — a model can
/// answer that with `.success` and STILL have its candidate rejected one
/// layer up, by `ResponseValidation.passesSemanticGuards` inside
/// `ConversationalResponsePresenter.realize`, because inference success
/// and semantic-grounding acceptance are different questions. This type
/// answers the THIRD, previously-unrepresented question: what the user
/// actually heard.
public enum FinalResponseSource: Equatable, Sendable {
    case model
    case deterministicFallback
}

/// A cancellable handle to one in-flight provider request. Calling
/// `cancel()` after the request already completed (or was already
/// cancelled) is a harmless no-op — P2-M5V8 §20/§21's own "a stale
/// provider result must never speak after interaction cancellation"
/// requirement is enforced by the CALLER checking a cancellation flag
/// before using any result, not by this token alone.
public final class ConversationModelCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?

    public init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        lock.lock()
        let action = cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
    }
}

/// P2-M5V8 §2/§3 — the provider-neutral transport abstraction
/// `ModelConversationReasoner`/`ModelNaturalResponseRealizer` are built
/// on. Real implementations (`URLSessionConversationModelClient`) and
/// fakes (for deterministic, network-free tests) both conform to this
/// one, small surface.
public protocol ConversationModelRequesting: Sendable {
    /// Sends `requestBody` (an already-encoded JSON chat-completion-shaped
    /// request) and calls `completion` from an arbitrary thread/queue —
    /// exactly once if the request completes, possibly never if
    /// cancelled first. Returns a token whose `cancel()` aborts it.
    func send(requestBody: Data, config: ConversationModelConfig, completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> ConversationModelCancelToken
}

/// The real, working implementation — `URLSession`-based, no third-party
/// SDK dependency. Targets the widely-supported OpenAI-compatible chat-
/// completions shape (see `ConversationModelConfig`'s own doc comment for
/// why this counts as "provider-neutral" rather than one vendor's
/// proprietary format).
public final class URLSessionConversationModelClient: ConversationModelRequesting, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(requestBody: Data, config: ConversationModelConfig, completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> ConversationModelCancelToken {
        guard let endpoint = config.endpoint, let apiKey = config.apiKey, !apiKey.isEmpty else {
            completion(.failure(ConversationModelError.notConfigured))
            return ConversationModelCancelToken(cancelAction: {})
        }
        var request = URLRequest(url: endpoint, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        // P2-M5V8 §22: no secret is ever logged — this header is
        // constructed and handed directly to URLSession, never passed
        // through any diagnostics/print path in this codebase.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = requestBody

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // §6/§10/§13: capture a bounded slice of the response body
                // (never the request's own header) so the caller can
                // classify the exact incompatibility instead of guessing.
                let bodyText = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) }
                completion(.failure(ConversationModelError.httpStatus(http.statusCode, body: bodyText)))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(ConversationModelError.emptyResponse))
                return
            }
            completion(.success(data))
        }
        task.resume()
        return ConversationModelCancelToken(cancelAction: { task.cancel() })
    }
}

/// P2-M5V8 §6/§17 — builds the actual chat-completion wire request,
/// structurally separating SYSTEM POLICY (fixed, never contains user
/// text) from CONVERSATION CONTEXT + the USER UTTERANCE (both carried
/// only inside the `user` message's own JSON payload, clearly delimited
/// — never concatenated into the system instructions where they could
/// redefine authority rules). `responseFormat` requests strict JSON-object
/// output from providers that support it (widely supported on
/// OpenAI-compatible endpoints); `ConversationModelSchema` still fully
/// re-validates the result regardless (§7: never trust wire shape alone).
enum ConversationModelRequestBuilder {
    struct ChatMessage: Encodable { let role: String; let content: String }
    /// P2-M5V8.1-HW — `max_tokens`/`max_completion_tokens` are BOTH
    /// optional and, being `Encodable` Optionals, are omitted from the
    /// encoded JSON entirely when `nil` (Swift's synthesized `Encodable`
    /// conformance uses `encodeIfPresent` for Optional stored properties).
    /// `encode(...)` below sets AT MOST ONE of the two, never both, based
    /// on `tokenLimitEncoding` — see `CompletionTokenLimitEncoding`.
    /// P2-M5V8.1-HW (sampling-capability fix) — `temperature` is now
    /// OPTIONAL for the identical reason `max_tokens`/`max_completion_tokens`
    /// are: a live provider (`gpt-5.6-sol`) rejects ANY explicit, non-default
    /// temperature outright, so `encode(...)` must be able to omit the
    /// field entirely, never encode `null`. Omitted (not just `nil`-valued)
    /// via the same synthesized-`Encodable`-`encodeIfPresent` mechanism.
    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let response_format: ResponseFormat
        let max_tokens: Int?
        let max_completion_tokens: Int?
        struct ResponseFormat: Encodable { let type: String }
    }

    /// P2-M5V8.1 §19 — `temperature` is ALWAYS passed explicitly by the
    /// caller (`ModelConversationReasoner`/`ModelNaturalResponseRealizer`,
    /// each using `config.reasoningTemperature`/`config.realizationTemperature`
    /// respectively) — never a value hidden inside this shared builder,
    /// so the two stages' deliberately different variability settings
    /// stay visible and documented at their own call sites.
    ///
    /// P2-M5V8.1 §20 — enforces `ConversationModelLimits.maxSerializedContextBytes`
    /// as a hard final check: if the fully-encoded request would still
    /// exceed the bound after the caller's own per-field truncation,
    /// this returns `nil` rather than sending an oversized payload — the
    /// request is never sent, safely degrading to the deterministic
    /// fallback via the same `nil`-return contract every other
    /// request-building failure already uses.
    /// - Parameter tokenLimitEncoding: P2-M5V8.1-HW. Defaults to `.none`
    ///   (today's pre-existing behavior — sends neither field) so every
    ///   caller that hasn't been updated to pass `config.tokenLimitEncoding`
    ///   explicitly keeps its exact prior request shape.
    /// - Parameter temperatureEncoding: P2-M5V8.1-HW (sampling-capability
    ///   fix). Defaults to `.explicit` (today's pre-existing behavior —
    ///   always sends `temperature`) for the identical reason. `temperature`
    ///   is still the caller's real, logical, documented setting either
    ///   way (§5: "preserve logical temperature settings") — this parameter
    ///   only decides whether the WIRE carries it.
    /// - Parameter completionTokenBudget: P2-M5V8.1-O.1 §7 — the ACTUAL
    ///   numeric value sent when `tokenLimitEncoding` isn't `.none`.
    ///   Defaults to `ConversationModelLimits.maxCompletionTokens` (400 —
    ///   today's exact pre-existing behavior), so `ModelConversationReasoner`/
    ///   `ModelNaturalResponseRealizer` (neither of which passes this
    ///   parameter) are BYTE-IDENTICAL to before. Only `ModelUnifiedConversationProvider`
    ///   passes a larger, explicit value — see `ConversationModelLimits.maxUnifiedCompletionTokens`'s
    ///   own doc comment for why a combined reasoning+response payload
    ///   needs materially more headroom than either single-stage payload.
    /// - Parameter maxSerializedContextBytes: P2-M5V8.1-O.3 §6/§7 — the
    ///   ACTUAL request-size ceiling enforced below. Defaults to
    ///   `ConversationModelLimits.maxSerializedContextBytes` (today's
    ///   exact pre-existing behavior), so `ModelConversationReasoner`/
    ///   `ModelNaturalResponseRealizer` (neither of which passes this
    ///   parameter) are BYTE-IDENTICAL to before. Only `ModelUnifiedConversationProvider`
    ///   passes the larger `maxUnifiedSerializedContextBytes` — see that
    ///   constant's own doc comment for why the combined system prompt
    ///   needs materially more headroom.
    static func encode(
        systemPolicy: String, userPayloadJSON: String, modelName: String, temperature: Double,
        tokenLimitEncoding: CompletionTokenLimitEncoding = .none, temperatureEncoding: TemperatureEncoding = .explicit,
        completionTokenBudget: Int = ConversationModelLimits.maxCompletionTokens,
        maxSerializedContextBytes: Int = ConversationModelLimits.maxSerializedContextBytes
    ) -> Data? {
        var maxTokens: Int?
        var maxCompletionTokens: Int?
        switch tokenLimitEncoding {
        case .none: break
        case .maxTokens: maxTokens = completionTokenBudget
        case .maxCompletionTokens: maxCompletionTokens = completionTokenBudget
        }
        let request = ChatRequest(
            model: modelName,
            messages: [
                ChatMessage(role: "system", content: systemPolicy),
                ChatMessage(role: "user", content: userPayloadJSON),
            ],
            temperature: temperatureEncoding == .explicit ? temperature : nil,
            response_format: .init(type: "json_object"),
            max_tokens: maxTokens,
            max_completion_tokens: maxCompletionTokens
        )
        guard let encoded = try? JSONEncoder().encode(request), encoded.count <= maxSerializedContextBytes else { return nil }
        return encoded
    }

    /// Extracts the nested JSON-string `choices[0].message.content` a
    /// chat-completions response carries, then decodes IT (a second,
    /// inner JSON document) as `T`. Returns `nil` on any structural
    /// mismatch — the caller treats this identically to any other
    /// schema violation.
    /// P2-M5V8.1-O.1 §2/§6/§25 — `content` is `String?`, not `String`:
    /// the STANDARD OpenAI-compatible chat-completions response can
    /// legitimately return `"content": null` (documented behavior when
    /// `finish_reason == "length"` cuts a response off before any
    /// visible content is produced — a real risk for a reasoning-capable
    /// model spending its completion-token budget on invisible reasoning
    /// tokens first). Before this fix, a `null` content made the WHOLE
    /// envelope fail to decode (Swift's `Decodable` throws for a
    /// non-optional field given `null`), which surfaced as the same
    /// opaque `envelopeDecodeFailure` as a genuinely malformed response —
    /// `finishReason` is decoded alongside it so `classifyDecodeFailure`
    /// can tell the two apart precisely (see `responseTruncatedByLength`).
    private struct ChatCompletionEnvelope: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }
        /// P2-M5V8.1-O.2 §13 — the STANDARD OpenAI-compatible token-usage
        /// object, decoded for DIAGNOSTICS ONLY (never used to decide
        /// success/failure, never required — `usage` is `nil` on any
        /// provider that omits it). `reasoningTokens` specifically lets a
        /// live run confirm or disprove the O.1 hypothesis ("a reasoning-
        /// capable model can spend part of the completion-token budget on
        /// invisible reasoning tokens") with real numbers instead of guessing.
        struct Usage: Decodable {
            struct CompletionTokensDetails: Decodable { let reasoning_tokens: Int? }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
            let completion_tokens_details: CompletionTokensDetails?
        }
        let choices: [Choice]
        let usage: Usage?
    }

    static func decodeChatCompletion<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        guard let envelope = try? JSONDecoder().decode(ChatCompletionEnvelope.self, from: data),
              let content = envelope.choices.first?.message.content, !content.isEmpty,
              let innerData = content.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: innerData)
    }

    /// P2-M5V8.1-S2 §2/§9 — DIAGNOSTIC ONLY: re-examines the same bytes
    /// `decodeChatCompletion` already returned `nil` for, to report WHICH
    /// of its three collapsed failure modes actually occurred (envelope
    /// shape, missing/empty message content, or the inner structured
    /// JSON itself). Never called on the success path, never changes
    /// what `decodeChatCompletion` itself accepts or rejects — a caller
    /// that doesn't need this distinction can keep using `decodeChatCompletion`
    /// exactly as before.
    ///
    /// P2-M5V8.1-O.2 §2/§4 — root-cause fix for a real live gap: the
    /// inner-JSON decode attempt used to be `try?`, silently discarding
    /// the ACTUAL `DecodingError` — a live "structuredDecodeFailure" gave
    /// no way to tell "missing key" from "wrong type" from "illegal
    /// value" apart. Now captured via `do`/`catch` and formatted into the
    /// case's own associated string. §4: `finish_reason == "length"` is
    /// checked in BOTH the empty-content branch (O.1) AND this
    /// structured-decode branch (new) — a provider can return NONEMPTY
    /// but truncated/partial JSON before being cut off, which is still
    /// token-budget exhaustion, not a schema/contract mismatch.
    static func classifyDecodeFailure<T: Decodable>(_ data: Data, as type: T.Type) -> ProviderStageOutcome {
        guard let envelope = try? JSONDecoder().decode(ChatCompletionEnvelope.self, from: data) else {
            return .envelopeDecodeFailure
        }
        let finishReason = envelope.choices.first?.finishReason
        guard let content = envelope.choices.first?.message.content, !content.isEmpty else {
            // P2-M5V8.1-O.1 §2/§25 — `finish_reason == "length"` is the
            // STANDARD, documented signal that the completion-token
            // budget was exhausted before any visible content was
            // produced — a materially different, more actionable
            // diagnosis than a generic "missing content" (which could
            // otherwise also mean a genuinely empty/malformed response).
            if finishReason == "length" { return .responseTruncatedByLength }
            return .missingContent
        }
        guard let innerData = content.data(using: .utf8) else {
            return .structuredDecodeFailure("content was not valid UTF-8")
        }
        do {
            _ = try JSONDecoder().decode(T.self, from: innerData)
            return .success // unreachable when called only after decodeChatCompletion returned nil
        } catch {
            if finishReason == "length" { return .responseTruncatedByLength }
            if let decodingError = error as? DecodingError {
                let described = Self.describeDecodingError(decodingError)
                return .structuredDecodeFailure("kind=\(described.kind) path=\(described.codingPath) description=\(described.debugDescription)")
            }
            return .structuredDecodeFailure("non-DecodingError thrown: \(String(describing: error).prefix(200))")
        }
    }

    /// P2-M5V8.1-O.2 §2 — maps every `DecodingError` case (§2's explicit
    /// list) to a bounded `(kind, codingPath, debugDescription)` triple.
    /// `codingPath` is dot-joined, e.g. `"reasoning.dialogueAct"` — for
    /// `.keyNotFound`, the missing key itself is APPENDED to the
    /// container's own `codingPath` (the key is a separate associated
    /// value, not already part of `context.codingPath`), matching what a
    /// developer actually wants to see ("which field was missing," not
    /// just "which object it should have been in"). `debugDescription`
    /// is length-capped independently of any other bound in this file.
    static func describeDecodingError(_ error: DecodingError) -> (kind: String, codingPath: String, debugDescription: String) {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map(\.stringValue).joined(separator: ".")
        }
        func bounded(_ text: String) -> String { String(text.prefix(300)) }
        switch error {
        case .typeMismatch(_, let context):
            return ("typeMismatch", path(context.codingPath), bounded(context.debugDescription))
        case .valueNotFound(_, let context):
            return ("valueNotFound", path(context.codingPath), bounded(context.debugDescription))
        case .keyNotFound(let key, let context):
            return ("keyNotFound", path(context.codingPath + [key]), bounded(context.debugDescription))
        case .dataCorrupted(let context):
            return ("dataCorrupted", path(context.codingPath), bounded(context.debugDescription))
        @unknown default:
            return ("unknown", "", "")
        }
    }

    /// P2-M5V8.1-O.2 §2/§3/§6 — the FULL, precise, structural-first decode
    /// diagnostic. Generic over any `Decodable` target (mirrors
    /// `classifyDecodeFailure`'s own genericity) but, per this milestone's
    /// own minimal-fix scope, wired ONLY into `ModelUnifiedConversationProvider` —
    /// `ModelConversationReasoner`/`ModelNaturalResponseRealizer` are
    /// untouched. Every field is either a boolean, a count, a SORTED list
    /// of top-level JSON KEY NAMES (never values), or a bounded
    /// description string; `sanitizedContentPreview` is populated only
    /// when the caller explicitly opts in (§5: only `provider-unified-smoke`
    /// does, since its own prompt/scenario is hard-coded and non-sensitive —
    /// every OTHER caller gets `nil` here by simply not asking).
    static func diagnoseUnifiedDecode<T: Decodable>(_ data: Data, as type: T.Type, includeContentPreview: Bool = false) -> UnifiedDecodeDiagnostic {
        guard let envelope = try? JSONDecoder().decode(ChatCompletionEnvelope.self, from: data) else {
            return UnifiedDecodeDiagnostic(
                finishReason: nil, contentWasNull: false, contentWasEmpty: false,
                assistantContentByteCount: 0, assistantContentCharacterCount: 0,
                structuredJSONParseable: false, topLevelJSONType: "n/a", topLevelKeys: [],
                decoderFailureKind: nil, decoderCodingPath: nil,
                decoderDebugDescription: "the outer chat-completion envelope itself did not decode",
                sanitizedContentPreview: nil, promptTokens: nil, completionTokens: nil, totalTokens: nil, reasoningTokens: nil
            )
        }
        let choice = envelope.choices.first
        let content = choice?.message.content
        let contentData = content.flatMap { $0.data(using: .utf8) } ?? Data()

        var structuredJSONParseable = false
        var topLevelJSONType = "n/a"
        var topLevelKeys: [String] = []
        if !contentData.isEmpty, let jsonObject = try? JSONSerialization.jsonObject(with: contentData, options: [.fragmentsAllowed]) {
            structuredJSONParseable = true
            if let object = jsonObject as? [String: Any] {
                topLevelJSONType = "object"
                topLevelKeys = object.keys.sorted()
            } else if jsonObject is [Any] {
                topLevelJSONType = "array"
            } else if jsonObject is String {
                topLevelJSONType = "string"
            } else {
                topLevelJSONType = "other"
            }
        }

        var decoderFailureKind: String?
        var decoderCodingPath: String?
        var decoderDebugDescription: String?
        if !contentData.isEmpty {
            do {
                _ = try JSONDecoder().decode(T.self, from: contentData)
            } catch let decodingError as DecodingError {
                let described = Self.describeDecodingError(decodingError)
                decoderFailureKind = described.kind
                decoderCodingPath = described.codingPath
                decoderDebugDescription = described.debugDescription
            } catch {
                decoderFailureKind = "unknown"
                decoderDebugDescription = String(describing: error).prefix(300).description
            }
        }

        return UnifiedDecodeDiagnostic(
            finishReason: choice?.finishReason, contentWasNull: content == nil, contentWasEmpty: content?.isEmpty ?? true,
            assistantContentByteCount: contentData.count, assistantContentCharacterCount: content?.count ?? 0,
            structuredJSONParseable: structuredJSONParseable, topLevelJSONType: topLevelJSONType, topLevelKeys: topLevelKeys,
            decoderFailureKind: decoderFailureKind, decoderCodingPath: decoderCodingPath, decoderDebugDescription: decoderDebugDescription,
            sanitizedContentPreview: includeContentPreview ? content.map { String($0.prefix(800)) } : nil,
            promptTokens: envelope.usage?.prompt_tokens, completionTokens: envelope.usage?.completion_tokens,
            totalTokens: envelope.usage?.total_tokens, reasoningTokens: envelope.usage?.completion_tokens_details?.reasoning_tokens
        )
    }
}

/// P2-M5V8.1-O.2 §2/§3 — see `ConversationModelRequestBuilder.diagnoseUnifiedDecode(_:as:includeContentPreview:)`'s
/// own doc comment for the full field-by-field rationale.
public struct UnifiedDecodeDiagnostic: Sendable, Equatable {
    public let finishReason: String?
    public let contentWasNull: Bool
    public let contentWasEmpty: Bool
    public let assistantContentByteCount: Int
    public let assistantContentCharacterCount: Int
    public let structuredJSONParseable: Bool
    public let topLevelJSONType: String
    public let topLevelKeys: [String]
    public let decoderFailureKind: String?
    public let decoderCodingPath: String?
    public let decoderDebugDescription: String?
    public let sanitizedContentPreview: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let reasoningTokens: Int?
}
