import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M4/P2-M5 pure engine transitions for the command-capture and
/// response phases (`.listening` → `.processing` → `.speaking` →
/// `.wakeOnly`), the same "no real time, no real audio" discipline
/// `WakeCoordinatorEngineTests` already established for the wake phase.
@Suite struct CommandCaptureEngineTests {

    @Test func commandUtteranceFinalized_fromListening_transitionsToProcessing_beginsProcessing() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "s1"))
        let (next, action) = engine.transition(state: state, event: .commandUtteranceFinalized(transcript: "check system status"))
        #expect(next.audioState == .processing)
        #expect(action == .beginProcessing(transcript: "check system status"))
    }

    @Test func commandUtteranceFinalized_ignoredOutsideListening() {
        let engine = WakeCoordinatorEngine()
        for offState: AudioState in [.microphoneOff, .unavailable, .wakeOnly, .processing, .speaking] {
            let state = WakeCoordinatorRuntimeState(audioState: offState)
            let (next, action) = engine.transition(state: state, event: .commandUtteranceFinalized(transcript: "x"))
            #expect(next.audioState == offState)
            #expect(action == .none)
        }
    }

    @Test func commandTranscriptionFailed_fromListening_returnsToWakeOnly_noProcessing() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "s1"))
        let (next, action) = engine.transition(state: state, event: .commandTranscriptionFailed(reason: "no speech"))
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func commandTranscriptionFailed_ignoredOutsideListening() {
        let engine = WakeCoordinatorEngine()
        for offState: AudioState in [.microphoneOff, .unavailable, .wakeOnly, .processing, .speaking] {
            let state = WakeCoordinatorRuntimeState(audioState: offState)
            let (next, _) = engine.transition(state: state, event: .commandTranscriptionFailed(reason: "x"))
            #expect(next.audioState == offState)
        }
    }

    // P2-M5: `.processing` no longer returns straight to `.wakeOnly` — it
    // first transitions through `.speaking` via `.responseReady`, then
    // `.speaking` returns to `.wakeOnly` via `.speechFinished`/
    // `.speechFailed`. See `ResponsePresentingTests`/`SpeechSynthesizingTests`
    // (response mapping / synthesizer lifecycle) and
    // `WakeCoordinatorSpeakingStateTests` (actor-level) for the P2-M5
    // coverage of this new phase.

    @Test func responseReady_fromProcessing_transitionsToSpeaking_beginsSpeaking() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .processing)
        let (next, action) = engine.transition(state: state, event: .responseReady(text: "System status retrieved successfully."))
        #expect(next.audioState == .speaking)
        #expect(action == .beginSpeaking(text: "System status retrieved successfully."))
    }

    @Test func responseReady_ignoredOutsideProcessing() {
        let engine = WakeCoordinatorEngine()
        for offState: AudioState in [.microphoneOff, .unavailable, .wakeOnly, .listening(sessionID: "s"), .speaking] {
            let state = WakeCoordinatorRuntimeState(audioState: offState)
            let (next, action) = engine.transition(state: state, event: .responseReady(text: "x"))
            #expect(next.audioState == offState)
            #expect(action == .none)
        }
    }

    @Test func speechFinished_fromSpeaking_returnsToWakeOnly() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .speaking)
        let (next, action) = engine.transition(state: state, event: .speechFinished)
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func speechFinished_ignoredOutsideSpeaking() {
        let engine = WakeCoordinatorEngine()
        for offState: AudioState in [.microphoneOff, .unavailable, .wakeOnly, .listening(sessionID: "s"), .processing] {
            let state = WakeCoordinatorRuntimeState(audioState: offState)
            let (next, _) = engine.transition(state: state, event: .speechFinished)
            #expect(next.audioState == offState)
        }
    }

    @Test func speechFailed_fromSpeaking_returnsToWakeOnly() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .speaking)
        let (next, action) = engine.transition(state: state, event: .speechFailed(reason: "engine error"))
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func listeningTimedOut_stillWorksAsCommandCaptureBackstop() {
        // Reused, unchanged transition (§7/§10: covers both "no speech
        // began" and "spoke too long without finishing").
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "s1"))
        let (next, action) = engine.transition(state: state, event: .listeningTimedOut)
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func fullCycle_wakeThenCommandThenProcessingThenBackToWakeOnly() {
        let engine = WakeCoordinatorEngine(now: { Date() }, makeID: { "s1" })
        var state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)

        (state, _) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: 0.9, engine: "fake", at: Date()))
        #expect(state.audioState == .listening(sessionID: "s1"))

        var action: WakeCoordinatorAction
        (state, action) = engine.transition(state: state, event: .commandUtteranceFinalized(transcript: "create a note saying buy milk"))
        #expect(state.audioState == .processing)
        #expect(action == .beginProcessing(transcript: "create a note saying buy milk"))

        (state, action) = engine.transition(state: state, event: .responseReady(text: "Created and verified note \"buy milk\"."))
        #expect(state.audioState == .speaking)
        #expect(action == .beginSpeaking(text: "Created and verified note \"buy milk\"."))

        (state, action) = engine.transition(state: state, event: .speechFinished)
        #expect(state.audioState == .wakeOnly)
        #expect(action == .none)
    }
}

/// P2-M4 actor-level orchestration — real `WakeCoordinator`, fake
/// capture/detector/permission/transcriber/runtime-submitter. Complements
/// `CommandCaptureEngineTests` (pure logic) by proving the real
/// frame-routing/cancellation/diagnostics wiring behaves correctly.
@Suite struct CommandCaptureCoordinatorTests {

    private func makeCoordinator(
        config: WakeSessionConfig = WakeSessionConfig(listeningTimeout: 0.3, cooldown: 0.1)
    ) -> (WakeCoordinator, FakeAudioCapturing, FakeWakeWordDetector, FakeSpeechTranscriber, FakeCommandRuntimeSubmitting) {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let submitter = FakeCommandRuntimeSubmitting()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: submitter,
            engine: WakeCoordinatorEngine(config: config)
        )
        return (coordinator, capture, detector, transcriber, submitter)
    }

    @Test func wakeDetected_startsTranscriberSession_entersListening() async {
        let (coordinator, capture, _, transcriber, _) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)

        let observedState = await coordinator.state
        #expect(observedState.sessionIDForTest != nil, "expected .listening, got \(observedState)")
        #expect(transcriber.startCallCount == 1)
    }

    @Test func realisticVoiceCommand_transcriptReachesRuntimeSubmitter_thenReturnsToWakeOnly() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.state != .wakeOnly, "must have entered a command-capture-adjacent state after wake")

        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(submitter.submittedTexts == ["check system status"])
        #expect(await coordinator.state == .wakeOnly, "must return to wakeOnly once the runtime call completes")
    }

    @Test func exactTypedEquivalence_spokenTranscriptSubmittedVerbatim_noRewriting() async {
        // P2-M4 §13: "Typed: 'check system status' / Spoken transcript:
        // 'check system status' — both must converge on the same
        // daemon/runtime behavior" — proven here at the point where the
        // Companion hands text to the runtime interface: byte-for-byte
        // identical to what a typed-input caller would pass.
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(submitter.submittedTexts.first == "check system status")
    }

    @Test func emptyTranscript_neverReachesRuntime_returnsToWakeOnly() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("   "))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(submitter.submittedTexts.isEmpty, "an empty/whitespace transcript must never be submitted (§11)")
        #expect(await coordinator.state == .wakeOnly)
    }

    @Test func overLengthTranscript_rejected_neverReachesRuntime() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized(String(repeating: "a", count: TranscriptValidation.maxLength + 1)))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(submitter.submittedTexts.isEmpty, "§12: enforce maximum transcript length")
        #expect(await coordinator.state == .wakeOnly)
    }

    @Test func sttEngineFailure_returnsToWakeOnly_doesNotFabricateACommand() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.failed("no speech detected"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(submitter.submittedTexts.isEmpty)
        #expect(await coordinator.state == .wakeOnly)
    }

    @Test func runtimeSubmissionFailure_stillReturnsToWakeOnly_truthfully() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        submitter.errorToThrow = RuntimeClientError.transport("daemon unreachable")
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(submitter.submittedTexts == ["check system status"], "the attempt must still have been made")
        #expect(await coordinator.state == .wakeOnly, "runtime failure must still recover to a truthful state, not get stuck in .processing")
    }

    @Test func framesDuringListening_goToTranscriber_notWakeDetector() async {
        let (coordinator, capture, detector, transcriber, _) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let detectorCountAtListening = detector.processedFrameCount

        capture.deliver(AudioFixtures.ordinarySpeech())
        capture.deliver(AudioFixtures.ordinarySpeech())
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(detector.processedFrameCount == detectorCountAtListening, "§8: the wake detector must not see frames once in command-listening")
        #expect(transcriber.appendedFrameCount == 2)
    }

    /// P2-M4D §7 — the owner's log showed "Wake events: 4, Command
    /// captures started: 4" while transcriptions/returns were 0,
    /// prompting the question of whether a second wake could start a
    /// second, overlapping interaction. It structurally cannot (frame
    /// routing is an exhaustive switch on `AudioState`, so a wake-marker
    /// frame arriving during `.listening`/`.processing` is routed to the
    /// transcriber/nowhere, never re-examined by the wake detector) —
    /// this test proves that directly rather than relying on the routing
    /// test above alone, by delivering a REAL wake-triggering frame
    /// while already `.listening` and confirming no second event fires
    /// and the detector is never even asked.
    @Test func secondWakeMarkerFrame_whileAlreadyListening_isIgnored_atMostOneActiveInteraction() async {
        let (coordinator, capture, detector, transcriber, _) = makeCoordinator()
        var wakeEventCount = 0
        await coordinator.onWakeEvent { _ in wakeEventCount += 1 }
        await coordinator.enable()

        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(wakeEventCount == 1)
        let detectorCountAtListening = detector.processedFrameCount

        // A second, otherwise-real wake-triggering frame arrives while
        // still `.listening` — must be silently ignored by the wake path.
        capture.deliver(AudioFixtures.positiveWakePhrase())
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(wakeEventCount == 1, "at most one active command interaction — a second wake must not fire while the first is unresolved")
        #expect(detector.processedFrameCount == detectorCountAtListening, "the wake detector must not even see these frames while listening")
        #expect(transcriber.appendedFrameCount == 2, "the marker frames were correctly routed to the transcriber instead")
    }

    /// P2-M4D §6/§10 — every command-capture attempt must terminate
    /// exactly once. Simulates a real-world race (the STT engine's
    /// callback firing twice — Apple's own documentation does not
    /// guarantee against a stray extra callback in edge cases) and
    /// confirms only the FIRST outcome is ever acted on.
    @Test func transcriberCallbackFiringTwice_onlyFirstOutcomeActedOn_exactlyOnceTermination() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)

        transcriber.simulateResult(.finalized("check system status"))
        // A short gap before the stray second callback (P2-M5 hardening:
        // observed flaky without this under heavy overall test-suite
        // load — `simulateResult`, unlike the real
        // `AppleSpeechTranscriber.deliverOnce`, has no delivery guard of
        // its own, so firing both calls back-to-back with zero gap makes
        // the outcome depend on unstructured-`Task` scheduling order
        // rather than on the actual guarantee under test: once the first
        // outcome has moved `audioState` off `.listening`, the pure
        // engine's own state guard rejects a second `commandUtteranceFinalized`
        // regardless of which text it carries. A real misbehaving engine
        // would also never deliver a genuine duplicate this close to the
        // first callback, so this gap costs nothing in realism.
        try? await Task.sleep(nanoseconds: 30_000_000)
        transcriber.simulateResult(.finalized("create a note called x with y")) // stray second callback
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(submitter.submittedTexts == ["check system status"], "only the first outcome may ever reach the runtime")
    }

    @Test func disableDuringCommandCapture_cancelsTranscriberSession_noZombieTask() async {
        let (coordinator, capture, _, transcriber, submitter) = makeCoordinator()
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.isSessionActive)

        await coordinator.disable()
        #expect(transcriber.cancelCallCount == 1)
        #expect(await coordinator.state == .microphoneOff)

        // A late result arriving after disable() must not resurrect
        // anything or reach the runtime (§16: no zombie task).
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(submitter.submittedTexts.isEmpty)
    }

    @Test func backstopTimeout_callsFinishSessionFirst_thenGraceExpires_cancelsSession_returnsToWakeOnly() async {
        // P2-M4D root-cause regression: the backstop must call
        // `finishSession()` (graceful — gives the real engine a chance
        // to deliver an actual result), NEVER jump straight to
        // `cancelSession()` (the exact bug that made real Apple Speech
        // finalization impossible). Only if NOTHING arrives within the
        // separate grace period does `cancelSession()` finally fire, as
        // the bounded safety net.
        let (coordinator, capture, _, transcriber, _) = makeCoordinator(
            config: WakeSessionConfig(listeningTimeout: 0.15, cooldown: 0.05, finalizeGracePeriod: 0.15)
        )
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())

        // Shortly after the backstop (0.15s) but before the grace period
        // (another 0.15s) elapses: finishSession called, cancelSession NOT yet.
        try? await Task.sleep(nanoseconds: 220_000_000)
        #expect(transcriber.finishCallCount == 1, "the backstop must ask the STT engine to finish gracefully")
        #expect(transcriber.cancelCallCount == 0, "must not hard-cancel before giving the engine a chance to respond")

        // After the grace period also elapses with no response: the
        // safety net forces a truthful failure and finally cancels.
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(await coordinator.state == .wakeOnly, "the safety net must still bound command capture")
        #expect(transcriber.cancelCallCount == 1, "the safety net must clean up a session that never finalized")
    }

    @Test func trailingSilence_afterSpeechDetected_finalizesEarly_beforeMaxDurationBackstop() async {
        // The genuine "trailing silence" mechanism (P2-M4D §9/§10): once
        // speech has been heard, a period of low-energy audio should end
        // capture well before the (much longer) max-duration backstop.
        let (coordinator, capture, _, transcriber, _) = makeCoordinator(
            config: WakeSessionConfig(listeningTimeout: 10, cooldown: 0.05, trailingSilenceTimeout: 0.1, voiceActivityThreshold: 0.02, finalizeGracePeriod: 0.2)
        )
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Loud "speech" frame, then silence frames spanning more than
        // `trailingSilenceTimeout`.
        let loud = AudioFrame(samples: [Int16](repeating: 12000, count: 800), sampleRate: 16000, channelCount: 1)
        capture.deliver(loud)
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<5 {
            capture.deliver(AudioFixtures.silence())
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        #expect(transcriber.finishCallCount == 1, "trailing silence after speech must end capture without waiting for the 10s max-duration backstop")
    }

    @Test func nullSpeechTranscriber_preservesExactPreP2M4Behavior() async {
        // The default construction path (no transcriber/submitter
        // supplied) — every P2-M3/P2-M3C/P2-M3D test uses exactly this,
        // and must be completely unaffected by P2-M4's additions (beyond
        // the new grace-period wait before the final safety net fires,
        // since NullSpeechTranscriber's `finishSession()` never calls
        // back on its own — disclosed, expected, and still bounded).
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 0.2, cooldown: 0.05, finalizeGracePeriod: 0.15))
        )
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let observedState = await coordinator.state
        #expect(observedState.sessionIDForTest != nil, "expected .listening, got \(observedState)")

        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(await coordinator.state == .wakeOnly, "with no real STT wired up, the session must still safely time out exactly as it did before P2-M4")
    }
}

private extension AudioState {
    /// Test-only convenience so assertions can compare `.listening`
    /// without needing to know the coordinator's internally-generated
    /// session ID in advance.
    var sessionIDForTest: String? {
        if case .listening(let id) = self { return id }
        return nil
    }
}
