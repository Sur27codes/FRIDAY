import Foundation

/// Timing configuration for one wake session (§18/§19/§20 of the P2-M3
/// authorization).
public struct WakeSessionConfig: Sendable, Equatable {
    /// How long a `.listening` session stays open with no downstream
    /// speech pipeline (P2-M4 scope) before safely returning to
    /// `.wakeOnly` (§19: "wake detected -> state = LISTENING -> maintain
    /// bounded capture/session for a configured short test interval ->
    /// ... -> timeout -> return to WAKE_ONLY").
    public let listeningTimeout: TimeInterval
    /// Minimum gap between two wake detections before the second one is
    /// treated as a genuine new wake rather than debounced/ignored
    /// (§20: "prevent one spoken phrase from generating repeated wake
    /// events").
    public let cooldown: TimeInterval
    /// P2-M4D: how much consecutive low-energy audio, once speech has
    /// been heard, ends command capture early rather than waiting the
    /// full `listeningTimeout` — the genuine "trailing silence" signal
    /// P2-M4's own instructions asked for, distinct from the overall
    /// bound. A simple RMS-threshold heuristic (`voiceActivityThreshold`
    /// below), not a learned VAD model — bounded, appropriate for this
    /// milestone's scope, and disclosed as such.
    public let trailingSilenceTimeout: TimeInterval
    /// RMS level (normalized [-1,1] samples, so roughly 0–1) above which
    /// a frame counts as "speech present" for the trailing-silence timer.
    public let voiceActivityThreshold: Double
    /// P2-M4D: after telling the STT engine the utterance is over
    /// (`SpeechTranscribing.finishSession()`), how long to wait for it
    /// to actually deliver a finalized/failed result before giving up
    /// and forcing a truthful failure — the safety net that guarantees
    /// "no silent limbo": every command capture terminates in bounded
    /// time no matter what the STT engine does.
    public let finalizeGracePeriod: TimeInterval
    /// P2-M5 §14/§33 — the bounded safety net for `.speaking`: if the
    /// configured `SpeechSynthesizing` engine never calls back after
    /// `speak()` is invoked AT ALL (a genuinely hung/deadlocked engine —
    /// e.g. a provider connection that never completes and never errors),
    /// this is how long `WakeCoordinator` waits before forcing a
    /// truthful failure and returning to `.wakeOnly`, mirroring
    /// `finalizeGracePeriod`'s "no silent limbo" guarantee for the STT
    /// side.
    ///
    /// P2-PROD-BOOTSTRAP-R2.8: originally 30s, calibrated when every
    /// spoken response was short and deterministic (§26 of that earlier
    /// milestone). Once responses became multi-minute (this mission),
    /// that same 30s became a NEW hard cutoff — exactly the "moved the
    /// bug instead of fixing it" anti-pattern this mission explicitly
    /// forbids (§5: "Do NOT replace 5 seconds with 30/60/120 seconds").
    /// This is a deadlock backstop, not a speech-length limit, so it is
    /// raised generously (30 minutes) rather than given a new, still-
    /// arbitrary "reasonable max response" number: real per-utterance
    /// playback in this codebase always terminates via the actual
    /// `onFinished`/`onPlaybackComplete` callback long before this could
    /// ever fire for healthy speech, whatever its length — this only
    /// ever catches a genuinely stuck engine, per §5's own instruction
    /// not to add a wall-clock cap where a progress-based one would be
    /// more correct but isn't otherwise needed by this architecture.
    public let maxSpeechDuration: TimeInterval
    /// P2-PROD-BOOTSTRAP-R2.8 — after a response finishes speaking, how
    /// long `.awaitingFollowUp` waits for the user to START a follow-up
    /// turn before giving up and returning to passive `.wakeOnly`. This
    /// is deliberately NOT a speech timeout and does not bound an
    /// in-progress utterance: it stops counting the instant speech is
    /// detected (mirroring `trailingSilenceTimeout`'s own VAD signal),
    /// at which point the existing `trailingSilenceTimeout`/
    /// `listeningTimeout` rules take over exactly as they already do for
    /// a fresh wake-triggered command (§8/§13 of this mission).
    public let followUpInactivityWindow: TimeInterval

    public init(
        listeningTimeout: TimeInterval, cooldown: TimeInterval,
        trailingSilenceTimeout: TimeInterval = 1.5, voiceActivityThreshold: Double = 0.02,
        finalizeGracePeriod: TimeInterval = 5.0, maxSpeechDuration: TimeInterval = 1_800.0,
        followUpInactivityWindow: TimeInterval = 8.0
    ) {
        self.listeningTimeout = listeningTimeout
        self.cooldown = cooldown
        self.trailingSilenceTimeout = trailingSilenceTimeout
        self.voiceActivityThreshold = voiceActivityThreshold
        self.finalizeGracePeriod = finalizeGracePeriod
        self.maxSpeechDuration = maxSpeechDuration
        self.followUpInactivityWindow = followUpInactivityWindow
    }

    public static let standard = WakeSessionConfig(listeningTimeout: 12, cooldown: 2)
}

/// Every state-affecting thing that can happen to the wake pipeline —
/// same "narrow event set, pure transition function" discipline
/// `SupervisorEngine` already established for P2-M1, reused here because
/// it is exactly the right shape for this problem too.
public enum WakeCoordinatorEvent: Sendable {
    case enableRequested
    case disableRequested
    case deviceUnavailable
    case deviceRecovered
    case rawWakeDetected(phraseID: String, confidence: Double?, engine: String, at: Date)
    case listeningTimedOut
    // P2-M4: command-capture phase, entered from `.listening` (which
    // `rawWakeDetected` above already transitions into, unchanged).
    /// STT finalized an utterance with a transcript that passed
    /// `TranscriptValidation` — WakeCoordinator validates BEFORE
    /// constructing this event, so the engine never sees raw/unvalidated
    /// text (§12: validation happens before anything reaches the pure
    /// state machine, not as a state-machine responsibility).
    case commandUtteranceFinalized(transcript: String)
    /// STT failed, or produced a transcript that failed validation —
    /// either way, no command reaches the runtime, and the session
    /// returns to `.wakeOnly` (§11: "do not fabricate a command").
    case commandTranscriptionFailed(reason: String)
    // P2-M5: spoken-response phase, entered from `.processing` once the
    // runtime call (success OR failure) has finished. `.processing` no
    // longer returns straight to `.wakeOnly` — it first speaks a
    // deterministic, truthful response (§1/§3), then returns.
    /// A safe, bounded, already-sanitized `SpokenResponse.text` is ready
    /// — `.processing` transitions to `.speaking` and the actor begins
    /// synthesis.
    case responseReady(text: String)
    /// The active utterance ended — naturally, via barge-in, or via
    /// Stop/disable/shutdown — `.speaking` returns to `.wakeOnly`. Also
    /// used for a genuinely-empty response (nothing to speak).
    case speechFinished
    /// The active utterance could not be played at all (engine error, or
    /// the `maxSpeechDuration` safety net expired with no callback) —
    /// `.speaking` still returns to `.wakeOnly` (§13 explicitly allows
    /// "processing -> error -> wakeOnly" as a valid alternate path; the
    /// same shape applies one state later here).
    case speechFailed(reason: String)
    /// P2-PROD-BOOTSTRAP-R2.8 §15 — the validated transcript of an
    /// `.awaitingFollowUp` turn matched a bounded, disclosed set of
    /// explicit session-exit phrases ("stop listening", "that's all", …
    /// — see `FollowUpSessionExitPhrases`). Distinct from
    /// `.commandTranscriptionFailed` (nothing failed; the user
    /// succeeded in saying they're done) and from `.listeningTimedOut`
    /// (this is deliberate, not silence) so diagnostics/tests can tell
    /// the three apart.
    case followUpSessionExplicitlyEnded
}

public enum WakeCoordinatorAction: Equatable, Sendable {
    case none
    case startCapture
    case stopCapture
    case emitWakeEvent(WakeEvent)
    /// Tells the actor to submit `transcript` through
    /// `CommandRuntimeSubmitting` — the pure engine only decides that
    /// processing should begin, never performs the I/O itself (same
    /// separation `.startCapture`/`.stopCapture` already establish).
    case beginProcessing(transcript: String)
    /// Tells the actor to hand `text` to `SpeechSynthesizing.speak` — the
    /// pure engine only decides that speaking should begin, never
    /// performs the I/O itself (same separation `.beginProcessing`
    /// already establishes for the runtime call).
    case beginSpeaking(text: String)
    /// P2-PROD-BOOTSTRAP-R2.8 — tells the actor to open the bounded,
    /// wake-word-free follow-up window: start an STT session exactly
    /// like `.startCapture` does for a fresh wake, plus arm the
    /// speech-aware `followUpInactivityWindow` timer.
    case beginFollowUpCapture
}

public struct WakeCoordinatorRuntimeState: Equatable, Sendable {
    public var audioState: AudioState
    /// The user's own wake ON/OFF toggle (§14) — tracked separately from
    /// `audioState` so a transient `.unavailable` (device error) can
    /// correctly resume into `.wakeOnly` on recovery only if the user
    /// actually wanted wake enabled, never the reverse.
    public var wakeEnabled: Bool
    public var lastWakeAt: Date?

    public init(audioState: AudioState = .microphoneOff, wakeEnabled: Bool = false, lastWakeAt: Date? = nil) {
        self.audioState = audioState
        self.wakeEnabled = wakeEnabled
        self.lastWakeAt = lastWakeAt
    }
}

public struct WakeCoordinatorEngine: Sendable {
    public let config: WakeSessionConfig
    public let now: @Sendable () -> Date
    public let makeID: @Sendable () -> String

    public init(config: WakeSessionConfig = .standard, now: @escaping @Sendable () -> Date = { Date() }, makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.config = config
        self.now = now
        self.makeID = makeID
    }

    public func transition(state: WakeCoordinatorRuntimeState, event: WakeCoordinatorEvent) -> (WakeCoordinatorRuntimeState, WakeCoordinatorAction) {
        var state = state
        switch event {
        case .enableRequested:
            state.wakeEnabled = true
            guard state.audioState == .microphoneOff else { return (state, .none) }
            state.audioState = .wakeOnly
            return (state, .startCapture)

        case .disableRequested:
            state.wakeEnabled = false
            let wasActive = state.audioState != .microphoneOff
            state.audioState = .microphoneOff
            return (state, wasActive ? .stopCapture : .none)

        case .deviceUnavailable:
            let wasActive = state.audioState != .microphoneOff && state.audioState != .unavailable
            state.audioState = .unavailable
            return (state, wasActive ? .stopCapture : .none)

        case .deviceRecovered:
            guard state.audioState == .unavailable else { return (state, .none) }
            if state.wakeEnabled {
                state.audioState = .wakeOnly
                return (state, .startCapture)
            }
            state.audioState = .microphoneOff
            return (state, .none)

        case .rawWakeDetected(let phraseID, let confidence, let engineID, let at):
            // Only `.wakeOnly` OR `.speaking` transition on a wake
            // detection. `.speaking` is the P2-M5 barge-in contract
            // (§19/§20): a genuine, deliberate re-utterance of the wake
            // phrase while FRIDAY is talking stops the active response
            // and starts a fresh interaction, exactly like a wake from
            // `.wakeOnly`. `.listening` (debounced by state, not just
            // timestamp), `.microphoneOff`, `.unavailable`, and
            // `.processing` (a runtime call already in flight has no
            // in-progress speech to interrupt, and P2-M5 does not add
            // mid-processing cancellation) all still ignore it
            // (P2M3-WAKE-004/005).
            guard state.audioState == .wakeOnly || state.audioState == .speaking else { return (state, .none) }
            if let last = state.lastWakeAt, at.timeIntervalSince(last) < config.cooldown {
                return (state, .none) // within the cooldown window — debounced
            }
            let sessionID = makeID()
            state.audioState = .listening(sessionID: sessionID)
            state.lastWakeAt = at
            let wakeEvent = WakeEvent(
                eventID: makeID(), sessionID: sessionID, phraseID: phraseID,
                detectedAt: at, source: "wake_word", engine: engineID, confidence: confidence
            )
            return (state, .emitWakeEvent(wakeEvent))

        case .listeningTimedOut:
            // Reused for both "no speech began within the command
            // window" and "spoke too long without an STT finalize" —
            // from the pure state machine's perspective both are simply
            // "give up on this listening session," which is exactly
            // what this transition already did before P2-M4 (the P2-M3
            // placeholder used it as the ENTIRE listening lifecycle;
            // P2-M4 keeps it as the bounding backstop while a real
            // finalize now usually arrives sooner via
            // `commandUtteranceFinalized`).
            guard state.audioState.isActivelyCapturingSpeech else { return (state, .none) }
            state.audioState = .wakeOnly
            return (state, .none)

        case .commandUtteranceFinalized(let transcript):
            guard state.audioState.isActivelyCapturingSpeech else { return (state, .none) }
            state.audioState = .processing
            return (state, .beginProcessing(transcript: transcript))

        case .commandTranscriptionFailed:
            guard state.audioState.isActivelyCapturingSpeech else { return (state, .none) }
            state.audioState = .wakeOnly
            return (state, .none)

        case .followUpSessionExplicitlyEnded:
            // P2-PROD-BOOTSTRAP-R2.8 §15 — only meaningful mid-session;
            // a stray/late event once state has already moved on (e.g.
            // `disable()` raced in) is silently ignored, same shape as
            // every other terminal event in this engine.
            guard case .awaitingFollowUp = state.audioState else { return (state, .none) }
            state.audioState = .wakeOnly
            return (state, .none)

        case .responseReady(let text):
            guard state.audioState == .processing else { return (state, .none) }
            state.audioState = .speaking
            return (state, .beginSpeaking(text: text))

        case .speechFinished:
            // P2-PROD-BOOTSTRAP-R2.8 §7/§9/§10 — a NATURALLY finished
            // response (this event, as opposed to `.speechFailed`) opens
            // the bounded follow-up window instead of returning straight
            // to `.wakeOnly`: the wake word is only required to START a
            // conversation, not before every turn inside one. This is
            // unconditional — every successful spoken response, first
            // turn or Nth, opens a follow-up window; the session only
            // actually ends via explicit exit phrase, inactivity
            // timeout, Stop/Pause, disable, or device failure (all of
            // which already force `.wakeOnly`/`.microphoneOff`/
            // `.unavailable` from ANY state, unchanged by this case).
            guard state.audioState == .speaking else { return (state, .none) }
            let sessionID = makeID()
            state.audioState = .awaitingFollowUp(sessionID: sessionID)
            return (state, .beginFollowUpCapture)

        case .speechFailed:
            guard state.audioState == .speaking else { return (state, .none) }
            state.audioState = .wakeOnly
            return (state, .none)
        }
    }
}
