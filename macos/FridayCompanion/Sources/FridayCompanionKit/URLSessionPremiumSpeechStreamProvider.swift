import Foundation

/// P2-M5V9-B §2/§8/§17 — the transport-layer seam behind
/// `URLSessionPremiumSpeechStreamProvider`, mirroring `ConversationModelRequesting`'s
/// own established shape exactly (a thin `send`, real network code kept
/// out of anything a test needs to exercise). `onChunk` may be called
/// zero or more times as raw audio bytes arrive over the wire, in order,
/// BEFORE `completion` fires exactly once.
public protocol PremiumSpeechRequesting: Sendable {
    func send(requestBody: Data, config: PremiumVoiceProviderConfig, onChunk: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Result<Void, PremiumSpeechTransportError>) -> Void) -> SpeechProviderCancelToken
}

public enum PremiumSpeechTransportError: Error, Sendable, Equatable {
    case notConfigured
    case httpStatus(Int)
    case network(String)
    case cancelled
}

/// The real, working implementation — `URLSession`-based, no third-party
/// SDK dependency, and deliberately generic (§2: "do not hard-code one
/// cloud vendor into core speech architecture" / §17: "no provider-
/// specific branching scattered through presenter code"). Targets a
/// simple, common REST shape any streaming-TTS-capable endpoint can
/// implement: `POST {endpoint}` with a small JSON body
/// (`{"text","voice","locale","format"}`), `Authorization: Bearer
/// {apiKey}`, and a response body that IS the raw audio stream, delivered
/// incrementally as the real vendor's own HTTP response arrives — this
/// class is the ONE place that wire shape lives; if a chosen vendor's API
/// differs (SSE framing, base64-JSON-per-line, a different auth scheme),
/// this is the one, isolated place to adapt, never scattered elsewhere.
///
/// NEVER constructed with real credentials by any code in this
/// repository — `PremiumVoiceProviderConfig.unconfigured` (no endpoint,
/// no key) is the default everywhere, so this class exists as tested,
/// ready architecture, not a live integration (§0/§29 of this milestone's
/// own authorization: "LIVE PREMIUM VOICE: PENDING OWNER").
public final class URLSessionPremiumSpeechRequester: NSObject, PremiumSpeechRequesting, URLSessionDataDelegate, @unchecked Sendable {
    private final class RequestState: @unchecked Sendable {
        let onChunk: @Sendable (Data) -> Void
        let completion: @Sendable (Result<Void, PremiumSpeechTransportError>) -> Void
        let lock = NSLock()
        var finished = false
        var sawSuccessfulStatus = false

        init(onChunk: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Result<Void, PremiumSpeechTransportError>) -> Void) {
            self.onChunk = onChunk
            self.completion = completion
        }

        func finishOnce(_ result: Result<Void, PremiumSpeechTransportError>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            completion(result)
        }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var states: [Int: RequestState] = [:] // keyed by task identifier

    public override init() {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    public func send(requestBody: Data, config: PremiumVoiceProviderConfig, onChunk: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Result<Void, PremiumSpeechTransportError>) -> Void) -> SpeechProviderCancelToken {
        guard let endpoint = config.endpoint, let apiKey = config.apiKey, !apiKey.isEmpty else {
            completion(.failure(.notConfigured))
            return SpeechProviderCancelToken(cancelAction: {})
        }
        var request = URLRequest(url: endpoint, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.dataTask(with: request)
        let state = RequestState(onChunk: onChunk, completion: completion)
        lock.lock(); states[task.taskIdentifier] = state; lock.unlock()
        task.resume()
        return SpeechProviderCancelToken(cancelAction: { [weak self] in
            task.cancel()
            self?.lock.lock(); self?.states.removeValue(forKey: task.taskIdentifier); self?.lock.unlock()
            state.finishOnce(.failure(.cancelled))
        })
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock(); let state = states[dataTask.taskIdentifier]; lock.unlock()
        guard (200...299).contains(http.statusCode) else {
            state?.finishOnce(.failure(.httpStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        state?.lock.lock(); state?.sawSuccessfulStatus = true; state?.lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let state = states[dataTask.taskIdentifier]; lock.unlock()
        guard let state, !data.isEmpty else { return }
        state.onChunk(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = states.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let state else { return }
        if let error {
            let nsError = error as NSError
            state.finishOnce(.failure(nsError.code == NSURLErrorCancelled ? .cancelled : .network(nsError.localizedDescription)))
            return
        }
        state.finishOnce(.success(()))
    }
}

/// The real, working `PremiumSpeechStreamProviding` adapter — translates
/// `PremiumSpeechRequesting`'s raw byte stream into the typed
/// `SpeechSynthesisEvent` sequence `PremiumNeuralSpeechSynthesizer`
/// already knows how to consume (§32). All the safety machinery
/// downstream (`UtteranceIdentityGuard`, `AudioChunkValidator`,
/// `AudioChunkBuffer`, `ProviderCircuitBreaker`) is `PremiumNeuralSpeechSynthesizer`'s
/// own, unchanged responsibility — this adapter's only job is the wire
/// translation, per §17's "no provider-specific branching scattered
/// through presenter code."
public struct URLSessionPremiumSpeechStreamProvider: PremiumSpeechStreamProviding {
    private let requester: PremiumSpeechRequesting
    private let config: PremiumVoiceProviderConfig
    private let format: AudioFormatDescriptor

    public let capabilities: PremiumSpeechCapabilities

    /// - Parameters:
    ///   - format: the PCM shape this endpoint is documented to return.
    ///     Never assumed silently elsewhere — `AudioChunkValidator`
    ///     independently re-validates every chunk against it.
    public init(
        requester: PremiumSpeechRequesting = URLSessionPremiumSpeechRequester(), config: PremiumVoiceProviderConfig,
        format: AudioFormatDescriptor = AudioFormatDescriptor(sampleRate: 24000, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true),
        capabilities: PremiumSpeechCapabilities = PremiumSpeechCapabilities(
            streaming: true, cancellation: true, nativeProsody: false, speakingStyles: false, pronunciationControl: false,
            ssml: false, wordTimestamps: false, sentenceTimestamps: false, sampleRates: [24000], audioFormats: ["pcm_s16le"],
            voiceSelection: true, customVoice: false, localeSupport: ["en-US"]
        )
    ) {
        self.requester = requester
        self.config = config
        self.format = format
        self.capabilities = capabilities
    }

    public func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken {
        // §15 — SSML only ever generated from typed local structures
        // (`SSMLSafety.wrapWithPronunciationHints`), never raw string
        // concatenation of transcript-derived text into markup; only sent
        // at all when THIS provider's own negotiated capability allows it.
        let textForWire = capabilities.ssml && capabilities.pronunciationControl
            ? SSMLSafety.wrapWithPronunciationHints(request.text)
            : request.text
        let payload: [String: Any] = [
            "text": textForWire, "voice": request.voiceID, "locale": request.language,
            "format": format.sampleFormat, "sampleRate": format.sampleRate,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .invalidResponse))
            return SpeechProviderCancelToken(cancelAction: {})
        }
        onEvent(.started(interactionID: request.interactionID, utteranceID: request.utteranceID))
        let sequenceCounter = ChunkSequenceCounter()
        return requester.send(
            requestBody: body, config: config,
            onChunk: { chunk in
                onEvent(.audioChunk(interactionID: request.interactionID, utteranceID: request.utteranceID, samples: chunk, sequence: sequenceCounter.next()))
            },
            completion: { result in
                switch result {
                case .success:
                    onEvent(.completed(interactionID: request.interactionID, utteranceID: request.utteranceID))
                case .failure(.cancelled):
                    onEvent(.cancelled(interactionID: request.interactionID, utteranceID: request.utteranceID))
                case .failure(.notConfigured):
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .configuration))
                case .failure(.httpStatus(let code)):
                    let category: SpeechProviderFailureCategory
                    switch code {
                    case 401: category = .authentication
                    case 403: category = .authorization
                    case 404, 422: category = .unsupportedVoice
                    case 429: category = .rateLimit
                    case 500...599: category = .server
                    default: category = .unknown
                    }
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: category))
                case .failure(.network):
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .network))
                }
            }
        )
    }
}

/// A tiny, lock-protected monotonic counter — isolated into its own
/// `Sendable` type (matching `PlaybackProgressBox`'s established pattern
/// in `PremiumSpeechSynthesizing.swift`) so the streaming callback
/// closures above never capture a bare mutable `var` across concurrent
/// invocations. Not `private` — `CartesiaSpeechStreamProvider.swift`
/// reuses this same small utility rather than duplicating it.
final class ChunkSequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
