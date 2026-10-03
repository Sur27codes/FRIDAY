import Foundation

/// P2-M5V9-B.2 §4 — the transport seam behind `CartesiaSpeechStreamProvider`,
/// mirroring `PremiumSpeechRequesting`'s established "protocol +
/// URLSession-backed real implementation, fakeable in tests" shape
/// exactly, adapted for a persistent WebSocket connection instead of one
/// request/response. No new networking framework is introduced —
/// `URLSessionWebSocketTask` is part of `Foundation`/`URLSession`, the
/// same stack every other provider in this codebase already uses (§1:
/// "do not introduce another speech framework unless a real integration
/// gap requires it" — none does here).
public protocol CartesiaWebSocketTransport: Sendable {
    /// Opens one socket to `url` with `headers` applied to the upgrade
    /// request (§7: auth stays inside the adapter — headers are Cartesia's
    /// own concern, never the caller's). `onMessage` fires for every text
    /// frame received, in order; `onClose` fires exactly once, with the
    /// error that ended the connection (`nil` for a clean close).
    func open(url: URL, headers: [String: String], onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) -> CartesiaWebSocketHandle
}

public protocol CartesiaWebSocketHandle: Sendable {
    func send(_ message: String)
    func close()
}

/// The real, working implementation. Kept deliberately small: connect,
/// send, receive-loop, close — every Cartesia-specific wire detail
/// (message shape, auth header names, model/voice/context fields) lives
/// in `CartesiaSpeechStreamProvider` below, never here (§7/§17: "no
/// provider-specific branching scattered through presenter code").
public final class URLSessionCartesiaWebSocketTransport: NSObject, CartesiaWebSocketTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private final class Connection: CartesiaWebSocketHandle, @unchecked Sendable {
        let task: URLSessionWebSocketTask
        init(task: URLSessionWebSocketTask) { self.task = task }
        func send(_ message: String) {
            task.send(.string(message)) { _ in } // transport-level send failures surface via the receive loop's onClose
        }
        func close() { task.cancel(with: .normalClosure, reason: nil) }
    }

    private var session: URLSession!

    public override init() {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    public func open(url: URL, headers: [String: String], onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) -> CartesiaWebSocketHandle {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.webSocketTask(with: request)
        let closedOnce = OnceFlag()
        func receiveLoop() {
            task.receive { result in
                switch result {
                case .success(let message):
                    if case .string(let text) = message { onMessage(text) }
                    receiveLoop()
                case .failure(let error):
                    if closedOnce.markIfFirst() { onClose(error) }
                }
            }
        }
        task.resume()
        receiveLoop()
        return Connection(task: task)
    }
}

/// A tiny, lock-protected "fire exactly once" gate — the receive loop's
/// terminal error and a real socket-level close can both attempt to
/// signal completion; only the first must reach `onClose`.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markIfFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// P2-M5V9-B.2 §2/§4 — the real Cartesia Sonic adapter behind the
/// EXISTING, unchanged `PremiumSpeechStreamProviding` abstraction.
///
/// **Wire-shape disclosure**: this targets Cartesia's realtime TTS
/// WebSocket contract as publicly documented up through this codebase's
/// own knowledge — `POST`-equivalent JSON control message
/// (`model_id`/`transcript`/`voice`/`output_format`/`context_id`) over
/// `wss://api.cartesia.ai/tts/websocket`, streamed `chunk`/`done`/`error`
/// response messages, and `context_id`-scoped cancellation. The mission's
/// own stated API version (`Cartesia-Version: 2026-08-14`) is NEWER than
/// this implementation's ability to independently verify against a live
/// server (no credentials exist in this environment — see this
/// milestone's own STOP report). If Cartesia's wire shape has since
/// changed, this is the ONE place to update it — never scattered
/// elsewhere (§7/§17).
///
/// Never fakes streaming (§4.8): every `.audioChunk` event corresponds to
/// one real WebSocket text frame actually received, decoded, and
/// forwarded — this type never buffers a complete response before
/// emitting anything.
public struct CartesiaSpeechStreamProvider: PremiumSpeechStreamProviding {
    private let config: PremiumVoiceProviderConfig
    private let transport: CartesiaWebSocketTransport
    private let outputFormat: AudioFormatDescriptor

    public let capabilities: PremiumSpeechCapabilities

    /// P2-M5V9-B.3C §1/§4/§6 — ROOT-CAUSE CORRECTION, measured not
    /// guessed: the owner's Cartesia REST reference (the gold-standard
    /// Skylar rendering) uses 44.1kHz PCM. This adapter previously
    /// defaulted its realtime WebSocket request to 22050Hz — a genuine,
    /// unforced audio-FIDELITY gap (less high-frequency content is
    /// physically present below the lower Nyquist limit, and the coarser
    /// 22050→device-rate resample CoreAudio then performs is a rougher
    /// conversion than 44100→device-rate) fully capable of producing an
    /// audible, honest "doesn't quite sound the same" perception without
    /// implying anything about the SPEAKER identity itself. Now defaults
    /// to 44100Hz, matching the reference exactly — `capabilities.sampleRates`
    /// already declared this as supported before this fix; only the
    /// DEFAULT actually used was wrong.
    public init(
        config: PremiumVoiceProviderConfig, transport: CartesiaWebSocketTransport = URLSessionCartesiaWebSocketTransport(),
        outputFormat: AudioFormatDescriptor = AudioFormatDescriptor(sampleRate: 44100, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true),
        capabilities: PremiumSpeechCapabilities = PremiumSpeechCapabilities(
            streaming: true, cancellation: true, nativeProsody: false, speakingStyles: false, pronunciationControl: false,
            ssml: false, wordTimestamps: true, sentenceTimestamps: false, sampleRates: [22050, 44100], audioFormats: ["pcm_s16le"],
            voiceSelection: true, customVoice: true, localeSupport: ["en-US", "hi-IN", "es-ES", "fr-FR", "de-DE", "ja-JP", "ko-KR", "pt-BR"]
        )
    ) {
        self.config = config
        self.transport = transport
        self.outputFormat = outputFormat
        self.capabilities = capabilities
    }

    private struct WireVoice: Encodable { let mode = "id"; let id: String }
    private struct WireOutputFormat: Encodable { let container = "raw"; let encoding: String; let sample_rate: Int }
    private struct WireRequest: Encodable {
        let model_id: String
        let transcript: String
        let voice: WireVoice
        let output_format: WireOutputFormat
        let language: String?
        let context_id: String
        // P2-M5V9-B.3C §3/§4 — explicit `speed`/`volume`, previously
        // OMITTED entirely (relying silently on whatever Cartesia's own
        // undocumented default happens to be, rather than the reference's
        // own explicit `speed=1, volume=1`). Fixed at the SkylarCanonicalBase
        // values (see that type's own doc comment) — never sourced from
        // `request.prosody`/`VoiceProfile.friday`/any delivery mode, so
        // this provider can never silently drift from the canonical,
        // undistorted Skylar rendering the owner accepted as correct.
        let speed: Double
        let volume: Double
    }
    private struct WireCancel: Encodable { let context_id: String; let cancel = true }
    private struct WireResponse: Decodable {
        let type: String
        let data: String?
        let context_id: String?
        let error: String?
    }

    public func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken {
        guard let endpoint = config.endpoint, let apiKey = config.apiKey, !apiKey.isEmpty else {
            onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .configuration))
            return SpeechProviderCancelToken(cancelAction: {})
        }
        // §4.9: one Cartesia `context_id` per FRIDAY utterance — this
        // reuses the SAME utteranceID `UtteranceIdentityGuard` already
        // tracks upstream, so a cancel here and a stale-chunk rejection
        // upstream are always talking about the exact same generation.
        let contextID = request.utteranceID
        let wireRequest = WireRequest(
            model_id: config.modelName, transcript: request.text, voice: WireVoice(id: config.voiceID),
            output_format: WireOutputFormat(encoding: outputFormat.sampleFormat, sample_rate: outputFormat.sampleRate),
            // §9: never send both locale and language — Cartesia's own
            // `language` field IS the locale-or-base-language slot; this
            // codebase's `PremiumVoiceProviderConfig.locale` is the one
            // value sent, `request.language` is ignored for the wire
            // payload precisely to avoid sending two conflicting hints.
            language: config.locale, context_id: contextID,
            // P2-M5V9-B.3C §4: SkylarCanonicalBase — fixed, never
            // configurable per-call, never influenced by delivery mode.
            speed: SkylarCanonicalBase.speed, volume: SkylarCanonicalBase.volume
        )
        guard let bodyData = try? JSONEncoder().encode(wireRequest), let bodyString = String(data: bodyData, encoding: .utf8) else {
            onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .invalidResponse))
            return SpeechProviderCancelToken(cancelAction: {})
        }
        var headers = ["X-API-Key": apiKey]
        if let apiVersion = config.apiVersion { headers["Cartesia-Version"] = apiVersion }
        let sequenceCounter = ChunkSequenceCounter()
        let finished = OnceFlag()

        onEvent(.started(interactionID: request.interactionID, utteranceID: request.utteranceID))
        // P2-M5V9-B.3C — the ACTUAL sample rate this request asked for,
        // surfaced so a real downstream player (`PremiumNeuralSpeechSynthesizer`)
        // can build the correct `AVAudioFormat` instead of guessing —
        // exactly the kind of accidental-misinterpretation bug §7 of this
        // milestone warns about ("24k interpreted as 44.1k" etc.). Encoded
        // as a small, parseable, non-content string via the EXISTING
        // `.metadata` event — no new event type, no wire-shape change.
        onEvent(.metadata(interactionID: request.interactionID, utteranceID: request.utteranceID, description: "sampleRate:\(outputFormat.sampleRate)"))
        let handle = transport.open(
            url: endpoint, headers: headers,
            onMessage: { text in
                guard let data = text.data(using: .utf8), let response = try? JSONDecoder().decode(WireResponse.self, from: data) else { return }
                switch response.type {
                case "chunk":
                    guard let base64 = response.data, let decoded = Data(base64Encoded: base64) else { return }
                    onEvent(.audioChunk(interactionID: request.interactionID, utteranceID: request.utteranceID, samples: decoded, sequence: sequenceCounter.next()))
                case "done":
                    if finished.markIfFirst() { onEvent(.completed(interactionID: request.interactionID, utteranceID: request.utteranceID)) }
                case "error":
                    if finished.markIfFirst() {
                        let category: SpeechProviderFailureCategory = (response.error ?? "").lowercased().contains("auth") ? .authentication : .server
                        onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: category))
                    }
                default:
                    onEvent(.metadata(interactionID: request.interactionID, utteranceID: request.utteranceID, description: response.type))
                }
            },
            onClose: { error in
                guard finished.markIfFirst() else { return }
                if let error {
                    let nsError = error as NSError
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: nsError.code == NSURLErrorCancelled ? .cancelled : .network))
                }
                // A clean close with no prior `done`/`error` message is
                // treated as already handled by whichever `finished`
                // winner fired first — never a SECOND terminal event.
            }
        )
        handle.send(bodyString)
        return SpeechProviderCancelToken(cancelAction: {
            guard let cancelData = try? JSONEncoder().encode(WireCancel(context_id: contextID)), let cancelString = String(data: cancelData, encoding: .utf8) else {
                handle.close()
                return
            }
            handle.send(cancelString)
            handle.close()
            if finished.markIfFirst() {
                onEvent(.cancelled(interactionID: request.interactionID, utteranceID: request.utteranceID))
            }
        })
    }
}

/// P2-M5V9-B.3C §4 — the canonical, undistorted Skylar rendering
/// baseline: `speed`/`volume` at Cartesia's own neutral 1.0, no pitch
/// shift, no formant shift, no artificial EQ, no hidden emotion or
/// exaggeration preset, no provider-specific "cinematic" effect. FRIDAY's
/// conversational personality lives in TEXT and contextual delivery
/// decisions (word choice, register, pacing at the response-planning
/// layer) — never in distorting the SPEAKER itself. `CartesiaSpeechStreamProvider`
/// sources `speed`/`volume` from here UNCONDITIONALLY — never from
/// `request.prosody`, `VoiceProfile.friday` (Samantha's own tuned
/// values — inert for Cartesia by construction), or any `SpeechDeliveryMode`
/// — so the canonical rendering can never silently drift.
public enum SkylarCanonicalBase {
    public static let speed: Double = 1.0
    public static let volume: Double = 1.0
}
