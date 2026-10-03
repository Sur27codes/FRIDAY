import Foundation

/// P2-M3D §2/§3 — bounded, non-audio diagnostic evidence for each boundary
/// of the real microphone → wake path. This is the thing that would have
/// caught the P2-M3D root cause (zero real frames ever reaching the
/// detector) months earlier than an owner hardware test: "Microphone: Wake
/// Listening" only ever proved `capture.start()`/`detector.start()`
/// returned without throwing, never that a single real audio sample
/// actually flowed through the pipeline.
///
/// Explicitly never records raw PCM content — only counts, rates, and a
/// single RMS/peak *level* value per callback (§3: "DO NOT log raw PCM
/// samples. DO NOT persist raw microphone audio."). A snapshot of this
/// type is safe to print to stdout/NSLog and safe to show in the menu bar.
public struct WakeDiagnosticsSnapshot: Sendable, Equatable {
    public var engineStarted = false
    public var inputDeviceName = "unknown"
    public var inputSampleRate: Double = 0
    public var inputChannelCount: Int = 0
    public var detectorSampleRate: Int32 = 0
    public var audioCallbackCount = 0
    public var samplesReceived = 0
    public var lastRMS: Double = 0
    public var lastPeak: Double = 0
    public var framesForwardedToDetector = 0
    public var detectorResultCount = 0
    public var lastKeywordResult: String = ""
    public var wakeEventCount = 0
    public var lastWakeEventID: String?
    public var lastWakeEventAt: Date?
    public var deviceChangeCount = 0
    public var microphonePermissionStatus = "unknown"
    public var detectorConstructionFailure: String?

    // MARK: - P2-M4: command capture / STT / runtime submission
    public var speechRecognitionPermissionStatus = "unknown"
    public var sttEngineIdentifier = ""
    public var commandCaptureStartedCount = 0
    public var speechStartDetectedCount = 0
    /// P2-M4D — why the most recent command capture stopped listening
    /// ("trailing-silence" / "max-duration" / etc.), set before the STT
    /// engine is told to finalize.
    public var lastCommandCaptureStopReason: String?
    public var framesForwardedToSTT = 0
    public var transcriptionFailureCount = 0
    public var lastTranscriptionFailureReason: String?
    public var transcriptionFinalizedCount = 0
    /// Developer-only, privacy-sensitive — recorded always (so the
    /// recorder itself has it), but `WakeDiagnosticsFormatter.render`
    /// only prints it when explicitly asked to (§19: "must be explicitly
    /// developer-only... Document this").
    public var lastTranscript: String?
    public var lastTranscriptionLatencyMs: Double?
    public var runtimeRequestsSubmitted = 0
    public var lastRuntimeRequestID: String?
    public var lastRuntimeOutcome: String?
    public var returnedToWakeListeningCount = 0

    // MARK: - P2-M5: response presentation / speech synthesis / barge-in
    public var responsesPreparedCount = 0
    public var responsesSpokenCount = 0
    public var lastResponseWasSuccess: Bool?
    /// Developer-only, privacy-sensitive (same rationale as
    /// `lastTranscript`) — recorded always, shown by
    /// `WakeDiagnosticsFormatter.render` only when explicitly opted in.
    public var lastResponseText: String?
    public var ttsEngineIdentifier = ""
    public var speechStartedCount = 0
    public var speechCompletedCount = 0
    public var speechInterruptedCount = 0
    public var speechFailureCount = 0
    public var lastSpeechFailureReason: String?
    public var lastSpeechDurationMs: Double?
    public var lastSpeechResult: String?
    public var bargeInCount = 0

    // MARK: - P2-M5V9-B §25: premium voice session metrics. Additive to
    // the counters above — never a parallel/competing source of truth,
    // never any spoken content, never a credential.
    public var premiumAttemptCount = 0
    public var premiumChunksReceivedCount = 0
    /// P2-M5V9-B.2B — a chunk the provider delivered for an utterance
    /// `UtteranceIdentityGuard` has already superseded/invalidated (§33) —
    /// silently and safely dropped either way, but now actually COUNTED,
    /// so a barge-in acceptance run can report a real number instead of
    /// merely asserting "none resumed."
    public var premiumStaleChunksDiscardedCount = 0
    public var premiumBufferHighWaterBytes = 0
    public var premiumCancellationCount = 0
    public var premiumProviderFailureCount = 0
    public var premiumFallbackBeforePlaybackCount = 0
    public var premiumInterruptionAfterPlaybackCount = 0
    public var samanthaFallbackCount = 0
    public var lastPremiumFirstAudioByteMs: Double?
    /// §25's `SamanthaFallbackRate` — a derived ratio, never independently
    /// settable, so it can never drift from the two counters it reports on.
    public var samanthaFallbackRate: Double? {
        guard premiumAttemptCount > 0 else { return nil }
        return Double(samanthaFallbackCount) / Double(premiumAttemptCount)
    }

    // MARK: - P2-M5V5 §23: conversational persona / adaptive prosody
    /// Every field below is structural metadata about HOW a response was
    /// shaped (which family, which strategy dimensions, which prosody),
    /// never the spoken content itself — so none of it is gated behind
    /// the transcript opt-in the way `lastTranscript`/`lastResponseText`
    /// are (§23: "do not log sensitive conversational content unless
    /// existing explicit diagnostics transcript opt-in enabled" — none
    /// of this IS conversational content).
    public var lastContextResponseFamily = ""
    public var lastStrategyPurpose = ""
    public var lastStrategyWarmth: Double = 0
    public var lastStrategyFormality: Double = 0
    public var lastStrategyUrgency: Double = 0
    public var lastProsodyIntent = ""
    public var lastFinalRate: Float = 0
    public var lastFinalPitch: Float = 0
    public var lastFinalVolume: Float = 0
    public var resolvedVoiceIdentifier: String?
    /// "exact-identifier" (Samantha resolved directly) / "fallback-tier"
    /// (a different installed voice matched by language+gender or plain
    /// language default) / "system-default" (§20's never-crash last
    /// resort — `AVSpeechUtterance.voice = nil`).
    public var voiceFallbackTier = "unknown"

    // MARK: - P2-M5V6 §2/§29: turn-taking / acoustic conversation features
    /// The most recent `SpeakerActivityState` observed by an (optional,
    /// nil-by-default) `TurnTakingTracking` instance — `""` if none is
    /// configured. Structural metadata, not conversational content.
    public var lastSpeakerActivityState = ""
    public var lastAcousticRelativeLoudness: Double?
    public var lastAcousticPauseDensity: Double?
    public var lastAcousticUtteranceDuration: Double?
    public var acousticInterruptionCount = 0
    public var acousticOverlapCount = 0

    // MARK: - P2-M5V8 §23: conversational model provider
    /// "model" or "deterministic" — whichever actually produced the last
    /// understanding/realization (never which one was merely configured).
    public var lastReasonerUsed = ""
    public var lastRealizerUsed = ""
    public var modelProviderRequestCount = 0
    public var modelProviderFailureCount = 0
    public var lastModelProviderLatencyMs: Double?
    /// P2-M5V8.1-HW §13/§14 — the two stages' network latency, tracked
    /// SEPARATELY (unlike `lastModelProviderLatencyMs` above, which is
    /// overwritten by whichever stage recorded most recently and so loses
    /// the other stage's number within the same turn) so a caller can
    /// report reasoner/realizer/combined latency as three distinct,
    /// honest numbers rather than one ambiguous shared value.
    public var lastReasonerLatencyMs: Double?
    public var lastRealizerLatencyMs: Double?
    public var modelSchemaViolationCount = 0
    /// P2-M5V8.1-S2 §2/§3/§9 — precisely WHERE the last reasoner/realizer
    /// attempt stopped short (or `.success`), so a live diagnostic never
    /// has to say the ambiguous "provider rejected" when the
    /// implementation already knows the exact stage. `nil` only before
    /// any attempt has been recorded at all this turn.
    public var lastReasonerOutcome: ProviderStageOutcome?
    public var lastRealizerOutcome: ProviderStageOutcome?
    /// P2-M5V8.1-S2 §18/§19 — the three SEPARATE acceptance diagnostics:
    /// a candidate can be `schemaValid=true, semanticGroundingValid=false,
    /// responseAccepted=false` (a well-formed but ungrounded response was
    /// correctly rejected) — a materially different situation from a
    /// provider/transport failure, and this is the only place that
    /// distinction is actually observable (see
    /// `ConversationalResponsePresenter.realize`'s own doc comment).
    public var lastSchemaValid: Bool?
    public var lastSemanticGroundingValid: Bool?
    public var lastResponseAccepted: Bool?
    /// P2-M5V8.1-S2.1 §2/§3 — WHICH source produced the text actually
    /// spoken this turn. Distinct from `lastRealizerUsed`/
    /// `realizerProviderSucceeded` (provider INFERENCE success) — a model
    /// can succeed at inference and still lose selection here if its
    /// candidate failed semantic grounding.
    public var lastFinalResponseSource: FinalResponseSource?
    /// P2-M5V8.1-O §8/§9 — which PHYSICAL provider architecture actually
    /// ran this turn: `"twoStage"` (the original, still-default separate
    /// reasoner+realizer calls) or `"unifiedOneCall"` (§1: one provider
    /// round trip carrying both a reasoning proposal and candidate
    /// wording). Exists so `lastReasonerUsed`/`lastRealizerUsed`/
    /// `lastReasonerLatencyMs`/`lastRealizerLatencyMs` — reused UNCHANGED
    /// as compatibility views over a single unified response (§9: "reuse
    /// existing diagnostics... document this clearly") — are never
    /// misread as proof of two independent network round trips. Empty
    /// string before any turn has run this session.
    public var lastProviderArchitecture = ""
    /// P2-M5V8.1-O §27/§30 — the ACTUAL number of `ConversationModelRequesting.send`
    /// invocations this turn made (0 when not configured/not attempted).
    /// The direct, unambiguous instrumentation §30 requires: "add
    /// tests/instrumentation proving... EXACTLY ONE model HTTP request."
    public var lastProviderCallCount: Int?
    /// P2-M5V8.1-O.2 §2/§3 — the precise structural decode diagnostic for
    /// the LAST unified-provider attempt that reached a real response
    /// (set only by `ModelUnifiedConversationProvider`; `nil` for every
    /// turn that used the two-stage path, or that never got a response
    /// body at all). See `UnifiedDecodeDiagnostic`'s own doc comment for
    /// the full field list; `sanitizedContentPreview` inside it is `nil`
    /// unless the caller explicitly opted in (only `provider-unified-smoke`
    /// does).
    public var lastUnifiedDecodeDiagnostic: UnifiedDecodeDiagnostic?
    /// P2-M5V8.1-O.4 §3 — the SAME generic structural decode diagnostic,
    /// now ALSO captured for the two-stage reasoner/realizer stages, so
    /// `provider-latency-profile` can report "same metrics" (byte counts,
    /// token usage, finishReason) across all three architectures, not
    /// just unified. `nil` for any turn that never reached a real
    /// response body on that stage.
    public var lastReasonerDecodeDiagnostic: UnifiedDecodeDiagnostic?
    public var lastRealizerDecodeDiagnostic: UnifiedDecodeDiagnostic?
    /// P2-M5V8.1-O.4 §3 — the ACTUAL serialized request byte count sent
    /// for the last attempt on each stage (`nil` if the request was never
    /// built/sent at all — e.g. not configured, or `buildRequest` itself
    /// returned nil). Recorded independently of response-side diagnostics
    /// since a request can be sent even when the response never comes back.
    public var lastReasonerRequestBytes: Int?
    public var lastRealizerRequestBytes: Int?
    public var lastUnifiedRequestBytes: Int?
    /// P2-M5V8.1-O.5 §4/§5 — the actual SPOKEN text's character count for
    /// the last attempt that produced one, on whichever stage actually
    /// realizes text (`nil` for "understand," which never produces
    /// response text at all). Exists so `provider-latency-profile`/
    /// `provider-unified-smoke` can correlate `lastUnifiedResponseScope`
    /// against how much text actually came back, per response class
    /// (§5: "prove output length actually correlates with the
    /// locally-established scope, not just report the field exists").
    public var lastRealizerResponseCharacterCount: Int?
    public var lastUnifiedResponseCharacterCount: Int?
    /// P2-M5V8.1-O.5 §4 — the `ResponseScope` the unified provider sent
    /// for the last attempt (as `String(describing:)`, matching every
    /// other diagnostic enum field in this file) — `nil` for a turn that
    /// never reached `ModelUnifiedConversationProvider.propose(...)` at all.
    public var lastUnifiedResponseScope: String?
    /// P2-M5V8.1-O.6 §5/§6 — how much CONVERSATION HISTORY was actually
    /// sent on the last attempt for each stage: the number of recent
    /// turns included (after `ConversationModelLimits.maxRecentTurns`
    /// truncation) and an APPROXIMATE byte count of just that history
    /// slice (summed truncated transcript/response text, mirroring the
    /// exact same `ConversationModelLimits.truncated(_:to:)` truncation
    /// `buildRequest` itself applies — not a re-serialization of the JSON
    /// wrapper, so it excludes key names/quoting overhead; a lower bound,
    /// not a claim of byte-exact request-JSON size). Exists so
    /// `provider-latency-paired-profile` can correlate latency against
    /// history depth/size independently of total request bytes (which
    /// also includes the fixed system prompt and non-history payload
    /// fields).
    public var lastReasonerHistoryTurnCount: Int?
    public var lastRealizerHistoryTurnCount: Int?
    public var lastUnifiedHistoryTurnCount: Int?
    public var lastReasonerHistoryBytes: Int?
    public var lastRealizerHistoryBytes: Int?
    public var lastUnifiedHistoryBytes: Int?
    /// P2-PROD-BOOTSTRAP-R2.5 §1 — one turn's real state-transition
    /// timeline, monotonic-clock timestamps only (`ProcessInfo.systemUptime`,
    /// immune to wall-clock adjustment) — never a private transcript,
    /// credential, or raw audio sample. Reset at the start of each new
    /// wake event (`beginTurnTiming()`) so a fresh turn never inherits a
    /// stale mark from the previous one.
    public var lastTurnTiming = TurnTimingTrace()

    public init() {}
}

/// P2-PROD-BOOTSTRAP-R2.5 §1 — the exact sanitized per-turn diagnostic
/// record the mission requires: every named timestamp (monotonic,
/// seconds since boot) plus the one question this whole record exists to
/// answer — `activeCaptureReopenedBeforePlaybackCompleted` — computed,
/// never asserted, directly from the two timestamps it depends on.
public struct TurnTimingTrace: Sendable, Equatable {
    public var wakeDetected: TimeInterval?
    public var commandCaptureStarted: TimeInterval?
    public var commandCaptureStopped: TimeInterval?
    public var sttFinalReceived: TimeInterval?
    public var conversationStarted: TimeInterval?
    public var providerRequestStarted: TimeInterval?
    public var providerResponseReceived: TimeInterval?
    public var speechSynthesisStarted: TimeInterval?
    public var firstAudioReceived: TimeInterval?
    public var playbackStarted: TimeInterval?
    public var providerGenerationCompleted: TimeInterval?
    public var speechTerminalCallback: TimeInterval?
    public var playbackCompleted: TimeInterval?
    public var wakePassiveArmed: TimeInterval?
    public var activeCommandCaptureStartedAgain: TimeInterval?

    public init() {}

    /// PART 1's key forensic question, answered directly from real
    /// timestamps: `nil` until BOTH marks exist for this turn (nothing to
    /// compare yet); `true` means the bug is proven — a fresh active
    /// command-capture session opened before the previous utterance's
    /// audio actually finished playing; `false` means the turn behaved
    /// correctly (playback drained before any new capture began, or no
    /// second capture happened at all within this turn's window).
    public var activeCaptureReopenedBeforePlaybackCompleted: Bool? {
        guard let reopened = activeCommandCaptureStartedAgain, let completed = playbackCompleted else { return nil }
        return reopened < completed
    }
}

/// Thread-safe recorder — every method is a cheap lock + a few scalar
/// writes (no allocation beyond what was already necessary, no I/O), so
/// it is safe to call directly from `RealAudioCaptureEngine`'s real-time
/// audio tap callback, matching the real-time-safety bar
/// `RealAudioCaptureEngine` already holds itself to for its own
/// `onFrame`/lock access.
public final class WakeDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var state = WakeDiagnosticsSnapshot()
    private var commandCaptureStartedAt: Date?
    private var speechStartedAt: Date?

    public init() {}

    public func snapshot() -> WakeDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.5 §1: per-turn state-transition timeline

    /// Starts a fresh timeline for a new turn — called exactly where a
    /// wake event is confirmed (both the `.wakeOnly` and the barge-in
    /// `.speaking` path), so a genuinely NEW turn never inherits a stale
    /// mark left over from the previous one.
    public func beginTurnTiming() {
        lock.lock(); defer { lock.unlock() }
        state.lastTurnTiming = TurnTimingTrace()
    }

    /// Records `now()` (monotonic) at `keyPath` in the current turn's
    /// timeline — the FIRST occurrence only (a second call for the same
    /// field is a silent no-op). This matters for correctness, not just
    /// tidiness: a barge-in's audio genuinely stops the instant
    /// `synthesizer.stop()` is called (synchronous, at the audio-engine
    /// level), but the async `onFinished(.interrupted)` callback that
    /// ALSO marks `playbackCompleted` may only run on a later actor turn
    /// — first-write-wins guarantees the mark reflects the true earliest
    /// moment the event actually happened, never a later, redundant
    /// callback overwriting it with a later timestamp. A single generic
    /// setter, rather than fifteen near-identical methods, for the exact
    /// same reason `recordProviderStageOutcome` already parameterizes on
    /// `stage` instead of duplicating itself.
    public func markTurnTiming(_ keyPath: WritableKeyPath<TurnTimingTrace, TimeInterval?>, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard state.lastTurnTiming[keyPath: keyPath] == nil else { return }
        state.lastTurnTiming[keyPath: keyPath] = now
    }

    // MARK: - A/B/C/D: audio engine + real callbacks + signal level + format

    public func recordEngineStarted(deviceName: String, sampleRate: Double, channelCount: Int) {
        lock.lock(); defer { lock.unlock() }
        state.engineStarted = true
        state.inputDeviceName = deviceName
        state.inputSampleRate = sampleRate
        state.inputChannelCount = channelCount
    }

    public func recordEngineStopped() {
        lock.lock(); defer { lock.unlock() }
        state.engineStarted = false
    }

    public func recordDeviceChange() {
        lock.lock(); defer { lock.unlock() }
        state.deviceChangeCount += 1
    }

    /// `rms`/`peak` are levels only (0.0–1.0-ish range for normalized
    /// audio) — never the samples themselves.
    public func recordAudioCallback(sampleCount: Int, rms: Double, peak: Double) {
        lock.lock(); defer { lock.unlock() }
        state.audioCallbackCount += 1
        state.samplesReceived += sampleCount
        state.lastRMS = rms
        state.lastPeak = peak
    }

    // MARK: - E/F/G: frames forwarded to sherpa + detector results

    public func recordDetectorSampleRate(_ rate: Int32) {
        lock.lock(); defer { lock.unlock() }
        state.detectorSampleRate = rate
    }

    public func recordFrameForwardedToDetector() {
        lock.lock(); defer { lock.unlock() }
        state.framesForwardedToDetector += 1
    }

    public func recordDetectorResult(keyword: String) {
        lock.lock(); defer { lock.unlock() }
        state.detectorResultCount += 1
        if !keyword.isEmpty { state.lastKeywordResult = keyword }
    }

    // MARK: - H: WakeCoordinator receives the event

    public func recordWakeEvent(eventID: String, at: Date) {
        lock.lock(); defer { lock.unlock() }
        state.wakeEventCount += 1
        state.lastWakeEventID = eventID
        state.lastWakeEventAt = at
    }

    // MARK: - Permission + detector-construction truthfulness

    public func recordPermissionStatus(_ status: String) {
        lock.lock(); defer { lock.unlock() }
        state.microphonePermissionStatus = status
    }

    public func recordDetectorConstructionFailure(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        state.detectorConstructionFailure = reason
    }

    // MARK: - P2-M4: command capture / STT / runtime submission

    public func recordSpeechRecognitionPermissionStatus(_ status: String) {
        lock.lock(); defer { lock.unlock() }
        state.speechRecognitionPermissionStatus = status
    }

    public func recordCommandCaptureStarted(engineIdentifier: String) {
        lock.lock(); defer { lock.unlock() }
        state.commandCaptureStartedCount += 1
        state.sttEngineIdentifier = engineIdentifier
        commandCaptureStartedAt = Date()
    }

    public func recordSpeechStartDetected() {
        lock.lock(); defer { lock.unlock() }
        state.speechStartDetectedCount += 1
    }

    public func recordCommandCaptureStopReason(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        state.lastCommandCaptureStopReason = reason
    }

    /// Reused per-frame counter for audio forwarded to the STT engine —
    /// deliberately a separate counter from `framesForwardedToDetector`
    /// (the KWS detector's own count), since during `.listening` frames
    /// go to the transcriber, never the wake detector (§8: exclusive
    /// frame ownership per state).
    public func recordFrameForwardedToSTT() {
        lock.lock(); defer { lock.unlock() }
        state.framesForwardedToSTT += 1
    }

    public func recordTranscriptionFailure(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        state.transcriptionFailureCount += 1
        state.lastTranscriptionFailureReason = reason
    }

    /// `text` is the validated transcript — recorded unconditionally
    /// here (this is the recorder's own storage, not yet a print/log
    /// call); whether it is ever actually displayed anywhere is decided
    /// solely by `WakeDiagnosticsFormatter.render`'s `includeTranscript`
    /// flag, gated on a second, explicit developer opt-in (§19).
    public func recordTranscript(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        state.transcriptionFinalizedCount += 1
        state.lastTranscript = text
        if let startedAt = commandCaptureStartedAt {
            state.lastTranscriptionLatencyMs = Date().timeIntervalSince(startedAt) * 1000.0
        }
        commandCaptureStartedAt = nil
    }

    public func recordRuntimeRequestSubmitted(requestID: String) {
        lock.lock(); defer { lock.unlock() }
        state.runtimeRequestsSubmitted += 1
        state.lastRuntimeRequestID = requestID
    }

    public func recordRuntimeOutcome(_ outcome: String) {
        lock.lock(); defer { lock.unlock() }
        state.lastRuntimeOutcome = outcome
    }

    public func recordReturnedToWakeListening() {
        lock.lock(); defer { lock.unlock() }
        state.returnedToWakeListeningCount += 1
        // P2-PROD-BOOTSTRAP-R2.5 §1 — every one of this method's existing
        // call sites (natural completion, failure, permission/transcription
        // failure, safety-net expiry) IS a "returned to passive wake" event
        // — recorded here once, rather than at each of the 8 call sites
        // individually, so none can be missed. First-write-wins (same
        // reasoning as `markTurnTiming`).
        if state.lastTurnTiming.wakePassiveArmed == nil {
            state.lastTurnTiming.wakePassiveArmed = ProcessInfo.processInfo.systemUptime
        }
    }

    // MARK: - P2-M5: response presentation / speech synthesis / barge-in

    /// `text` is the already-safe, already-bounded `SpokenResponse.text`
    /// about to be spoken — recorded unconditionally here (this is the
    /// recorder's own storage, not yet a print/log call), gated on
    /// display the same way `lastTranscript` is (§29: "developer-only
    /// optional response text behind explicit flag").
    public func recordResponsePrepared(_ text: String, wasSuccess: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.responsesPreparedCount += 1
        state.lastResponseWasSuccess = wasSuccess
        state.lastResponseText = text
    }

    public func recordSpeechStarted(engineIdentifier: String) {
        lock.lock(); defer { lock.unlock() }
        state.responsesSpokenCount += 1
        state.speechStartedCount += 1
        state.ttsEngineIdentifier = engineIdentifier
        speechStartedAt = Date()
    }

    public func recordSpeechCompleted(interrupted: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.speechCompletedCount += 1
        if interrupted { state.speechInterruptedCount += 1 }
        state.lastSpeechResult = interrupted ? "interrupted" : "finished"
        if let startedAt = speechStartedAt {
            state.lastSpeechDurationMs = Date().timeIntervalSince(startedAt) * 1000.0
        }
        speechStartedAt = nil
    }

    public func recordSpeechFailure(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        state.speechFailureCount += 1
        state.lastSpeechFailureReason = reason
        state.lastSpeechResult = "failed"
        if let startedAt = speechStartedAt {
            state.lastSpeechDurationMs = Date().timeIntervalSince(startedAt) * 1000.0
        }
        speechStartedAt = nil
    }

    // MARK: - P2-M5V9-B §25: premium voice session metrics

    /// Called once per `PremiumNeuralSpeechSynthesizer.speak` attempt
    /// that actually reaches the provider (i.e. not short-circuited by an
    /// open circuit or "not configured").
    public func recordPremiumAttempt() {
        lock.lock(); defer { lock.unlock() }
        state.premiumAttemptCount += 1
    }

    public func recordPremiumStaleChunkDiscarded() {
        lock.lock(); defer { lock.unlock() }
        state.premiumStaleChunksDiscardedCount += 1
    }

    public func recordPremiumChunkReceived(queuedBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        state.premiumChunksReceivedCount += 1
        state.premiumBufferHighWaterBytes = max(state.premiumBufferHighWaterBytes, queuedBytes)
    }

    public func recordPremiumFirstAudioByte(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        state.lastPremiumFirstAudioByteMs = ms
    }

    public func recordPremiumCancellation() {
        lock.lock(); defer { lock.unlock() }
        state.premiumCancellationCount += 1
    }

    /// - Parameter beforePlayback: `true` when no chunk had been accepted
    ///   yet (§39/§40 — a full-response Samantha replay is safe); `false`
    ///   when premium playback had already started (only the already-
    ///   spoken-through interruption applies, never a duplicate replay).
    public func recordPremiumProviderFailure(beforePlayback: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.premiumProviderFailureCount += 1
        if beforePlayback { state.premiumFallbackBeforePlaybackCount += 1 } else { state.premiumInterruptionAfterPlaybackCount += 1 }
    }

    /// Called only when Samantha (the secondary engine) is ACTUALLY asked
    /// to speak — never merely because it is configured as the fallback.
    public func recordSamanthaFallback() {
        lock.lock(); defer { lock.unlock() }
        state.samanthaFallbackCount += 1
    }

    /// A genuine wake-word-triggered interruption of active speech
    /// (§19/§21/§35) — distinct from `speechInterruptedCount` (which
    /// also counts Stop/disable/shutdown-triggered stops); this counts
    /// only the barge-in path specifically.
    public func recordBargeIn() {
        lock.lock(); defer { lock.unlock() }
        state.bargeInCount += 1
    }

    // MARK: - P2-M5V5 §23: conversational persona / adaptive prosody

    public func recordConversationalPersona(
        responseFamily: String, purpose: String, warmth: Double, formality: Double, urgency: Double,
        prosodyIntent: String, finalRate: Float, finalPitch: Float, finalVolume: Float,
        resolvedVoiceIdentifier: String?, voiceFallbackTier: String
    ) {
        lock.lock(); defer { lock.unlock() }
        state.lastContextResponseFamily = responseFamily
        state.lastStrategyPurpose = purpose
        state.lastStrategyWarmth = warmth
        state.lastStrategyFormality = formality
        state.lastStrategyUrgency = urgency
        state.lastProsodyIntent = prosodyIntent
        state.lastFinalRate = finalRate
        state.lastFinalPitch = finalPitch
        state.lastFinalVolume = finalVolume
        state.resolvedVoiceIdentifier = resolvedVoiceIdentifier
        state.voiceFallbackTier = voiceFallbackTier
    }

    // MARK: - P2-M5V6 §2/§29: turn-taking / acoustic conversation features

    /// - Parameter isNewInterruption/isNewOverlap: EDGE-triggered (true
    ///   only on the frame where the state first became interruption/
    ///   overlap, not for every subsequent frame while it remains so) —
    ///   the caller (`WakeCoordinator`) computes this by comparing
    ///   consecutive `SpeakerActivityState` values, so this recorder
    ///   itself never has to track state transitions.
    public func recordTurnTaking(state activityState: String, features: AcousticConversationFeatures, isNewInterruption: Bool, isNewOverlap: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.lastSpeakerActivityState = activityState
        state.lastAcousticRelativeLoudness = features.relativeLoudness
        state.lastAcousticPauseDensity = features.pauseDensity
        state.lastAcousticUtteranceDuration = features.utteranceDuration
        if isNewInterruption { state.acousticInterruptionCount += 1 }
        if isNewOverlap { state.acousticOverlapCount += 1 }
    }

    // MARK: - P2-M5V8 §23: conversational model provider

    /// §23: never logs prompt/response text or credentials — only
    /// timing/outcome. `stage` is `"understand"` or `"realize"`.
    public func recordModelProviderRequest(stage: String, latencyMs: Double, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.modelProviderRequestCount += 1
        state.lastModelProviderLatencyMs = latencyMs
        if stage == "understand" { state.lastReasonerUsed = succeeded ? "model" : "deterministic"; state.lastReasonerLatencyMs = latencyMs }
        if stage == "realize" { state.lastRealizerUsed = succeeded ? "model" : "deterministic"; state.lastRealizerLatencyMs = latencyMs }
        if !succeeded { state.modelProviderFailureCount += 1 }
    }

    public func recordModelSchemaViolation(stage: String) {
        lock.lock(); defer { lock.unlock() }
        state.modelSchemaViolationCount += 1
    }

    /// P2-M5V8.1-S2 §2/§3/§9 — `stage` is `"understand"` or `"realize"`,
    /// matching `recordModelProviderRequest`'s own convention. Never
    /// receives a credential/header/prompt/transcript — `ProviderStageOutcome`'s
    /// own doc comment establishes why every case it carries is already safe.
    public func recordProviderStageOutcome(stage: String, outcome: ProviderStageOutcome) {
        lock.lock(); defer { lock.unlock() }
        if stage == "understand" { state.lastReasonerOutcome = outcome }
        if stage == "realize" { state.lastRealizerOutcome = outcome }
    }

    /// P2-M5V8.1-S2 §18/§19 — never receives prompt/response text, only
    /// the three booleans themselves.
    public func recordResponseAcceptance(schemaValid: Bool, semanticGroundingValid: Bool, responseAccepted: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.lastSchemaValid = schemaValid
        state.lastSemanticGroundingValid = semanticGroundingValid
        state.lastResponseAccepted = responseAccepted
    }

    /// P2-M5V8.1-S2.1 §2/§3 — never receives the actual text, only which
    /// source it came from.
    public func recordFinalResponseSource(_ source: FinalResponseSource) {
        lock.lock(); defer { lock.unlock() }
        state.lastFinalResponseSource = source
    }

    /// P2-M5V8.1-O §8/§9 — records which physical provider architecture
    /// ran this turn. See `WakeDiagnosticsSnapshot.lastProviderArchitecture`'s
    /// own doc comment for why this exists alongside the reused per-stage
    /// fields rather than replacing them.
    public func recordProviderArchitecture(_ architecture: String) {
        lock.lock(); defer { lock.unlock() }
        state.lastProviderArchitecture = architecture
    }

    /// P2-M5V8.1-O §27/§30 — records the ACTUAL count of `send` calls
    /// made this turn (never inferred/assumed from architecture alone).
    public func recordProviderCallCount(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        state.lastProviderCallCount = count
    }

    /// P2-M5V8.1-O.2 §2/§3 — records the precise structural decode
    /// diagnostic for a unified-provider response. See
    /// `WakeDiagnosticsSnapshot.lastUnifiedDecodeDiagnostic`'s own doc comment.
    public func recordUnifiedDecodeDiagnostic(_ diagnostic: UnifiedDecodeDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        state.lastUnifiedDecodeDiagnostic = diagnostic
    }

    /// P2-M5V8.1-O.4 §3 — `stage` is `"understand"` or `"realize"`,
    /// matching every other per-stage recorder's own convention.
    public func recordStageDecodeDiagnostic(stage: String, _ diagnostic: UnifiedDecodeDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        if stage == "understand" { state.lastReasonerDecodeDiagnostic = diagnostic }
        if stage == "realize" { state.lastRealizerDecodeDiagnostic = diagnostic }
    }

    /// P2-M5V8.1-O.4 §3 — `stage` is `"understand"`, `"realize"`, or
    /// `"unified"`.
    public func recordRequestBytes(stage: String, _ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        switch stage {
        case "understand": state.lastReasonerRequestBytes = bytes
        case "realize": state.lastRealizerRequestBytes = bytes
        case "unified": state.lastUnifiedRequestBytes = bytes
        default: break
        }
    }

    /// P2-M5V8.1-O.5 §4 — `stage` is `"realize"` or `"unified"` (the only
    /// two stages that ever actually produce spoken response text).
    public func recordResponseCharacterCount(stage: String, _ count: Int) {
        lock.lock(); defer { lock.unlock() }
        switch stage {
        case "realize": state.lastRealizerResponseCharacterCount = count
        case "unified": state.lastUnifiedResponseCharacterCount = count
        default: break
        }
    }

    /// P2-M5V8.1-O.5 §4/§6 — records the LOCAL `ResponseScope` the
    /// unified provider sent this turn, so the harness can print it
    /// alongside `lastUnifiedResponseCharacterCount` for a per-scope-class
    /// length correlation (§5).
    public func recordResponseScope(_ scope: String) {
        lock.lock(); defer { lock.unlock() }
        state.lastUnifiedResponseScope = scope
    }

    /// P2-M5V8.1-O.6 §5/§6 — `stage` is `"understand"`, `"realize"`, or
    /// `"unified"`, matching every other per-stage recorder's convention.
    public func recordHistoryStats(stage: String, turnCount: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        switch stage {
        case "understand": state.lastReasonerHistoryTurnCount = turnCount; state.lastReasonerHistoryBytes = bytes
        case "realize": state.lastRealizerHistoryTurnCount = turnCount; state.lastRealizerHistoryBytes = bytes
        case "unified": state.lastUnifiedHistoryTurnCount = turnCount; state.lastUnifiedHistoryBytes = bytes
        default: break
        }
    }
}

/// Owner-readable rendering of a snapshot — used by the `FRIDAY_WAKE_DIAGNOSTICS=1`
/// developer mode (§17: exact fields the owner should be able to read off
/// without inspecting source).
public enum WakeDiagnosticsFormatter {
    /// - Parameter includeTranscript: P2-M4 §19, extended by P2-M5 §29 —
    ///   a second, explicit developer opt-in beyond the base diagnostics
    ///   mode. Both what the user said (the transcript) and what FRIDAY
    ///   said back (the spoken response text) are potentially sensitive
    ///   spoken content, so `FRIDAY_WAKE_DIAGNOSTICS=1` alone (which
    ///   already exposes counts/timings/format info) never shows either
    ///   — only passing `true` here does, and only `AppDelegate` decides
    ///   to pass `true`, gated on a SEPARATE env var
    ///   (`FRIDAY_WAKE_DIAGNOSTICS_INCLUDE_TRANSCRIPT=1`).
    public static func render(_ s: WakeDiagnosticsSnapshot, includeTranscript: Bool = false) -> String {
        var lines: [String] = []
        lines.append("Mic permission: \(s.microphonePermissionStatus)")
        lines.append("Speech recognition permission: \(s.speechRecognitionPermissionStatus)")
        if let failure = s.detectorConstructionFailure {
            lines.append("Detector construction FAILED: \(failure)")
        }
        lines.append("Input device: \(s.inputDeviceName)")
        lines.append("Input rate: \(s.inputSampleRate == 0 ? "n/a (engine not started)" : String(format: "%.0f", s.inputSampleRate))")
        lines.append("Input channels: \(s.inputChannelCount)")
        lines.append("Detector rate: \(s.detectorSampleRate)")
        lines.append("Device changes: \(s.deviceChangeCount)")
        lines.append("Audio callbacks: \(s.audioCallbackCount)")
        lines.append("Samples received: \(s.samplesReceived)")
        lines.append(String(format: "Mic signal (RMS/peak): %.3f / %.3f", s.lastRMS, s.lastPeak))
        lines.append("Frames forwarded to detector: \(s.framesForwardedToDetector)")
        lines.append("Detector results processed: \(s.detectorResultCount)")
        lines.append("Last keyword result: \(s.lastKeywordResult.isEmpty ? "(none yet)" : s.lastKeywordResult)")
        lines.append("Wake events: \(s.wakeEventCount)" + (s.lastWakeEventID.map { " (last: \($0))" } ?? ""))
        lines.append("")
        lines.append("STT engine: \(s.sttEngineIdentifier.isEmpty ? "(not started yet)" : s.sttEngineIdentifier)")
        lines.append("Command captures started: \(s.commandCaptureStartedCount)")
        lines.append("Speech start detected: \(s.speechStartDetectedCount) time(s)")
        lines.append("Last capture stop reason: \(s.lastCommandCaptureStopReason ?? "(none yet)")")
        lines.append("Frames forwarded to STT: \(s.framesForwardedToSTT)")
        lines.append("Transcriptions finalized: \(s.transcriptionFinalizedCount)   Failures: \(s.transcriptionFailureCount)" + (s.lastTranscriptionFailureReason.map { " (last: \($0))" } ?? ""))
        if let latency = s.lastTranscriptionLatencyMs {
            lines.append(String(format: "Last transcription latency: %.0fms", latency))
        }
        if includeTranscript {
            lines.append("Transcript: \(s.lastTranscript ?? "(none yet)")")
        } else if s.lastTranscript != nil {
            lines.append("Transcript: (redacted — set FRIDAY_WAKE_DIAGNOSTICS_INCLUDE_TRANSCRIPT=1 to show)")
        }
        lines.append("Runtime requests submitted: \(s.runtimeRequestsSubmitted)" + (s.lastRuntimeRequestID.map { " (last: \($0))" } ?? ""))
        lines.append("Last runtime outcome: \(s.lastRuntimeOutcome ?? "(none yet)")")
        lines.append("")
        lines.append("TTS engine: \(s.ttsEngineIdentifier.isEmpty ? "(not started yet)" : s.ttsEngineIdentifier)")
        lines.append("Responses prepared: \(s.responsesPreparedCount)   Spoken: \(s.responsesSpokenCount)")
        lines.append("Speech started: \(s.speechStartedCount)   Completed: \(s.speechCompletedCount)   Interrupted: \(s.speechInterruptedCount)")
        lines.append("Speech failures: \(s.speechFailureCount)" + (s.lastSpeechFailureReason.map { " (last: \($0))" } ?? ""))
        if let duration = s.lastSpeechDurationMs {
            lines.append(String(format: "Last speech duration: %.0fms", duration))
        }
        lines.append("Last speech result: \(s.lastSpeechResult ?? "(none yet)")")
        if includeTranscript {
            lines.append("Last response text: \(s.lastResponseText ?? "(none yet)")")
        } else if s.lastResponseText != nil {
            lines.append("Last response text: (redacted — set FRIDAY_WAKE_DIAGNOSTICS_INCLUDE_TRANSCRIPT=1 to show)")
        }
        lines.append("Barge-in events: \(s.bargeInCount)")
        lines.append("Returned to wake listening: \(s.returnedToWakeListeningCount) times")
        lines.append("")
        lines.append("Last response family: \(s.lastContextResponseFamily.isEmpty ? "(none yet)" : s.lastContextResponseFamily)")
        lines.append("Last strategy purpose: \(s.lastStrategyPurpose.isEmpty ? "(none yet)" : s.lastStrategyPurpose)")
        lines.append(String(format: "Last strategy warmth/formality/urgency: %.2f / %.2f / %.2f", s.lastStrategyWarmth, s.lastStrategyFormality, s.lastStrategyUrgency))
        lines.append("Last prosody intent: \(s.lastProsodyIntent.isEmpty ? "(none yet)" : s.lastProsodyIntent)")
        lines.append(String(format: "Last final rate/pitch/volume: %.3f / %.3f / %.3f", s.lastFinalRate, s.lastFinalPitch, s.lastFinalVolume))
        lines.append("Resolved voice: \(s.resolvedVoiceIdentifier ?? "(none yet)") (\(s.voiceFallbackTier))")
        lines.append("")
        lines.append("Speaker activity state: \(s.lastSpeakerActivityState.isEmpty ? "(turn-taking not configured)" : s.lastSpeakerActivityState)")
        if let loudness = s.lastAcousticRelativeLoudness {
            lines.append(String(format: "Acoustic relative loudness: %.3f", loudness))
        }
        if let pauseDensity = s.lastAcousticPauseDensity {
            lines.append(String(format: "Acoustic pause density: %.3f", pauseDensity))
        }
        if let duration = s.lastAcousticUtteranceDuration {
            lines.append(String(format: "Acoustic utterance duration: %.2fs", duration))
        }
        lines.append("Interruptions detected: \(s.acousticInterruptionCount)   Overlaps detected: \(s.acousticOverlapCount)")
        lines.append("")
        lines.append("Reasoner used: \(s.lastReasonerUsed.isEmpty ? "(none yet)" : s.lastReasonerUsed)   Realizer used: \(s.lastRealizerUsed.isEmpty ? "(none yet)" : s.lastRealizerUsed)")
        lines.append("Model provider requests: \(s.modelProviderRequestCount)   Failures: \(s.modelProviderFailureCount)   Schema violations: \(s.modelSchemaViolationCount)")
        if let latency = s.lastModelProviderLatencyMs {
            lines.append(String(format: "Last model provider latency: %.0fms", latency))
        }
        return lines.joined(separator: "\n")
    }
}
