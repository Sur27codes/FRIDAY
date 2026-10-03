import Foundation

/// P2-M5V9-B.3B §4 — every timing checkpoint the mission asks for, for
/// exactly one local Chatterbox utterance. `generationStartMs`/
/// `generationCompleteMs`/`audioDurationSec`/`modelClass`/`checkpointRepo`
/// come straight from the paired Python service's own response (the SAME
/// instrumentation P2-M5V9-B.3A already added); everything else is a
/// real, locally-observed `Date`. `audioDecoded` and `firstPlayableAudio`
/// are the SAME timestamp — an honest disclosure, not an oversight:
/// Chatterbox returns one complete waveform per call (§4/§11 of this
/// milestone: "if Chatterbox cannot provide true incremental audio...
/// report that honestly" — it cannot), so there is no genuine
/// intermediate "decoded but not yet playable" state to distinguish.
public struct LocalSpeechTiming: Sendable, Equatable {
    public var requestStart: Date
    public var generationStartMs: Double?
    public var generationCompleteMs: Double?
    public var audioDecoded: Date?
    public var firstPlayableAudio: Date?
    public var playbackStart: Date?
    public var playbackComplete: Date?
    public var audioDurationSec: Double?
    public var modelClass: String?
    public var checkpointRepo: String?
    public var failureReason: String?

    public init(requestStart: Date) {
        self.requestStart = requestStart
    }
}

/// A tiny, lock-protected mutable box for `LocalSpeechTiming` — the same
/// "isolate the mutable state a multi-callback chain assembles" pattern
/// as `PlaybackProgressBox`/`InFlightSpeechSession` elsewhere in this
/// file's sibling sources, so no `@Sendable` closure here ever captures a
/// bare mutable `var` across threads.
private final class TimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timing: LocalSpeechTiming

    init(requestStart: Date) { timing = LocalSpeechTiming(requestStart: requestStart) }

    func update(_ mutate: (inout LocalSpeechTiming) -> Void) {
        lock.lock(); mutate(&timing); lock.unlock()
    }

    var snapshot: LocalSpeechTiming {
        lock.lock(); defer { lock.unlock() }
        return timing
    }
}

/// P2-M5V9-B.3B §1 — the real, production-shaped `SpeechSynthesizing`
/// conformer for the local Chatterbox backend, mirroring exactly how
/// `AVSpeechSynthesizerAdapter` (Samantha) and `PremiumNeuralSpeechSynthesizer`
/// (Cartesia/generic remote) are each their own conformer. Talks directly
/// to the local service over `POSIXUnixSocketIPCTransport` (reused, not
/// duplicated) — bypassing `LocalChatterboxProvider`'s `PremiumSpeechStreamProviding`
/// event abstraction, which does not carry real sample-rate/generation-timing
/// fidelity end to end; `LocalChatterboxProvider` itself is UNCHANGED by
/// this milestone. Real audio reaches the speakers via `AVAudioEnginePCMPlayer`
/// (or any `PCMAudioPlaying` — injectable for tests).
public final class LocalChatterboxSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public struct NotAvailableError: Error, CustomStringConvertible {
        public var description: String { "LocalChatterboxSpeechSynthesizer: no local Chatterbox service socket found — start services/chatterbox-speech/chatterbox_service.py first" }
    }

    private let socketPath: String
    private let variant: String
    private let transport: LocalIPCTransport
    private let player: PCMAudioPlaying
    private let identityGuard = UtteranceIdentityGuard()
    private let sessionLock = NSLock()
    private var currentSession: InFlightSpeechSession?
    private let socketExistenceCheck: (String) -> Bool
    /// P2-PROD-BOOTSTRAP-R2.5 §1 — `nil` by default (every pre-existing
    /// call site/test keeps compiling and behaving byte-identically);
    /// production `AppDelegate` supplies the SAME shared recorder every
    /// other component uses, so this tier's marks land on the same
    /// per-turn timeline `WakeCoordinator` reads. Purely additive — never
    /// replaces `onTiming` below, which keeps its own existing behavior.
    private let diagnostics: WakeDiagnosticsRecorder?

    /// Fires once per `speak(...)` call, with every checkpoint that was
    /// actually reached (§4) — `nil` fields mean genuinely unmeasured
    /// (a failure before that stage), never fabricated.
    public var onTiming: (@Sendable (LocalSpeechTiming) -> Void)?

    public let engineIdentifier: String

    public init(
        socketPath: String, variant: String, transport: LocalIPCTransport = POSIXUnixSocketIPCTransport(),
        player: PCMAudioPlaying = AVAudioEnginePCMPlayer(), socketExistenceCheck: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        diagnostics: WakeDiagnosticsRecorder? = nil
    ) {
        self.socketPath = socketPath
        self.variant = variant
        self.diagnostics = diagnostics
        self.transport = transport
        self.player = player
        self.socketExistenceCheck = socketExistenceCheck
        self.engineIdentifier = "local-chatterbox (\(variant))"
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        guard socketExistenceCheck(socketPath) else { throw NotAvailableError() }

        let interactionID = UUID().uuidString
        let utteranceID = UUID().uuidString
        identityGuard.begin(interactionID: interactionID, utteranceID: utteranceID)
        let session = InFlightSpeechSession(utteranceID: utteranceID, onFinished: onFinished)
        sessionLock.lock(); currentSession = session; sessionLock.unlock()

        let timingBox = TimingBox(requestStart: Date())
        let bodyDict: [String: Any] = ["text": text, "language": "en", "variant": variant]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            clearSession(ifMatching: utteranceID)
            session.deliverOnce(.failed("could not encode local Chatterbox request"))
            return
        }

        let guardRef = identityGuard
        let onTimingHandler = onTiming
        let playerRef = player
        let diag = diagnostics

        transport.requestWithTiming(body, socketPath: socketPath) { [weak self] result, _ in
            guard let self else { return }
            guard guardRef.isCurrent(interactionID: interactionID, utteranceID: utteranceID) else { return } // §7: stale — silently dropped

            switch result {
            case .failure:
                self.clearSession(ifMatching: utteranceID)
                timingBox.update { $0.failureReason = "IPC failure" }
                onTimingHandler?(timingBox.snapshot)
                session.deliverOnce(.failed("local Chatterbox IPC failure"))
                return
            case .success(let data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.clearSession(ifMatching: utteranceID)
                    timingBox.update { $0.failureReason = "malformed response" }
                    onTimingHandler?(timingBox.snapshot)
                    session.deliverOnce(.failed("local Chatterbox malformed response"))
                    return
                }
                let timingDict = json["timing"] as? [String: Any] ?? [:]
                timingBox.update {
                    $0.generationStartMs = timingDict["generationStartMs"] as? Double
                    $0.generationCompleteMs = timingDict["generationCompleteMs"] as? Double
                    $0.audioDurationSec = timingDict["audioDurationSec"] as? Double
                    $0.modelClass = timingDict["modelClass"] as? String
                    $0.checkpointRepo = timingDict["checkpointRepo"] as? String
                }
                guard json["status"] as? String == "ok", let sampleRate = json["sampleRate"] as? Int,
                      let base64 = json["audioBase64"] as? String, let audio = Data(base64Encoded: base64), !audio.isEmpty else {
                    self.clearSession(ifMatching: utteranceID)
                    let serverError = json["error"] as? String ?? "unknown failure"
                    timingBox.update { $0.failureReason = serverError }
                    onTimingHandler?(timingBox.snapshot)
                    session.deliverOnce(.failed("local Chatterbox synthesis failure: \(serverError)"))
                    return
                }
                // §4/§11: honestly the SAME moment — Chatterbox returns one
                // complete waveform, never true incremental audio.
                let decodedAt = Date()
                timingBox.update { $0.audioDecoded = decodedAt; $0.firstPlayableAudio = decodedAt }
                // P2-PROD-BOOTSTRAP-R2.5 §1/§3/§4 — the PROVIDER (local
                // generation) finished HERE, distinct from playback
                // completion below — same distinction Cartesia's own mark
                // preserves, for tier parity.
                diag?.markTurnTiming(\.providerGenerationCompleted)
                diag?.markTurnTiming(\.firstAudioReceived)

                let format = AudioFormatDescriptor(sampleRate: sampleRate, channelCount: 1, sampleFormat: "pcm_f32le", interleaved: true)
                playerRef.play(
                    audio, format: format,
                    onPlaybackStarted: { timingBox.update { $0.playbackStart = Date() }; diag?.markTurnTiming(\.playbackStarted) },
                    onPlaybackComplete: { completedNaturally in
                        timingBox.update { $0.playbackComplete = Date() }
                        onTimingHandler?(timingBox.snapshot)
                        guard guardRef.isCurrent(interactionID: interactionID, utteranceID: utteranceID) else { return } // §7
                        self.clearSession(ifMatching: utteranceID)
                        session.deliverOnce(completedNaturally ? .finished : .interrupted)
                    }
                )
            }
        }
    }

    private func clearSession(ifMatching utteranceID: String) {
        sessionLock.lock()
        if currentSession?.utteranceID == utteranceID { currentSession = nil }
        sessionLock.unlock()
    }

    public func stop() {
        identityGuard.invalidate() // §5/§7: any late IPC response or player completion becomes stale immediately
        player.stop() // §5: stop AVAudioEngine buffers
        sessionLock.lock(); let session = currentSession; currentSession = nil; sessionLock.unlock()
        // §5: guarantee onFinished(.interrupted) exactly once ourselves —
        // mirrors the exact fix P2-M5V9-B.2B made for the Cartesia path,
        // never depending on the player's own completion callback (which
        // `identityGuard.invalidate()` above has already made stale for
        // THIS utterance) to be the one that delivers it.
        session?.deliverOnce(.interrupted)
    }
}
