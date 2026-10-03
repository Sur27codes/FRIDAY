import Foundation

/// P2-M5V9 §32 — a cancellable handle for one in-flight premium
/// synthesis stream. Distinct from `ConversationModelCancelToken` (same
/// pattern, different domain — audio streaming, not conversation-model
/// HTTP requests) so the two stay conceptually separate even though both
/// are simple, small wrappers.
public final class SpeechProviderCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?

    public init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        lock.lock(); let action = cancelAction; cancelAction = nil; lock.unlock()
        action?()
    }
}

/// P2-M5V9 §32 — the provider-neutral streaming contract. A real adapter
/// (Stage V9-B, not implemented this pass — see this file's own STOP
/// POINT disclosure) would wrap one vendor's SDK/HTTP API behind this;
/// `PremiumNeuralSpeechSynthesizer` never sees vendor-specific types.
public protocol PremiumSpeechStreamProviding: Sendable {
    var capabilities: PremiumSpeechCapabilities { get }
    /// Streams `SpeechSynthesisEvent`s for exactly one request, calling
    /// `onEvent` zero or more times, ending in exactly one terminal event
    /// (`.completed`/`.failed`/`.cancelled`) UNLESS cancelled via the
    /// returned token first.
    func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken
}

/// P2-M5V9 — architecture-only. NO real neural TTS provider is selected,
/// configured, or called by default — `provider` is `nil` unless a
/// caller explicitly supplies one (§0: this default MUST remain
/// byte-identical to every prior milestone's own disclosed "not
/// configured" stub, since `FallbackSpeechSynthesizer(primary:
/// PremiumNeuralSpeechSynthesizer(), secondary: ...)` is already relied
/// on by existing tests to always fall through to Samantha).
///
/// When a `provider` IS supplied (only ever a fake in this milestone's
/// own tests — see `docs/E-traceability-matrix.md`'s P2-M5V9 section for
/// why no real vendor was integrated), this type implements the real
/// P2-M5V9 safety machinery end to end:
/// - §33: every streamed chunk is checked against `UtteranceIdentityGuard`
///   before being accepted — a stale chunk (wrong/superseded interaction)
///   is silently dropped, never played.
/// - §35/§36: every chunk is validated (`AudioChunkValidator`) and
///   bounded (`AudioChunkBuffer`) before being accepted.
/// - §39/§40: the "before vs. after first audible audio" failure policy —
///   a failure before any chunk was accepted reports `.failed` (letting
///   `FallbackSpeechSynthesizer` speak the FULL response via Samantha,
///   since nothing was heard yet); a failure AFTER at least one chunk was
///   accepted reports `.interrupted` instead (which `FallbackSpeechSynthesizer`
///   passes straight through, never retrying — so already-heard content
///   is never duplicated by a second engine picking up mid-sentence).
/// - §46/§66: `ProviderCircuitBreaker` — an open circuit skips the
///   network attempt entirely, throwing immediately so the caller falls
///   back to Samantha with no added latency.
public final class PremiumNeuralSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public struct NotConfiguredError: Error, CustomStringConvertible {
        public var description: String {
            "PremiumNeuralSpeechSynthesizer: no provider selected or configured (P2-M5V9 — voice candidate evaluation pending real provider credentials and owner A/B listening, see docs/E-traceability-matrix.md's P2-M5V9 section)"
        }
    }
    public struct CircuitOpenError: Error, CustomStringConvertible {
        public var description: String { "PremiumNeuralSpeechSynthesizer: provider circuit is open (repeated recent failures) — skipping network attempt, falling back immediately" }
    }

    private let provider: PremiumSpeechStreamProviding?
    private let voiceProfile: PremiumVoiceProfile
    private let circuitBreaker: ProviderCircuitBreaker
    private let identityGuard = UtteranceIdentityGuard()
    private let diagnostics: WakeDiagnosticsRecorder?
    /// P2-M5V9-B.2B — the current utterance's own session: its cancel
    /// token (so `stop()` can reach the PROVIDER's real cancellation path
    /// — e.g. Cartesia's `context_id`-scoped cancel message — not merely
    /// the local `identityGuard`) AND a delivery-once gate (so `stop()`
    /// ITSELF guarantees the `SpeechSynthesizing` protocol's own
    /// documented contract: "must still deliver exactly one
    /// `onFinished(.interrupted)`... never zero, never twice" — mirroring
    /// `AVSpeechSynthesizerAdapter.stop()`'s existing, already-correct
    /// `deliverOnce` pattern exactly, rather than depending on the
    /// provider's own async cancel acknowledgment ever arriving at all.
    /// Both were real, disclosed gaps: local playback correctly stopped
    /// ACCEPTING chunks on barge-in, but (a) a real remote provider was
    /// never actually told to stop generating/streaming, and (b) nothing
    /// ever guaranteed the caller's own `onFinished` fired at all.
    private let sessionLock = NSLock()
    private var currentSession: InFlightSpeechSession?
    /// P2-M5V9-B.3C §2/§8 — real audible playback for THIS synthesizer's
    /// own accumulated audio, reusing `AVAudioEnginePCMPlayer` (built for
    /// Chatterbox in P2-M5V9-B.3B) rather than a second, ad-hoc player.
    /// `nil` by default — every pre-B.3C call site (including every
    /// existing test using a fake provider) keeps behaving byte-identically:
    /// chunks still accumulate in `AudioChunkBuffer`, `onFinished` still
    /// fires the moment the PROVIDER reports `.completed`, exactly as
    /// before. Only a caller that explicitly supplies a player (this
    /// milestone's `cartesia-skylar-parity`/`friday-voice-ab` tools, and
    /// production `AppDelegate` wiring) gets real speaker output, and for
    /// those, `onFinished` correctly waits for PLAYBACK to finish too —
    /// "the utterance is done" now honestly means "audibly done," not
    /// merely "the network call finished."
    private let player: PCMAudioPlaying?

    public var engineIdentifier: String {
        provider == nil ? "premium-neural (not configured)" : "premium-neural (\(voiceProfile.providerID)/\(voiceProfile.providerVoiceID))"
    }

    public init(
        provider: PremiumSpeechStreamProviding? = nil,
        voiceProfile: PremiumVoiceProfile = PremiumVoiceProfile(voiceProfileID: "unconfigured", providerID: "none", providerVoiceID: "none", profileVersion: "0"),
        circuitBreaker: ProviderCircuitBreaker = ProviderCircuitBreaker(), diagnostics: WakeDiagnosticsRecorder? = nil, player: PCMAudioPlaying? = nil
    ) {
        self.provider = provider
        self.voiceProfile = voiceProfile
        self.circuitBreaker = circuitBreaker
        self.diagnostics = diagnostics
        self.player = player
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        guard let provider else { throw NotConfiguredError() }
        guard circuitBreaker.shouldAttempt() else { throw CircuitOpenError() }
        diagnostics?.recordPremiumAttempt() // P2-M5V9-B §25

        let interactionID = UUID().uuidString
        let utteranceID = UUID().uuidString
        identityGuard.begin(interactionID: interactionID, utteranceID: utteranceID)
        let requestStartedAt = Date()

        let normalizedText = SpeechTextNormalizer.normalize(text)
        let prosody = ProsodyPlan(rate: VoiceProfile.friday.rate, pitchMultiplier: VoiceProfile.friday.pitchMultiplier, volume: VoiceProfile.friday.volume, preUtteranceDelay: VoiceProfile.friday.preUtteranceDelay, postUtteranceDelay: VoiceProfile.friday.postUtteranceDelay, emphasisStrength: 0, energy: FridayPersona.friday.energy)
        let request = SpeechSynthesisRequest(interactionID: interactionID, utteranceID: utteranceID, text: normalizedText, voiceID: voiceProfile.providerVoiceID, language: "en-US", prosody: prosody)

        // P2-PROD-BOOTSTRAP-R2.8 — this buffer is used in "accumulate
        // every chunk, then play ONE concatenated buffer once the
        // provider reports `.completed`" mode (see the `.completed` case
        // below): nothing ever drains it concurrently with generation,
        // so `AudioChunkBuffer.Limits`' default backpressure bounds
        // (sized for a genuinely progressive producer/consumer pair,
        // where a slow player could let generation run away unbounded)
        // do not protect against that scenario here — there is no
        // concurrent consumer to outrun. Left at the defaults
        // (~10s/64 chunks), those bounds instead silently truncated ANY
        // response whose real audio exceeded them: exactly the owner's
        // reported "speech stops dead around 5 seconds in" defect,
        // compounded by `durationEstimate: 0.5` below being a flat
        // per-chunk guess rather than each chunk's real duration, which
        // made the effective cutoff arrive even earlier than the
        // nominal 10s bound implied. Sized here to comfortably exceed
        // any real multi-minute spoken response while still bounding
        // worst-case memory if a provider stream never terminates.
        let buffer = AudioChunkBuffer(limits: AudioChunkBuffer.Limits(maxQueuedBytes: 200_000_000, maxChunkCount: 50_000, maxQueuedDuration: 1_800))
        let playbackState = PlaybackProgressBox()
        let breaker = circuitBreaker
        let guardRef = identityGuard
        let diag = diagnostics
        let session = InFlightSpeechSession(utteranceID: utteranceID, onFinished: onFinished)
        sessionLock.lock(); currentSession = session; sessionLock.unlock()
        // P2-M5V9-B.3C §7 — the REAL sample rate this provider actually
        // used, learned from its own `.metadata` announcement (see
        // `CartesiaSpeechStreamProvider`'s own emission) rather than a
        // hardcoded guess. Fixes a real, disclosed "accidental
        // misinterpretation" risk this milestone's own §7 warns about —
        // a hardcoded `24000` here would have been silently WRONG for
        // Cartesia's actual 44100Hz output the moment real playback (below)
        // was wired in. Falls back to 24000 only if no provider ever
        // announces a rate at all (defensive, never a silent guess used
        // for anything but that one, disclosed fallback case).
        let sampleRateBox = SampleRateBox(fallback: 24000)
        let playerRef = player

        let token = provider.synthesize(request) { [weak self] event in
            // P2-PROD-BOOTSTRAP §B15 — rebinds `self` to a strong, immutable
            // local for the rest of this closure body (Swift 5.7+ shorthand
            // for `guard let self = self else { return }`), rather than
            // repeatedly re-reading the outer `weak var self` from inside a
            // FURTHER-nested `@Sendable` closure (`playerRef.play`'s own
            // `onPlaybackComplete`) — that re-read of a weak-optional var
            // across a nested closure boundary was the actual, real,
            // production-reachable Swift 6 warning here. `self` is already
            // `@unchecked Sendable` (see the class declaration), so
            // capturing this strong, non-optional local into the nested
            // closure below is genuinely safe, not merely silenced.
            guard let self else { return }
            guard guardRef.isCurrent(interactionID: event.interactionID, utteranceID: event.utteranceID) else {
                // §33: stale event for a superseded/cancelled utterance —
                // silently dropped either way; a stale AUDIO CHUNK
                // specifically is also counted (P2-M5V9-B.2B §6/§25) so a
                // barge-in acceptance run can report a real number.
                if case .audioChunk = event { diag?.recordPremiumStaleChunkDiscarded() }
                return
            }
            switch event {
            case .started:
                break
            case .audioChunk(_, _, let samples, _):
                let format = AudioFormatDescriptor(sampleRate: sampleRateBox.value, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true)
                guard AudioChunkValidator.validate(samples, format: format) else { return } // §35: reject, don't crash, don't "repair"
                // P2-PROD-BOOTSTRAP-R2.8 — this chunk's REAL duration
                // (bytes / bytesPerSample / channelCount / sampleRate),
                // not a flat guess: `AudioChunkValidator.validate` above
                // already proves `samples.count` is a whole number of
                // s16 mono frames for `format`, so this division is
                // always exact. A flat per-chunk estimate here — this
                // call site previously hardcoded 0.5s regardless of a
                // chunk's actual size — made `AudioChunkBuffer`'s
                // duration-based backpressure trip on a completely wrong
                // signal, the root cause of the ~5-second cutoff this
                // fixes (§ buffer construction comment above).
                let chunkDuration = Double(samples.count) / 2.0 / Double(max(format.sampleRate, 1))
                guard buffer.enqueue(samples, durationEstimate: chunkDuration) else { return } // §36: backpressure — drop rather than grow unbounded
                let isFirstChunk = !playbackState.hadAcceptedChunk
                playbackState.markChunkAccepted()
                diag?.recordPremiumChunkReceived(queuedBytes: buffer.queuedByteCount) // §25/§43
                if isFirstChunk {
                    diag?.recordPremiumFirstAudioByte(ms: Date().timeIntervalSince(requestStartedAt) * 1000)
                    diag?.markTurnTiming(\.firstAudioReceived)
                }
            case .metadata(_, _, let description):
                // Parses ONLY the specific "sampleRate:<n>" shape this
                // codebase's own providers emit (see `CartesiaSpeechStreamProvider`) —
                // anything else is a genuinely unrelated metadata event
                // and is correctly ignored, not misparsed.
                if description.hasPrefix("sampleRate:"), let rate = Int(description.dropFirst("sampleRate:".count)) {
                    sampleRateBox.set(rate)
                }
            case .completed:
                breaker.recordSuccess()
                diag?.recordSpeechCompleted(interrupted: false)
                // P2-PROD-BOOTSTRAP-R2.5 §1/§3 — the PROVIDER (network
                // generation) finished HERE; this is deliberately a
                // DIFFERENT mark than `playbackCompleted` (below, via
                // `onPlaybackComplete`) — exactly the distinction §3 asks
                // this whole pass to prove is never conflated.
                diag?.markTurnTiming(\.providerGenerationCompleted)
                if let playerRef {
                    // §2/§8: real audible playback, reusing the SAME
                    // player Chatterbox already uses — "accumulate then
                    // play," matching `LocalChatterboxSpeechSynthesizer`'s
                    // established shape exactly, never a second,
                    // competing playback mechanism.
                    //
                    // P2-M5V9-B.3C §5 — the session is DELIBERATELY kept
                    // alive (NOT cleared here) for the whole duration of
                    // playback: generation finishing is no longer "done" —
                    // the utterance is only truly over once PLAYBACK ends,
                    // and a `stop()` call arriving during that window must
                    // still find this session so it can reach `player.stop()`.
                    let audio = buffer.drainAllConcatenated()
                    let format = AudioFormatDescriptor(sampleRate: sampleRateBox.value, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true)
                    // `completedNaturally == false` means `stop()` interrupted
                    // playback (see `player?.stop()` there) — must map to
                    // `.interrupted`, never `.finished`, or a real barge-in
                    // during Cartesia playback would be misreported.
                    playerRef.play(audio, format: format, onPlaybackStarted: { diag?.markTurnTiming(\.playbackStarted) }, onPlaybackComplete: { completedNaturally in
                        self.clearSession(ifMatching: utteranceID)
                        session.deliverOnce(completedNaturally ? .finished : .interrupted)
                    })
                } else {
                    // No player configured (the default, backward-compatible
                    // path every pre-B.3C call site still uses) — generation
                    // completing IS the utterance completing, exactly as before.
                    self.clearSession(ifMatching: utteranceID)
                    session.deliverOnce(.finished)
                }
            case .cancelled:
                diag?.recordPremiumCancellation()
                self.clearSession(ifMatching: utteranceID)
                session.deliverOnce(.interrupted)
            case .failed(_, _, let category):
                breaker.recordFailure(category)
                diag?.recordSpeechFailure("premium provider failure: \(category)")
                diag?.recordPremiumProviderFailure(beforePlayback: !playbackState.hadAcceptedChunk)
                self.clearSession(ifMatching: utteranceID)
                // §39/§40: never let a second engine replay content the
                // user already heard part of — `.interrupted` is passed
                // straight through by `FallbackSpeechSynthesizer`,
                // `.failed` triggers its Samantha retry.
                session.deliverOnce(playbackState.hadAcceptedChunk ? .interrupted : .failed("premium provider: \(category)"))
            }
        }
        // The cancel token only exists once `synthesize(...)` returns —
        // a provider may complete/fail entirely SYNCHRONOUSLY before
        // that, in which case `session` is already delivered and this is
        // a harmless, never-used store (§B.2B: storing it anyway is safe
        // since `stop()` only ever reads it through the SAME session
        // object, and a delivered session is always cleared/replaced
        // before any real `stop()` could reach it).
        session.setCancelToken(token)
    }

    private func clearSession(ifMatching utteranceID: String) {
        sessionLock.lock()
        if currentSession?.utteranceID == utteranceID { currentSession = nil }
        sessionLock.unlock()
    }

    public func stop() {
        identityGuard.invalidate() // §11/§33: any chunk still in flight becomes stale immediately
        sessionLock.lock(); let session = currentSession; currentSession = nil; sessionLock.unlock()
        guard let session else { return }
        // P2-M5V9-B.2B §1: actually reach the provider's own
        // cancellation path (e.g. Cartesia's context_id-scoped cancel
        // message over the still-open WebSocket) — never just the local
        // identity guard. Called BEFORE `deliverOnce` so a provider that
        // synchronously acknowledges cancellation inline still only ever
        // results in ONE delivered outcome (via `deliverOnce`'s own
        // exactly-once gate — whichever of the two "wins" the race).
        session.cancelToken?.cancel()
        // P2-M5V9-B.3C §5: also stop real playback, if any is in flight —
        // a harmless no-op when no player is configured or nothing is
        // currently playing.
        player?.stop()
        // P2-M5V9-B.2B §2: guarantee the `SpeechSynthesizing` protocol's
        // own contract ourselves — never depend on the provider's async
        // acknowledgment ever arriving, matching `AVSpeechSynthesizerAdapter.stop()`'s
        // existing, already-correct pattern exactly.
        session.deliverOnce(.interrupted)
    }
}

/// P2-M5V9-B.2B — one in-flight utterance's full local state: its own
/// cancel token (set once `synthesize(...)` returns) and an
/// exactly-once delivery gate for `onFinished`, mirroring
/// `AVSpeechSynthesizerAdapter`'s own `delivered`/`deliverOnce` pattern
/// so `PremiumNeuralSpeechSynthesizer` satisfies the EXACT SAME
/// `SpeechSynthesizing` contract that adapter already does. Isolated
/// into its own `Sendable` type (matching every other small state box in
/// this file) so `speak`/`stop`, and the streaming callback closure, can
/// all safely reference one shared instance per utterance. Not `private`
/// — `LocalChatterboxSpeechSynthesizer.swift` (P2-M5V9-B.3B) reuses this
/// same small, generic "deliver onFinished exactly once" gate rather
/// than duplicating it; that type never calls `setCancelToken` (Chatterbox
/// has no mid-flight cancel — `cancelToken` simply stays `nil` for it).
final class InFlightSpeechSession: @unchecked Sendable {
    let utteranceID: String
    private let onFinished: @Sendable (SpeechSynthesisOutcome) -> Void
    private let lock = NSLock()
    private var delivered = false
    private(set) var cancelToken: SpeechProviderCancelToken?

    init(utteranceID: String, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) {
        self.utteranceID = utteranceID
        self.onFinished = onFinished
    }

    func setCancelToken(_ token: SpeechProviderCancelToken) {
        lock.lock(); cancelToken = token; lock.unlock()
    }

    @discardableResult
    func deliverOnce(_ outcome: SpeechSynthesisOutcome) -> Bool {
        lock.lock()
        guard !delivered else { lock.unlock(); return false }
        delivered = true
        lock.unlock()
        onFinished(outcome)
        return true
    }
}

/// A tiny, lock-protected flag tracking whether ANY audio chunk was
/// accepted yet this utterance — exactly the fact §39/§40's "before vs.
/// after first audible audio" policy needs, isolated into its own
/// `Sendable` type so the streaming callback closure never captures a
/// bare mutable `var` across concurrent invocations.
private final class PlaybackProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = false

    func markChunkAccepted() {
        lock.lock(); accepted = true; lock.unlock()
    }

    var hadAcceptedChunk: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }
}

/// P2-M5V9-B.3C §7 — a tiny, lock-protected holder for the REAL sample
/// rate a provider announces via `.metadata`, isolated the same way
/// every other small state box in this file is. Starts at an explicit,
/// disclosed fallback — never silently `0` or an uninitialized guess.
private final class SampleRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Int

    init(fallback: Int) { rate = fallback }

    func set(_ newRate: Int) {
        lock.lock(); rate = newRate; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return rate
    }
}

/// P2-M5V9 §21/§28 — the required fallback hierarchy, generalized into a
/// real, testable composite: try `primary` first; if it cannot even
/// begin (`speak` throws) OR reports `.failed` after starting, retry
/// exactly once via `secondary`, delivering exactly one final
/// `onFinished` to the caller either way (preserving `SpeechSynthesizing`'s
/// own "exactly once" contract). `.finished`/`.interrupted` from
/// `primary` pass straight through — a fallback only ever engages on
/// genuine failure, never on a normal completed or barge-in-interrupted
/// utterance, and never on a `PremiumNeuralSpeechSynthesizer` failure
/// that already delivered partial audible content (§39/§40 — that
/// engine reports `.interrupted`, not `.failed`, for exactly this
/// reason).
///
/// Composing `FallbackSpeechSynthesizer(primary: PremiumNeuralSpeechSynthesizer(), secondary: AVSpeechSynthesizerAdapter(...))`
/// today is a REAL, working, tested configuration: since the premium
/// side always throws immediately when unconfigured (the disclosed "not
/// configured" default), every utterance transparently and correctly
/// falls through to Samantha — proving this fallback machinery works
/// end-to-end without requiring an actual neural engine to exist yet.
public final class FallbackSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let primary: SpeechSynthesizing
    private let secondary: SpeechSynthesizing
    /// P2-M5V9-B §13/§25 — optional, additive: records `SamanthaFallbackRate`'s
    /// numerator (§25) ONLY at the moment `secondary` is actually asked to
    /// speak, never merely because it is configured. `nil` by default —
    /// every pre-V9-B call site keeps compiling and behaving unchanged.
    private let diagnostics: WakeDiagnosticsRecorder?

    public var engineIdentifier: String { "\(primary.engineIdentifier) -> fallback:\(secondary.engineIdentifier)" }

    public init(primary: SpeechSynthesizing, secondary: SpeechSynthesizing, diagnostics: WakeDiagnosticsRecorder? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.diagnostics = diagnostics
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        do {
            try primary.speak(text, category: category, onFinished: { [secondary, diagnostics] outcome in
                switch outcome {
                case .finished, .interrupted:
                    onFinished(outcome)
                case .failed:
                    do {
                        diagnostics?.recordSamanthaFallback()
                        try secondary.speak(text, category: category, onFinished: onFinished)
                    } catch {
                        onFinished(.failed("primary failed after starting, secondary could not begin: \(error)"))
                    }
                }
            })
        } catch {
            // Primary could not even begin synchronously — try secondary
            // immediately; if IT throws too, propagate that (both
            // engines are genuinely unavailable).
            diagnostics?.recordSamanthaFallback()
            try secondary.speak(text, category: category, onFinished: onFinished)
        }
    }

    public func stop() {
        primary.stop()
        secondary.stop()
    }
}
