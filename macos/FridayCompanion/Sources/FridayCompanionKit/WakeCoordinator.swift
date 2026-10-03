import Foundation

/// Truthful reasons the wake pipeline can be unavailable — surfaced to
/// the menu bar (§13) instead of a generic "off" so the user (and tests)
/// can tell *why* (§12: "no fake listening state").
public enum WakeUnavailableReason: Equatable, Sendable {
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case deviceError(String)
    case detectorFailedToStart(String)
}

/// The outcome of one runtime submission — deliberately plain, not
/// `Result<RuntimeTextResult, any Error>` (existential `Error` isn't
/// `Sendable`-friendly across the `Task.detached` boundary here), and
/// the failure case only ever needs a description for diagnostics, not
/// programmatic error handling.
///
/// `public` since P2-M5: this is the sole input to `ResponsePresenting`,
/// a public protocol production code outside this file implements
/// (`AppDelegate` wires a real presenter; tests supply fakes) — Swift's
/// access control requires the type appearing in a public protocol
/// requirement to be at least as visible as the protocol itself.
public enum CommandRuntimeOutcome: Sendable {
    case success(RuntimeTextResult)
    case failure(String)
}

/// Orchestrates audio capture + wake detection + command-capture speech
/// transcription + submission through the existing runtime, all driven
/// by the pure `WakeCoordinatorEngine` state machine. An `actor` for the
/// same reason `Supervisor` is one: multiple asynchronous sources (frame
/// arrivals, timers, user enable/disable actions, device-change
/// notifications, STT results, runtime responses) all mutate shared
/// state and must not race each other.
///
/// P2-M4 architectural rule (§3, restated here since this is the one
/// type that touches every stage): voice is only another INPUT ADAPTER.
/// The only thing this actor ever does with a validated transcript is
/// call `CommandRuntimeSubmitting.submitText` — the exact same interface
/// `RuntimeClient` already exposes to typed input. There is no method
/// anywhere in this file that calls a capability directly, reaches the
/// Capability Bus, or constructs anything resembling an authorization
/// decision.
public actor WakeCoordinator {
    private let capture: AudioCapturing
    private let detector: WakeWordDetecting
    private let permission: MicrophonePermissionChecking
    private let transcriber: SpeechTranscribing
    private let runtimeSubmitter: CommandRuntimeSubmitting
    /// `nil` (the default) means "do not gate command capture on
    /// Speech-Recognition permission at all" — the correct behavior for
    /// every pre-P2-M4 test and any `NullSpeechTranscriber`-based
    /// configuration, none of which need real permission to behave
    /// correctly. Production wiring (`AppDelegate`) passes a real
    /// `RealSpeechRecognitionPermission`.
    private let speechPermission: SpeechRecognitionPermissionChecking?
    /// P2-M5: the ONLY thing that ever plays audio out loud. Never
    /// called with anything but `SpokenResponse.text` produced by
    /// `responsePresenter` — never a raw runtime payload, never a
    /// transcript, never anything else in this actor's state (§3: TTS is
    /// an output adapter with zero execution authority, and symmetrically
    /// zero access to anything beyond the one bounded string it's told
    /// to speak).
    private let synthesizer: SpeechSynthesizing
    private let responsePresenter: ResponsePresenting
    /// P2-M5V5 §23 — diagnostics-only. These three are the SAME
    /// deterministic, side-effect-free components `responsePresenter`
    /// already uses internally to decide what to say; this coordinator
    /// re-invokes them independently, purely to surface their otherwise-
    /// private intermediate decisions (response family, strategy
    /// purpose/warmth/formality/urgency, final bounded prosody) into
    /// diagnostics, without changing `ResponsePresenting`'s protocol or
    /// `SpokenResponse`'s shape. `ResponseStrategyPlanner` never reads
    /// `ConversationContext.recentResponseFamilies`, so recomputing
    /// context+strategy here (with an empty history, since this
    /// coordinator doesn't track that private repetition-control state)
    /// always agrees with what `responsePresenter` actually decided —
    /// this never risks disagreeing with, or duplicating the RULES
    /// behind, the real decision.
    private let diagnosticsContextCompiler: ConversationContextCompiling
    private let diagnosticsStrategyPlanner: ResponseStrategyPlanning
    private let diagnosticsProsodyPlanner: AdaptiveProsodyPlanning
    /// P2-M5V6 §2/§29 — diagnostics-only real turn-taking observation.
    /// `nil` by default (zero behavior/perf change for every existing
    /// caller/test). When configured, EVERY frame this coordinator
    /// receives (regardless of `AudioState`) is also fed here purely for
    /// observation — it never influences `engine.transition(...)`, never
    /// changes frame routing, and is not consulted by
    /// `updateVoiceActivity`'s own command-finalization decision (§2:
    /// "preserve existing STT finalization reliability" — this is a
    /// parallel observer, not a replacement).
    private let turnTaking: TurnTakingTracking?
    /// Edge-detection state for turn-taking diagnostics counters only —
    /// see `handleFrame`'s own comment.
    private var lastSpeakerActivityStateForCounting: SpeakerActivityState = .silence
    private let engine: WakeCoordinatorEngine
    /// P2-M3D §10 — when the real detector could not be constructed and
    /// the caller had to fall back to `NullWakeWordDetector` (or any
    /// other non-functional stand-in), this carries WHY, and `enable()`
    /// refuses to ever report `.wakeOnly` while it is set. Before this,
    /// a construction-time fallback in `AppDelegate` swapped in a
    /// trivially-succeeding `NullWakeWordDetector` and the coordinator
    /// had no way to tell the difference from a genuinely working
    /// detector — "Microphone: Wake Listening" would have been shown
    /// while wake detection was actually impossible. `nil` means the
    /// caller is using a real, intentionally-constructed detector (this
    /// is also `nil` for tests/explicitly-disabled-wake fixtures that
    /// deliberately use `NullWakeWordDetector`/a fake on purpose, not as
    /// an unwanted fallback).
    private let detectorUnavailableReason: String?
    private let diagnostics: WakeDiagnosticsRecorder?

    private var runtimeState = WakeCoordinatorRuntimeState()
    private var unavailableReason: WakeUnavailableReason?
    private var listeningTimeoutTask: Task<Void, Never>?
    /// P2-M4D: the safety net started once `finishSession()` has been
    /// called — guarantees a bounded, truthful outcome even if the STT
    /// engine never calls back after being told the utterance is over.
    private var finalizeGraceTask: Task<Void, Never>?
    /// P2-M4D: true from the moment command capture decides the
    /// utterance is over (trailing silence or max duration) until an
    /// outcome is actually delivered — an idempotency guard so the
    /// trailing-silence check and the max-duration backstop can never
    /// both call `finishSession()`/start the grace timer for the same
    /// session.
    private var isFinalizingCommand = false
    /// P2-M4D voice-activity tracking for the CURRENT command-capture
    /// session only — reset at the start of each session
    /// (`beginCommandCapture()`). A simple RMS-threshold heuristic
    /// (`WakeSessionConfig.voiceActivityThreshold`), not a learned VAD
    /// model — see that config's own doc comment for why this bounded
    /// approach is appropriate here.
    private var vadSpeechStarted = false
    private var vadLastAboveThresholdAt: Date?
    private var wakeEventHandler: (@Sendable (WakeEvent) -> Void)?
    /// P2-M5 §14/§33 safety net for `.speaking` — mirrors
    /// `finalizeGraceTask`'s role for STT: guarantees a bounded, truthful
    /// outcome even if the configured `SpeechSynthesizing` engine never
    /// calls back after `speak()`.
    private var speechSafetyNetTask: Task<Void, Never>?
    /// P2-PROD-BOOTSTRAP-R2.8 — armed the moment `.awaitingFollowUp`
    /// begins, cancelled the instant `updateVoiceActivity` sees the user
    /// start talking (mirroring how `vadSpeechStarted` already gates
    /// trailing-silence detection). Fires only "no speech at all within
    /// `followUpInactivityWindow`" — never a bound on an utterance
    /// already in progress.
    private var followUpInactivityTask: Task<Void, Never>?

    public init(
        capture: AudioCapturing, detector: WakeWordDetecting, permission: MicrophonePermissionChecking,
        transcriber: SpeechTranscribing = NullSpeechTranscriber(),
        runtimeSubmitter: CommandRuntimeSubmitting = NullCommandRuntimeSubmitting(),
        speechPermission: SpeechRecognitionPermissionChecking? = nil,
        synthesizer: SpeechSynthesizing = NullSpeechSynthesizer(),
        responsePresenter: ResponsePresenting = DeterministicResponsePresenter(),
        diagnosticsContextCompiler: ConversationContextCompiling = DeterministicConversationContextCompiler(),
        diagnosticsStrategyPlanner: ResponseStrategyPlanning = DeterministicResponseStrategyPlanner(),
        diagnosticsProsodyPlanner: AdaptiveProsodyPlanning = DeterministicAdaptiveProsodyPlanner(),
        turnTaking: TurnTakingTracking? = nil,
        engine: WakeCoordinatorEngine = WakeCoordinatorEngine(),
        detectorUnavailableReason: String? = nil, diagnostics: WakeDiagnosticsRecorder? = nil
    ) {
        self.capture = capture
        self.detector = detector
        self.permission = permission
        self.transcriber = transcriber
        self.runtimeSubmitter = runtimeSubmitter
        self.speechPermission = speechPermission
        self.synthesizer = synthesizer
        self.responsePresenter = responsePresenter
        self.diagnosticsContextCompiler = diagnosticsContextCompiler
        self.diagnosticsStrategyPlanner = diagnosticsStrategyPlanner
        self.diagnosticsProsodyPlanner = diagnosticsProsodyPlanner
        self.turnTaking = turnTaking
        self.engine = engine
        self.detectorUnavailableReason = detectorUnavailableReason
        self.diagnostics = diagnostics
    }

    public var state: AudioState { runtimeState.audioState }
    public var lastUnavailableReason: WakeUnavailableReason? { unavailableReason }

    /// Registers the callback invoked whenever a real wake event fires.
    /// This is the ONLY thing downstream code ever receives from wake
    /// detection — never raw audio, never anything resembling a
    /// TextRequest (P2-M3 instruction §29: "do not send a TextRequest to
    /// friday-daemon merely because 'Hey Friday' was detected" — P2-M4
    /// only submits a TextRequest-equivalent AFTER a real, validated
    /// spoken COMMAND is transcribed, never merely because wake fired).
    public func onWakeEvent(_ handler: @escaping @Sendable (WakeEvent) -> Void) {
        wakeEventHandler = handler
    }

    /// User/Companion-initiated: turn wake detection on. Handles the
    /// real macOS permission flow truthfully (§12) — never fakes a
    /// listening state if permission is unavailable.
    public func enable() async {
        let permissionStatus = permission.currentStatus()
        diagnostics?.recordPermissionStatus(String(describing: permissionStatus))

        // P2-M3D §10: a construction-time detector fallback must never
        // present as a working "Wake Listening" state — checked before
        // the permission flow so the truthful reason always wins over
        // whatever permission happens to be granted.
        if let detectorUnavailableReason {
            unavailableReason = .detectorFailedToStart(detectorUnavailableReason)
            (runtimeState, _) = engine.transition(state: runtimeState, event: .deviceUnavailable)
            return
        }

        switch permissionStatus {
        case .denied:
            unavailableReason = .microphonePermissionDenied
            (runtimeState, _) = engine.transition(state: runtimeState, event: .deviceUnavailable)
            return
        case .restricted:
            unavailableReason = .microphonePermissionRestricted
            (runtimeState, _) = engine.transition(state: runtimeState, event: .deviceUnavailable)
            return
        case .notDetermined:
            let result = await permission.requestAccess()
            diagnostics?.recordPermissionStatus(String(describing: result))
            guard result == .authorized else {
                unavailableReason = (result == .restricted) ? .microphonePermissionRestricted : .microphonePermissionDenied
                (runtimeState, _) = engine.transition(state: runtimeState, event: .deviceUnavailable)
                return
            }
        case .authorized:
            break
        }

        // P2-M4: resolve Speech-Recognition permission proactively, at
        // the same predictable moment as microphone permission, rather
        // than lazily inside a later wake trigger — surfaces
        // authorization behavior (including, on some launch
        // configurations, TCC's real crash-on-request failure mode
        // discovered this milestone; see `docs/E-traceability-matrix.md`'s
        // P2-M4 section) immediately when the user turns wake on, not
        // buried inside an unrelated later action. Never gates
        // `.wakeOnly` itself — only affects whether command capture can
        // later proceed (checked again, read-only, in
        // `beginCommandCapture()`).
        if let speechPermission {
            let sStatus = speechPermission.currentStatus()
            diagnostics?.recordSpeechRecognitionPermissionStatus(String(describing: sStatus))
            if sStatus == .notDetermined {
                let result = await speechPermission.requestAccess()
                diagnostics?.recordSpeechRecognitionPermissionStatus(String(describing: result))
            }
        }

        unavailableReason = nil
        let (next, action) = engine.transition(state: runtimeState, event: .enableRequested)
        runtimeState = next
        if action == .startCapture {
            await startCaptureAndDetector()
        }
    }

    public func disable() {
        let (next, action) = engine.transition(state: runtimeState, event: .disableRequested)
        runtimeState = next
        if action == .stopCapture {
            capture.stop()
            detector.stop()
        }
        // P2-M4 §16: disabling must cancel any in-flight command
        // capture/STT session — a harmless no-op if none was active.
        transcriber.cancelSession()
        // P2-M5 §23: disabling wake must also stop any speech in
        // progress — a harmless no-op if nothing was speaking. The
        // `.disableRequested` transition above already unconditionally
        // moves `audioState` to `.microphoneOff` regardless of what it
        // was, so the synthesizer's own `.interrupted` callback (if any)
        // arriving afterward finds the engine no longer `.speaking` and
        // is correctly ignored — no accidental resurrection of
        // `.wakeOnly`.
        synthesizer.stop()
        cancelAllCommandCaptureTimers()
    }

    /// A real device error (capture engine failed, input node gone) —
    /// called by the driver's own error paths, never fabricated.
    public func reportDeviceUnavailable(_ reason: WakeUnavailableReason) {
        unavailableReason = reason
        let (next, action) = engine.transition(state: runtimeState, event: .deviceUnavailable)
        runtimeState = next
        if action == .stopCapture {
            capture.stop()
            detector.stop()
        }
        transcriber.cancelSession()
        synthesizer.stop()
        cancelAllCommandCaptureTimers()
    }

    private func cancelAllCommandCaptureTimers() {
        listeningTimeoutTask?.cancel()
        listeningTimeoutTask = nil
        finalizeGraceTask?.cancel()
        finalizeGraceTask = nil
        isFinalizingCommand = false
        speechSafetyNetTask?.cancel()
        speechSafetyNetTask = nil
        followUpInactivityTask?.cancel()
        followUpInactivityTask = nil
    }

    public func reportDeviceRecovered() async {
        let (next, action) = engine.transition(state: runtimeState, event: .deviceRecovered)
        runtimeState = next
        unavailableReason = nil
        if action == .startCapture {
            await startCaptureAndDetector()
        }
    }

    private func startCaptureAndDetector() async {
        do {
            try detector.start()
        } catch {
            reportDeviceUnavailable(.detectorFailedToStart(String(describing: error)))
            return
        }
        do {
            try capture.start(onFrame: { [weak self] frame in
                // Real-time-adjacent callback: do the absolute minimum
                // here (§22) — hand the frame to the actor via a Task,
                // never call the (potentially heavier) detector/STT
                // engine inline on this thread.
                guard let self else { return }
                Task { await self.handleFrame(frame) }
            })
        } catch {
            detector.stop()
            let reason: WakeUnavailableReason
            if case AudioCaptureError.noInputDeviceAvailable = error {
                reason = .deviceError("no input device available")
            } else {
                reason = .deviceError(String(describing: error))
            }
            reportDeviceUnavailable(reason)
        }
    }

    /// P2-M4 §8: frame ownership is exclusively determined by the
    /// current `AudioState` — a frame goes to exactly one consumer
    /// (the wake detector while `.wakeOnly`, the transcriber while
    /// `.listening`), never both, and never neither by accident. This
    /// is the single place that decides that routing.
    private func handleFrame(_ frame: AudioFrame) async {
        if let turnTaking {
            let activityState = turnTaking.process(frame: frame, isFridaySpeaking: runtimeState.audioState == .speaking)
            let isNewInterruption = activityState == .interruption && lastSpeakerActivityStateForCounting != .interruption
            let isNewOverlap = activityState == .overlappingSpeech && lastSpeakerActivityStateForCounting != .overlappingSpeech
            lastSpeakerActivityStateForCounting = activityState
            diagnostics?.recordTurnTaking(state: String(describing: activityState), features: turnTaking.acousticFeatures(), isNewInterruption: isNewInterruption, isNewOverlap: isNewOverlap)
        }
        switch runtimeState.audioState {
        case .wakeOnly:
            handleWakeOnlyFrame(frame)
        case .listening, .awaitingFollowUp:
            // P2-PROD-BOOTSTRAP-R2.8 — a follow-up turn is captured
            // exactly like a fresh wake-triggered command (§10/§13):
            // same transcriber session, same VAD/trailing-silence rules.
            // Only `beginFollowUpCapture()` (vs. `beginCommandCapture()`)
            // and the extra inactivity timer it arms differ.
            guard !isFinalizingCommand else { return } // already wrapping up — no more audio needed
            transcriber.append(frame)
            updateVoiceActivity(frame)
        case .speaking:
            // P2-M5 §19/§20 barge-in: frames route to the SAME wake
            // detector used in `.wakeOnly` — not a new detector
            // instance, not an energy-based/full-duplex heuristic. The
            // detector is only started/stopped in `enable()`/`disable()`
            // (never per-state), so this requires no detector lifecycle
            // change, only this routing. This is a deliberate,
            // wake-word-only interruption contract, not general speech
            // barge-in — see `handleSpeakingFrame`'s own doc comment.
            handleSpeakingFrame(frame)
        default:
            return
        }
    }

    /// P2-M4D §9/§10 — the actual "trailing silence" mechanism: tracks
    /// whether speech has started (RMS above threshold) and, once it
    /// has, how long the signal has stayed below threshold since. This
    /// is what lets a command finish promptly after the user stops
    /// talking instead of always waiting the full `listeningTimeout`.
    private func updateVoiceActivity(_ frame: AudioFrame) {
        let rms = SimpleVoiceActivity.rms(of: frame.samples)
        let now = frame.capturedAt
        if rms >= engine.config.voiceActivityThreshold {
            if !vadSpeechStarted {
                diagnostics?.recordSpeechStartDetected()
                // P2-PROD-BOOTSTRAP-R2.8 §13 — the follow-up window's
                // "no speech yet" timer stops mattering the instant real
                // speech begins; from here on the existing trailing-
                // silence/absolute-timeout rules govern exactly like any
                // other command capture. A harmless no-op outside
                // `.awaitingFollowUp` (the task is simply nil there).
                followUpInactivityTask?.cancel()
                followUpInactivityTask = nil
            }
            vadSpeechStarted = true
            vadLastAboveThresholdAt = now
            return
        }
        guard vadSpeechStarted, let lastAbove = vadLastAboveThresholdAt else { return }
        if now.timeIntervalSince(lastAbove) >= engine.config.trailingSilenceTimeout {
            finalizeCommandCapture(reason: "trailing-silence")
        }
    }

    private func handleWakeOnlyFrame(_ frame: AudioFrame) {
        guard let wakeEvent = detector.process(frame, sessionID: "") else { return }

        let (next, action) = engine.transition(
            state: runtimeState,
            event: .rawWakeDetected(phraseID: wakeEvent.phraseID, confidence: wakeEvent.confidence, engine: detector.engineIdentifier, at: frame.capturedAt)
        )
        runtimeState = next
        if case .emitWakeEvent(let confirmedEvent) = action {
            // P2-PROD-BOOTSTRAP-R2.5 §1 — a fresh turn timeline starts
            // HERE, at a genuine wake from passive `.wakeOnly` (never at
            // a barge-in re-wake — see `handleSpeakingFrame`, which marks
            // `activeCommandCaptureStartedAgain` on THIS SAME, still-open
            // timeline instead, so the forensic comparison against this
            // turn's own `playbackCompleted` stays meaningful).
            diagnostics?.beginTurnTiming()
            diagnostics?.markTurnTiming(\.wakeDetected)
            diagnostics?.recordWakeEvent(eventID: confirmedEvent.eventID, at: confirmedEvent.detectedAt)
            wakeEventHandler?(confirmedEvent)
            beginCommandCapture()
        }
    }

    /// P2-M5 §19/§20/§40 — the entire barge-in contract: a genuine wake
    /// detection while `.speaking` immediately stops the active
    /// utterance and starts a brand-new interaction, identically to a
    /// wake from `.wakeOnly`. This is deliberately NOT general/energy-
    /// based full-duplex interruption — ordinary speech or noise while
    /// FRIDAY talks does nothing at all, because this environment has no
    /// real acoustic echo cancellation to safely tell FRIDAY's own voice
    /// apart from the owner's (§20: "do not invent echo cancellation").
    /// The only interruption path is the same KWS detector already
    /// measured (P2-M3C) to have a low false-accept rate, reused
    /// unchanged. Residual self-wake risk (the detector mishearing
    /// FRIDAY's own synthesized speech as "Hey Friday") is a disclosed,
    /// bounded risk — see `docs/W-adr-backlog.md`'s P2-M5 ADR-009 update
    /// — not eliminated by any new mechanism here, which is why §18 also
    /// asks response text to avoid the literal wake phrase (every
    /// template in `services/runtime/response/response.go` already does).
    private func handleSpeakingFrame(_ frame: AudioFrame) {
        guard let wakeEvent = detector.process(frame, sessionID: "") else { return }
        let (next, action) = engine.transition(
            state: runtimeState,
            event: .rawWakeDetected(phraseID: wakeEvent.phraseID, confidence: wakeEvent.confidence, engine: detector.engineIdentifier, at: frame.capturedAt)
        )
        guard case .emitWakeEvent(let confirmedEvent) = action else {
            // Debounced by cooldown, or the engine had already moved on
            // (e.g. `disable()` raced in) — leave the current utterance
            // alone in that case.
            runtimeState = next
            return
        }
        // Stop the audible response FIRST — a barge-in that started a
        // new listening session but left the old utterance still
        // playing would violate §19 ("current TTS immediately stops").
        synthesizer.stop()
        // P2-PROD-BOOTSTRAP-R2.5 §1 — marked HERE, not only in the async
        // `handleSpeechOutcome(.interrupted)` callback: `stop()` halts the
        // audio engine SYNCHRONOUSLY (the true moment playback audibly
        // ends), while the callback that ALSO reaches `playbackCompleted`
        // may only run on a later actor turn — marking it now, on THIS
        // SAME open timeline (never a fresh one — see `handleWakeOnlyFrame`),
        // is what makes `activeCaptureReopenedBeforePlaybackCompleted`
        // correctly read `false` for a genuine, correct barge-in.
        diagnostics?.markTurnTiming(\.playbackCompleted)
        speechSafetyNetTask?.cancel()
        speechSafetyNetTask = nil
        diagnostics?.recordBargeIn()
        runtimeState = next
        diagnostics?.recordWakeEvent(eventID: confirmedEvent.eventID, at: confirmedEvent.detectedAt)
        wakeEventHandler?(confirmedEvent)
        diagnostics?.markTurnTiming(\.activeCommandCaptureStartedAgain)
        beginCommandCapture()
    }

    /// P2-M4/P2-M4D §7/§10: starts the STT session for the command
    /// window that just opened. `listeningTimeout` is the absolute max
    /// duration backstop; the normal, faster path is
    /// `updateVoiceActivity`'s own trailing-silence detection calling
    /// `finalizeCommandCapture` once the user stops talking.
    private func beginCommandCapture() {
        startCaptureSession(isFollowUp: false)
    }

    /// P2-PROD-BOOTSTRAP-R2.8 §8/§10 — opens the bounded, wake-word-free
    /// follow-up window: identical STT session setup to
    /// `beginCommandCapture()`, plus the speech-aware "no speech yet"
    /// inactivity timer (`scheduleFollowUpInactivityTimeout`) that
    /// distinguishes this from a normal fresh-wake command capture.
    /// Called only from `handleSpeechOutcome` upon `.beginFollowUpCapture`
    /// — i.e. only once real audible playback has genuinely finished
    /// (never on provider/synthesis completion alone).
    private func beginFollowUpCapture() {
        startCaptureSession(isFollowUp: true)
    }

    private func startCaptureSession(isFollowUp: Bool) {
        // Read-only status check — never a fresh `requestAccess()` call
        // here (that only ever happens once, in `enable()`, at a
        // predictable moment) — a wake trigger must never itself risk
        // provoking a fresh, potentially crashing authorization request.
        if let speechPermission, speechPermission.currentStatus() != .authorized {
            let status = speechPermission.currentStatus()
            diagnostics?.recordTranscriptionFailure("speech recognition not authorized (\(status))")
            (runtimeState, _) = engine.transition(state: runtimeState, event: .commandTranscriptionFailed(reason: "speech recognition permission: \(status)"))
            diagnostics?.recordReturnedToWakeListening()
            return
        }
        vadSpeechStarted = false
        vadLastAboveThresholdAt = nil
        isFinalizingCommand = false
        turnTaking?.beginNewTurn()
        do {
            try transcriber.startSession(onResult: { [weak self] outcome in
                guard let self else { return }
                Task { await self.handleTranscriptionOutcome(outcome) }
            })
            diagnostics?.recordCommandCaptureStarted(engineIdentifier: transcriber.engineIdentifier)
            diagnostics?.markTurnTiming(\.commandCaptureStarted)
            scheduleListeningTimeout()
            if isFollowUp {
                scheduleFollowUpInactivityTimeout()
            }
        } catch {
            diagnostics?.recordTranscriptionFailure("startSession failed: \(error)")
            (runtimeState, _) = engine.transition(state: runtimeState, event: .commandTranscriptionFailed(reason: String(describing: error)))
            diagnostics?.recordReturnedToWakeListening()
        }
    }

    /// P2-PROD-BOOTSTRAP-R2.8 §8 — "no speech yet" backstop for
    /// `.awaitingFollowUp`: fires only if `updateVoiceActivity` never
    /// saw real speech (cancelling this same task) within
    /// `followUpInactivityWindow`. Reuses the existing, previously-dormant
    /// `.listeningTimedOut` event — its semantics ("give up on this
    /// capture attempt, no valid command materialized, return to
    /// wake-only") are exactly what a silent follow-up window needs, and
    /// its guard already accepts `.awaitingFollowUp` (`isActivelyCapturingSpeech`).
    private func scheduleFollowUpInactivityTimeout() {
        followUpInactivityTask?.cancel()
        let timeout = engine.config.followUpInactivityWindow
        followUpInactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.applyFollowUpInactivityExpired()
        }
    }

    private func applyFollowUpInactivityExpired() {
        guard case .awaitingFollowUp = runtimeState.audioState, !vadSpeechStarted else { return }
        transcriber.cancelSession()
        listeningTimeoutTask?.cancel()
        listeningTimeoutTask = nil
        diagnostics?.recordCommandCaptureStopReason("follow-up-inactivity")
        (runtimeState, _) = engine.transition(state: runtimeState, event: .listeningTimedOut)
        diagnostics?.recordReturnedToWakeListening()
    }

    /// P2-M4D root-cause fix — the command-capture window has decided
    /// the utterance is over (trailing silence, or the max-duration
    /// backstop below). Tells the STT engine via `finishSession()`
    /// (NOT `cancelSession()` — the whole P2-M4D bug was calling the
    /// hard-abandon path here, which both discarded any in-flight result
    /// AND told `SFSpeechAudioBufferRecognitionRequest` to stop via
    /// `cancel()` before `endAudio()` could matter, so no real
    /// transcript or failure was ever delivered) and starts a bounded
    /// safety net in case the engine still never calls back.
    private func finalizeCommandCapture(reason: String) {
        guard case .listening = runtimeState.audioState, !isFinalizingCommand else { return }
        isFinalizingCommand = true
        listeningTimeoutTask?.cancel()
        listeningTimeoutTask = nil
        diagnostics?.recordCommandCaptureStopReason(reason)
        diagnostics?.markTurnTiming(\.commandCaptureStopped)
        transcriber.finishSession()

        let grace = engine.config.finalizeGracePeriod
        finalizeGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.applyFinalizeGraceExpired()
        }
    }

    /// The bounded safety net itself — guarantees "no silent limbo"
    /// (P2-M4D §10): if the STT engine still hasn't delivered a result
    /// this long after being told the utterance ended, force a truthful
    /// failure and hard-cancel whatever is left of the session.
    private func applyFinalizeGraceExpired() {
        guard case .listening = runtimeState.audioState else { return }
        transcriber.cancelSession()
        diagnostics?.recordTranscriptionFailure("STT did not finalize within the grace period after finishSession()")
        (runtimeState, _) = engine.transition(state: runtimeState, event: .commandTranscriptionFailed(reason: "no result after finishSession()"))
        isFinalizingCommand = false
        diagnostics?.recordReturnedToWakeListening()
    }

    private func handleTranscriptionOutcome(_ outcome: SpeechTranscriptionOutcome) {
        // Whichever path finishes first — a real result or either
        // timer — the others must not also fire. This is the single
        // place every command-capture attempt terminates exactly once
        // (P2-M4D §6/§10): every branch below sets `isFinalizingCommand
        // = false` and, unless it hands off to `beginProcessing`
        // (which itself always eventually reaches `.wakeOnly` via
        // `commandProcessingFinished`), records the return to wake
        // listening here.
        listeningTimeoutTask?.cancel()
        listeningTimeoutTask = nil
        finalizeGraceTask?.cancel()
        finalizeGraceTask = nil
        followUpInactivityTask?.cancel()
        followUpInactivityTask = nil
        isFinalizingCommand = false

        switch outcome {
        case .finalized(let raw):
            switch TranscriptValidation.validate(raw) {
            case .success(let clean):
                diagnostics?.recordTranscript(clean)
                diagnostics?.markTurnTiming(\.sttFinalReceived)
                // P2-PROD-BOOTSTRAP-R2.8 §15 — checked only inside an
                // already-open follow-up window (saying "stop listening"
                // as literally the FIRST command after a fresh wake has
                // no session to close, so it is submitted as an ordinary
                // command like anything else). A small, bounded, disclosed
                // set of exact phrases — same "simple heuristic, not a
                // learned model, appropriate for this milestone's scope"
                // shape `voiceActivityThreshold` already discloses — not
                // a change to `DialogueAct`/the frozen brain.
                if case .awaitingFollowUp = runtimeState.audioState, FollowUpSessionExitPhrases.matches(clean) {
                    diagnostics?.recordCommandCaptureStopReason("explicit-session-end")
                    (runtimeState, _) = engine.transition(state: runtimeState, event: .followUpSessionExplicitlyEnded)
                    diagnostics?.recordReturnedToWakeListening()
                    return
                }
                let (next, action) = engine.transition(state: runtimeState, event: .commandUtteranceFinalized(transcript: clean))
                runtimeState = next
                if case .beginProcessing(let transcript) = action {
                    beginProcessing(transcript)
                } else {
                    // The engine ignored the event (state had already
                    // moved on, e.g. a very late result after
                    // disable()) — nothing to process, nothing to wait
                    // for.
                    diagnostics?.recordReturnedToWakeListening()
                }
            case .failure(let reason):
                diagnostics?.recordTranscriptionFailure("transcript rejected: \(reason)")
                (runtimeState, _) = engine.transition(state: runtimeState, event: .commandTranscriptionFailed(reason: "\(reason)"))
                diagnostics?.recordReturnedToWakeListening()
            }
        case .failed(let reason):
            diagnostics?.recordTranscriptionFailure(reason)
            (runtimeState, _) = engine.transition(state: runtimeState, event: .commandTranscriptionFailed(reason: reason))
            diagnostics?.recordReturnedToWakeListening()
        }
    }

    /// P2-M4 §3/§13: the ONLY place a transcript ever reaches the
    /// runtime — `runtimeSubmitter.submitText` is the exact same
    /// interface `RuntimeClient` exposes to typed input, called the
    /// exact same way. Runs off the actor (`Task.detached`) because
    /// `submitText` is a real, potentially slow, blocking network call
    /// (Unix-socket RPC with up to a 30s timeout) — running it directly
    /// on the actor would block frame delivery/disable()/every other
    /// actor operation for that entire duration (§16: `disable()` must
    /// remain responsive even during an in-flight command).
    private func beginProcessing(_ transcript: String) {
        diagnostics?.markTurnTiming(\.conversationStarted)
        let requestID = engine.makeID()
        // P2-M4R root-cause fix: correlation_id must genuinely identify
        // THIS interaction, never a constant/empty value — see
        // `RuntimeClient.submitText`'s own doc comment and
        // `docs/E-traceability-matrix.md`'s P2-M4R section for the full
        // mechanism a real owner voice interaction surfaced (an empty
        // correlation_id collapsed the server-side idempotency key for
        // any zero-argument capability like "system.get_status" into a
        // single constant, permanently misclassifying every interaction
        // after the first as a duplicate of it). This milestone's voice
        // flow is exactly one runtime request per interaction, so reusing
        // the same fresh, unique `requestID` as the correlation id is
        // correct — per `docs/JK-friday-ir-and-runtime-architecture.md`,
        // correlation_id identifies "one user-level request," which is
        // exactly what `requestID` already uniquely represents here.
        let correlationID = requestID
        diagnostics?.recordRuntimeRequestSubmitted(requestID: requestID)
        let submitter = runtimeSubmitter
        Task.detached { [weak self] in
            guard let self else { return }
            let outcome: CommandRuntimeOutcome
            do {
                let result = try submitter.submitText(transcript, requestID: requestID, correlationID: correlationID)
                outcome = .success(result)
            } catch {
                outcome = .failure(String(describing: error))
            }
            // P2-PROD-BOOTSTRAP-R2 §2.2 — the validated command transcript
            // is carried through to the presenter so a configured
            // conversational brain reasons about what the user actually
            // said. `submitText` above is the ONLY place it reaches the
            // runtime (§3/§13, unchanged); the presenter still has zero
            // execution authority.
            await self.commandProcessingFinished(outcome, transcript: transcript)
        }
    }

    /// P2-M5 §1/§3/§8: the runtime call has finished — instead of
    /// returning straight to `.wakeOnly` (the pre-P2-M5 behavior), this
    /// now computes a safe spoken response and transitions through
    /// `.speaking` first. `responsePresenter` never sees anything but
    /// this already-terminal `CommandRuntimeOutcome` — it has no way to
    /// invoke a capability or submit a new request (§3: zero execution
    /// authority).
    private func commandProcessingFinished(_ outcome: CommandRuntimeOutcome, transcript: String? = nil) {
        switch outcome {
        case .success(let result):
            diagnostics?.recordRuntimeOutcome(result.outcome)
        case .failure(let reason):
            diagnostics?.recordRuntimeOutcome("error: \(reason)")
        }
        let response = responsePresenter.response(for: outcome, transcript: transcript)
        diagnostics?.recordResponsePrepared(response.text, wasSuccess: response.wasSuccess)
        recordConversationalDiagnostics(outcome: outcome, response: response)
        let (next, action) = engine.transition(state: runtimeState, event: .responseReady(text: response.text))
        runtimeState = next
        guard case .beginSpeaking = action else {
            // The engine ignored it (state had already moved on, e.g.
            // `disable()` raced in while the runtime call was in
            // flight) — nothing to speak, nothing to wait for.
            diagnostics?.recordReturnedToWakeListening()
            return
        }
        // P2-M5V §10: `category` is a presentation-layer concern, not a
        // state-machine one — the pure engine's `.beginSpeaking(text:)`
        // action deliberately stays text-only; `response.category` is
        // passed straight through here instead of round-tripping
        // through the engine.
        beginSpeaking(response.text, category: response.category)
    }

    /// P2-M5V5 §23 — diagnostics only; see the doc comment on
    /// `diagnosticsContextCompiler` for why this can never disagree with
    /// what `responsePresenter` actually decided. Never affects what is
    /// spoken (`response.text`/`response.category`, already computed
    /// above, are what actually reaches `beginSpeaking`) — this only
    /// records ADDITIONAL detail about that same decision for the
    /// developer diagnostics view.
    private func recordConversationalDiagnostics(outcome: CommandRuntimeOutcome, response: SpokenResponse) {
        guard let diagnostics else { return }
        let context = diagnosticsContextCompiler.compile(outcome: outcome, recentResponseFamilies: [])
        let strategy = diagnosticsStrategyPlanner.strategy(for: context, persona: .friday)
        let finalProfile = diagnosticsProsodyPlanner.prosody(for: response.category, base: .friday)
        let resolvedVoice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: VoiceProfile.friday.voiceIdentifier, locale: VoiceProfile.friday.language,
            preferredGender: VoiceProfile.friday.preferredGenderFallback
        )
        let fallbackTier: String
        if let resolvedVoice, resolvedVoice.identifier == VoiceProfile.friday.voiceIdentifier {
            fallbackTier = "exact-identifier"
        } else if resolvedVoice != nil {
            fallbackTier = "fallback-tier"
        } else {
            fallbackTier = "system-default"
        }
        diagnostics.recordConversationalPersona(
            responseFamily: String(describing: context.responseFamily),
            purpose: String(describing: strategy.purpose),
            warmth: strategy.warmth, formality: strategy.formality, urgency: strategy.urgency,
            prosodyIntent: String(describing: response.category),
            finalRate: finalProfile.rate, finalPitch: finalProfile.pitchMultiplier, finalVolume: finalProfile.volume,
            resolvedVoiceIdentifier: resolvedVoice?.identifier, voiceFallbackTier: fallbackTier
        )
    }

    /// Hands `text` to the configured `SpeechSynthesizing` engine and
    /// starts the bounded safety net (§14/§33: "no stuck `.speaking`").
    private func beginSpeaking(_ text: String, category: SpeechResponseCategory) {
        diagnostics?.recordSpeechStarted(engineIdentifier: synthesizer.engineIdentifier)
        diagnostics?.markTurnTiming(\.speechSynthesisStarted)
        do {
            try synthesizer.speak(text, category: category, onFinished: { [weak self] outcome in
                guard let self else { return }
                Task { await self.handleSpeechOutcome(outcome) }
            })
            scheduleSpeechSafetyNet()
        } catch {
            diagnostics?.recordSpeechFailure(String(describing: error))
            let (next, _) = engine.transition(state: runtimeState, event: .speechFailed(reason: String(describing: error)))
            runtimeState = next
            diagnostics?.recordReturnedToWakeListening()
        }
    }

    /// The single place a spoken response terminates — natural
    /// completion, barge-in interruption, or failure all funnel through
    /// here exactly once per utterance (§14). Deliberately treats
    /// `.finished` and `.interrupted` identically for the ENGINE
    /// transition (both fire `.speechFinished`): if a barge-in already
    /// moved state on to `.listening` before this callback arrives (the
    /// normal case — `handleSpeakingFrame` calls `synthesizer.stop()`
    /// itself, which is what produces the `.interrupted` outcome this
    /// method then receives), the engine's own `.speaking`-only guard
    /// silently ignores the now-stale event — no double transition, no
    /// accidental regression back to `.wakeOnly` after a barge-in.
    private func handleSpeechOutcome(_ outcome: SpeechSynthesisOutcome) {
        // P2-PROD-BOOTSTRAP-R2.5 §1 — fires the instant ANY terminal
        // callback arrives, regardless of which of the three outcomes it
        // turns out to be.
        diagnostics?.markTurnTiming(\.speechTerminalCallback)
        speechSafetyNetTask?.cancel()
        speechSafetyNetTask = nil
        let event: WakeCoordinatorEvent
        switch outcome {
        case .finished:
            diagnostics?.recordSpeechCompleted(interrupted: false)
            // §3 — the actual contract this whole diagnostic exists to
            // verify: `.finished` is only EVER delivered, for every
            // production tier, after real audible playback has completed
            // (see `AVAudioEnginePCMPlayer`/each synthesizer's own
            // `onPlaybackComplete` gating) — so marking it here is
            // marking the true playback-completion moment, not merely
            // "a callback fired." First-write-wins means a barge-in's
            // earlier mark (at `synthesizer.stop()`) is never overwritten.
            diagnostics?.markTurnTiming(\.playbackCompleted)
            event = .speechFinished
        case .interrupted:
            diagnostics?.recordSpeechCompleted(interrupted: true)
            diagnostics?.markTurnTiming(\.playbackCompleted)
            event = .speechFinished
        case .failed(let reason):
            diagnostics?.recordSpeechFailure(reason)
            event = .speechFailed(reason: reason)
        }
        let before = runtimeState
        let (next, action) = engine.transition(state: runtimeState, event: event)
        runtimeState = next
        if before.audioState == .speaking && next.audioState == .wakeOnly {
            diagnostics?.recordReturnedToWakeListening()
        }
        // P2-PROD-BOOTSTRAP-R2.8 §7/§10 — ONLY reached once `.speechFinished`
        // has actually moved state to `.awaitingFollowUp` (the pure
        // engine's own `.speaking`-only guard already rejects a stale
        // event, e.g. after a barge-in already moved state to
        // `.listening`, or after `disable()`/Stop-Pause already moved it
        // to `.microphoneOff` — see `handleSpeechOutcome`'s existing doc
        // comment above). Ordering is exactly what §10 requires:
        // playback already completed (this callback IS that signal) ->
        // `speechTerminal` engine transition already applied above ->
        // follow-up capture starts now, never earlier.
        if case .beginFollowUpCapture = action {
            beginFollowUpCapture()
        }
    }

    private func scheduleSpeechSafetyNet() {
        speechSafetyNetTask?.cancel()
        let timeout = engine.config.maxSpeechDuration
        speechSafetyNetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.applySpeechSafetyNetExpired()
        }
    }

    /// The bounded safety net itself (§14/§33): if the synthesizer still
    /// hasn't delivered a result this long after `speak()` was called,
    /// force a truthful failure and hard-stop whatever is left.
    private func applySpeechSafetyNetExpired() {
        guard case .speaking = runtimeState.audioState else { return }
        synthesizer.stop()
        diagnostics?.recordSpeechFailure("TTS did not complete within the safety-net timeout")
        let (next, _) = engine.transition(state: runtimeState, event: .speechFailed(reason: "safety-net timeout"))
        runtimeState = next
        diagnostics?.recordReturnedToWakeListening()
    }

    /// P2-M4D: the absolute max-duration backstop. Unlike the pre-P2-M4D
    /// version, firing this does NOT itself return to `.wakeOnly` — it
    /// calls `finalizeCommandCapture`, which asks the STT engine to
    /// finish gracefully (`finishSession()`/`endAudio()`) and gives it
    /// `finalizeGracePeriod` more time to actually do so before the
    /// separate safety net (`applyFinalizeGraceExpired`) forces a
    /// truthful failure. This is what fixes the P2-M4D root cause: the
    /// old code called the hard-abandon `cancelSession()` here, which
    /// made it structurally impossible for Apple Speech to ever
    /// deliver a real result.
    private func scheduleListeningTimeout() {
        listeningTimeoutTask?.cancel()
        let timeout = engine.config.listeningTimeout
        listeningTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.finalizeCommandCapture(reason: "max-duration")
        }
    }
}
