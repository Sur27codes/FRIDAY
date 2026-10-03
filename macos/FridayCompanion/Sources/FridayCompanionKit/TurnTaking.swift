import Foundation

/// P2-M5V6 §2 — the closed set of turn-taking states this codebase
/// actually tracks. Deliberately NOT an emotion or intent model — purely
/// "is acoustic energy present, and whose turn does it look like."
public enum SpeakerActivityState: Sendable, Equatable {
    case silence
    case speech
    case trailingSilence
    case overlappingSpeech
    case interruption
}

/// A single, cheap, real-time-safe yes/no decision on one audio frame —
/// deliberately separated from `TurnTakingCoordinator`'s stateful turn
/// tracking so the raw energy-threshold decision stays independently
/// swappable/testable (§2: "use real acoustic VAD / endpointing" — this
/// is today's real, disclosed implementation of that: an RMS-energy
/// threshold, the same one `WakeCoordinator.updateVoiceActivity` already
/// uses via `SimpleVoiceActivity`, factored out here as its own
/// protocol-backed component rather than a second, separately-tuned
/// heuristic).
public protocol VoiceActivityDetecting: Sendable {
    func isSpeechPresent(in frame: AudioFrame) -> Bool
}

public struct ThresholdVoiceActivityDetector: VoiceActivityDetecting {
    public let threshold: Double

    public init(threshold: Double = WakeSessionConfig.standard.voiceActivityThreshold) {
        self.threshold = threshold
    }

    public func isSpeechPresent(in frame: AudioFrame) -> Bool {
        SimpleVoiceActivity.rms(of: frame.samples) >= threshold
    }
}

/// P2-M5V6 §2/§17 — bounded configuration for `TurnTakingCoordinator`.
/// `voiceActivityThreshold`/`trailingSilenceTimeout` intentionally match
/// `WakeSessionConfig`'s own defaults (0.02 / 1.5s) so this new,
/// STANDALONE turn-tracking layer reasons about "has the user stopped
/// talking" using the same calibration as the already-proven, already-
/// tested command-capture finalization logic in `WakeCoordinator`,
/// without being the same code path (§2: "preserve existing STT
/// finalization reliability" — this type observes audio in parallel for
/// richer turn-state/diagnostics purposes; it does not replace or
/// influence `WakeCoordinator.updateVoiceActivity`'s own finalization
/// decision this milestone).
public struct TurnTakingConfig: Sendable, Equatable {
    public let voiceActivityThreshold: Double
    public let trailingSilenceTimeout: TimeInterval
    /// How long speech must be sustained WHILE FRIDAY is speaking before
    /// it is treated as a genuine interruption rather than a brief
    /// overlap (a cough, a stray word, an echo artifact) — §18's
    /// "require conservative confidence / sustained speech."
    public let interruptionSustainedDuration: TimeInterval

    public init(
        voiceActivityThreshold: Double = WakeSessionConfig.standard.voiceActivityThreshold,
        trailingSilenceTimeout: TimeInterval = WakeSessionConfig.standard.trailingSilenceTimeout,
        interruptionSustainedDuration: TimeInterval = 0.3
    ) {
        self.voiceActivityThreshold = voiceActivityThreshold
        self.trailingSilenceTimeout = trailingSilenceTimeout
        self.interruptionSustainedDuration = interruptionSustainedDuration
    }

    public static let standard = TurnTakingConfig()
}

/// P2-M5V6 §2/§3/§17 — real, testable turn-taking + a small set of
/// genuinely-measured acoustic facts, all derived from the exact same
/// audio-level signal this codebase already computes elsewhere (never a
/// second raw-audio-persisting pipeline). Deterministic given a stream of
/// `AudioFrame`s (each frame carries its own `capturedAt`, so tests never
/// depend on wall-clock timing).
///
/// **Not wired into `WakeCoordinator`'s live state machine this
/// milestone** (§2's own "preserve existing STT finalization
/// reliability," and §18's "document experimental natural interruption
/// separately") — this is a real, standalone, independently-testable
/// component ready to observe the same audio `WakeCoordinator` already
/// captures for diagnostics/harness purposes, and ready for a future,
/// separately-authorized pass to wire into the live pipeline once real
/// microphone-hardware validation exists. See `docs/E-traceability-matrix.md`'s
/// P2-M5V6 section for the full disclosed reasoning.
public protocol TurnTakingTracking: Sendable {
    @discardableResult
    func process(frame: AudioFrame, isFridaySpeaking: Bool) -> SpeakerActivityState
    func currentState() -> SpeakerActivityState
    func acousticFeatures() -> AcousticConversationFeatures
    /// Resets turn-local timing (utterance start, rolling loudness
    /// window) — called at the start of a new command-capture session so
    /// `utteranceDuration`/`pauseDensity` describe THIS turn, not a
    /// leftover from the previous one.
    func beginNewTurn()
}

public final class TurnTakingCoordinator: TurnTakingTracking, @unchecked Sendable {
    private let config: TurnTakingConfig
    private let detector: VoiceActivityDetecting
    private let lock = NSLock()

    private var state: SpeakerActivityState = .silence
    private var turnStartedAt: Date?
    private var lastAboveThresholdAt: Date?
    private var sustainedOverlapStartedAt: Date?
    private var interruptionDetectedThisTurn = false
    private var overlapDetectedThisTurn = false
    /// The most recently processed frame's own timestamp — used (instead
    /// of wall-clock `Date()`) to compute `utteranceDuration` so this
    /// entire type stays deterministic/testable purely from the
    /// `capturedAt` values a test supplies, with zero dependency on real
    /// elapsed wall-clock time.
    private var lastFrameAt: Date?

    /// Bounded rolling window of recent (rms, wasSpeech) samples, used
    /// only to compute `relativeLoudness`/`pauseDensity` — never the
    /// underlying audio itself (§29: "do not log raw audio"; this holds
    /// two `Double`s per frame, not samples).
    private var recentLevels: [(rms: Double, wasSpeech: Bool)] = []
    private let maxRecentLevels = 200

    public init(config: TurnTakingConfig = .standard, detector: VoiceActivityDetecting = ThresholdVoiceActivityDetector()) {
        self.config = config
        self.detector = detector
    }

    @discardableResult
    public func process(frame: AudioFrame, isFridaySpeaking: Bool) -> SpeakerActivityState {
        lock.lock(); defer { lock.unlock() }
        let now = frame.capturedAt
        lastFrameAt = now
        let rms = SimpleVoiceActivity.rms(of: frame.samples)
        let speechPresent = rms >= config.voiceActivityThreshold
        recordLevel(rms: rms, wasSpeech: speechPresent)

        if speechPresent {
            if turnStartedAt == nil { turnStartedAt = now }
            lastAboveThresholdAt = now
            if isFridaySpeaking {
                if sustainedOverlapStartedAt == nil { sustainedOverlapStartedAt = now }
                let sustainedFor = now.timeIntervalSince(sustainedOverlapStartedAt!)
                if sustainedFor >= config.interruptionSustainedDuration {
                    state = .interruption
                    interruptionDetectedThisTurn = true
                } else {
                    state = .overlappingSpeech
                    overlapDetectedThisTurn = true
                }
            } else {
                sustainedOverlapStartedAt = nil
                state = .speech
            }
        } else {
            sustainedOverlapStartedAt = nil
            if let lastAbove = lastAboveThresholdAt, turnStartedAt != nil {
                let silentFor = now.timeIntervalSince(lastAbove)
                state = silentFor >= config.trailingSilenceTimeout ? .silence : .trailingSilence
            } else {
                state = .silence
            }
        }
        return state
    }

    public func currentState() -> SpeakerActivityState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func beginNewTurn() {
        lock.lock(); defer { lock.unlock() }
        state = .silence
        turnStartedAt = nil
        lastAboveThresholdAt = nil
        sustainedOverlapStartedAt = nil
        interruptionDetectedThisTurn = false
        overlapDetectedThisTurn = false
        lastFrameAt = nil
        recentLevels.removeAll()
    }

    /// P2-M5V6 §3 — only fields backed by a genuine, cheap computation
    /// from the existing RMS/timing signal are populated; `speechRateEstimate`/
    /// `pitchRange`/`pitchVariation` are honestly left `nil` rather than
    /// faked — real pitch tracking/rate estimation is a separate,
    /// not-yet-built DSP component, disclosed here rather than
    /// approximated with false confidence.
    public func acousticFeatures() -> AcousticConversationFeatures {
        lock.lock(); defer { lock.unlock() }
        guard !recentLevels.isEmpty else { return .unavailable }
        let speechSamples = recentLevels.filter(\.wasSpeech)
        let relativeLoudness: Double? = speechSamples.isEmpty ? nil
            : min(1.0, (speechSamples.map(\.rms).reduce(0, +) / Double(speechSamples.count)) / 0.3)
        let pauseDensity = Double(recentLevels.filter { !$0.wasSpeech }.count) / Double(recentLevels.count)
        let utteranceDuration: TimeInterval? = turnStartedAt.flatMap { start in lastFrameAt.map { $0.timeIntervalSince(start) } }
        return AcousticConversationFeatures(
            speechRateEstimate: nil, relativeLoudness: relativeLoudness, pitchRange: nil, pitchVariation: nil,
            pauseDensity: pauseDensity, utteranceDuration: utteranceDuration,
            interruptionDetected: interruptionDetectedThisTurn, overlapDetected: overlapDetectedThisTurn,
            speakingContinuously: state == .speech, signalConfidence: 1.0
        )
    }

    private func recordLevel(rms: Double, wasSpeech: Bool) {
        recentLevels.append((rms, wasSpeech))
        if recentLevels.count > maxRecentLevels { recentLevels.removeFirst(recentLevels.count - maxRecentLevels) }
    }
}

/// Null-object counterpart (matching this codebase's established
/// `NullSpeechSynthesizer`/`NullWakeWordDetector` convention) — for
/// callers that want the turn-taking SHAPE without any real tracking.
public struct NullTurnTakingTracking: TurnTakingTracking {
    public init() {}
    @discardableResult
    public func process(frame: AudioFrame, isFridaySpeaking: Bool) -> SpeakerActivityState { .silence }
    public func currentState() -> SpeakerActivityState { .silence }
    public func acousticFeatures() -> AcousticConversationFeatures { .unavailable }
    public func beginNewTurn() {}
}

/// P2-M5V6 §4 — separates "someone is speaking" (real today, via
/// `TurnTakingTracking`) from "WHO is speaking." `.unknown` is the only
/// value this codebase ever actually produces — matching `UserContext.ownerLocal`'s
/// own precedent from P2-M5V5. Wake word is activation, not identity
/// proof (§4's own explicit instruction) — no code path in this file or
/// anywhere else in this milestone attaches `.enrolledAuthenticated` to
/// anything.
public enum SpeakerIdentity: Sendable, Equatable {
    case unknown
    case enrolledAuthenticated(profileID: String)
}
