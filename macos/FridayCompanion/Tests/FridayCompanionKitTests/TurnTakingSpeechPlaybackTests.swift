import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-PROD-BOOTSTRAP-R2.5 — the owner-observed defect ("FRIDAY returns to
/// listening in between answering") investigated and hardened: proves
/// `.speaking` frames never reach active command capture/STT except via
/// a genuine wake-phrase barge-in, proves the new per-turn
/// `TurnTimingTrace` diagnostics (§1) behave correctly for both a normal
/// turn and a barge-in turn, and locks in the required test matrix (§10).
@Suite struct TurnTakingSpeechPlaybackTests {
    private func makeCoordinator(
        config: WakeSessionConfig = WakeSessionConfig(listeningTimeout: 0.3, cooldown: 0.05)
    ) -> (WakeCoordinator, FakeAudioCapturing, FakeWakeWordDetector, FakeSpeechTranscriber, FakeCommandRuntimeSubmitting, FakeSpeechSynthesizer, WakeDiagnosticsRecorder) {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let submitter = FakeCommandRuntimeSubmitting()
        let synthesizer = FakeSpeechSynthesizer()
        let diagnostics = WakeDiagnosticsRecorder()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: submitter,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: config), diagnostics: diagnostics
        )
        return (coordinator, capture, detector, transcriber, submitter, synthesizer, diagnostics)
    }

    private func startSpeaking(_ coordinator: WakeCoordinator, capture: FakeAudioCapturing, transcriber: FakeSpeechTranscriber, submitter: FakeCommandRuntimeSubmitting, synthesizer: FakeSpeechSynthesizer) async {
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - §10.1 — provider/runtime finished, playback still active -> active capture stays CLOSED

    @Test func stillSpeaking_ordinaryFramesDuringPlayback_neverReopenActiveCapture() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, _) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)
        #expect(await coordinator.state == .speaking, "the runtime call + response are already back — only playback is still pending")

        let startSessionCallsBefore = transcriber.startCallCount
        // Ordinary noise/speech/silence — never a wake phrase — arriving
        // WHILE FRIDAY is still speaking must never reopen active capture.
        capture.deliver(AudioFixtures.noise())
        capture.deliver(AudioFixtures.ordinarySpeech())
        capture.deliver(AudioFixtures.silence())
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(await coordinator.state == .speaking, "must still be speaking — no premature return, no reopened capture")
        #expect(transcriber.startCallCount == startSessionCallsBefore, "§10.1/§10.7 — active STT must not start again while speech is ongoing and no wake phrase occurred")
    }

    // MARK: - §10.2 — playback completes -> return to wake-only

    @Test func playbackCompletes_returnsToWakeOnlyState_andTimingTraceRecordsIt() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, diagnostics) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)
        synthesizer.simulateFinished()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await coordinator.state == .wakeOnly)
        let trace = diagnostics.snapshot().lastTurnTiming
        #expect(trace.playbackCompleted != nil)
        #expect(trace.wakePassiveArmed != nil)
        #expect(trace.activeCommandCaptureStartedAgain == nil, "a natural completion never reopens a second capture")
        #expect(trace.activeCaptureReopenedBeforePlaybackCompleted == nil, "nothing to compare — no second capture happened this turn")
    }

    // MARK: - §10.7 — no wake phrase during playback -> no capture starts

    @Test func noWakePhraseDuringPlayback_noCaptureStarts_noBargeInRecorded() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, diagnostics) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)
        let bargeInsBefore = diagnostics.snapshot().bargeInCount

        for _ in 0..<5 { capture.deliver(AudioFixtures.ordinarySpeech()) }
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(await coordinator.state == .speaking)
        #expect(diagnostics.snapshot().bargeInCount == bargeInsBefore, "ordinary speech must never be treated as a wake-triggered interruption")
        #expect(synthesizer.stopCallCount == 0)
    }

    // MARK: - §10.6/§10.8 — wake phrase DURING playback -> real barge-in, diagnostics prove it is NOT the premature-rearm bug

    @Test func wakePhraseDuringPlayback_bargesIn_diagnosticsConfirmNoBugPresent() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, diagnostics) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)

        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 40_000_000)

        #expect(synthesizer.stopCallCount == 1, "the active utterance must be stopped immediately")
        if case .listening = await coordinator.state {} else { Issue.record("expected .listening, got \(await coordinator.state)") }
        #expect(diagnostics.snapshot().bargeInCount == 1)

        let trace = diagnostics.snapshot().lastTurnTiming
        #expect(trace.activeCommandCaptureStartedAgain != nil)
        #expect(trace.playbackCompleted != nil)
        // §1's central forensic question, proven FALSE for this genuine,
        // correct barge-in: the mark at `synthesizer.stop()` (synchronous,
        // the true audible-stop moment) precedes the new capture, exactly
        // as required — this is what "not a bug" looks like in the trace.
        #expect(trace.activeCaptureReopenedBeforePlaybackCompleted == false,
                "a real barge-in must never be misclassified as the premature-rearm bug")
    }

    // MARK: - §10.13/§10.14 — next turn works, after natural completion AND after barge-in

    @Test func nextNormalTurn_afterNaturalCompletion_succeeds() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, _) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)
        synthesizer.simulateFinished()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.state == .wakeOnly)

        synthesizer.autoFinish = true
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(synthesizer.speakCallCount == 2, "the second, independent turn must also reach speech")
    }

    @Test func nextNormalTurn_afterBargeIn_succeeds() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer, _) = makeCoordinator()
        await startSpeaking(coordinator, capture: capture, transcriber: transcriber, submitter: submitter, synthesizer: synthesizer)
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 40_000_000)
        if case .listening = await coordinator.state {} else { Issue.record("expected .listening, got \(await coordinator.state)") }

        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(synthesizer.speakCallCount == 2, "the post-barge-in turn must independently reach speech")
    }

    // MARK: - Full-timeline sanity: every required checkpoint is present for one ordinary turn

    @Test func fullTurn_everyRequiredCheckpointIsRecorded() async {
        // A short `trailingSilenceTimeout` here (mirroring
        // `CommandCaptureTests.trailingSilence_afterSpeechDetected_...`'s
        // own established pattern) so this test exercises the REAL
        // production path for `commandCaptureStopped`: VAD trailing-
        // silence detection calls `finalizeCommandCapture()` (which
        // marks it) BEFORE the STT engine's own callback ever delivers
        // a final transcript — exactly the order real production
        // always uses, never fabricated by calling `simulateResult`
        // without ever having "spoken."
        let (coordinator, capture, _, transcriber, submitter, synthesizer, diagnostics) = makeCoordinator(
            config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.05, trailingSilenceTimeout: 0.08, voiceActivityThreshold: 0.02)
        )
        synthesizer.autoFinish = true
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 30_000_000)

        let loud = AudioFrame(samples: [Int16](repeating: 12000, count: 800), sampleRate: 16000, channelCount: 1)
        capture.deliver(loud)
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<4 {
            capture.deliver(AudioFixtures.silence())
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(transcriber.finishCallCount == 1, "trailing silence must have already ended capture before the transcript arrives")

        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(await coordinator.state == .wakeOnly)
        let t = diagnostics.snapshot().lastTurnTiming
        #expect(t.wakeDetected != nil)
        #expect(t.commandCaptureStarted != nil)
        #expect(t.commandCaptureStopped != nil)
        #expect(t.sttFinalReceived != nil)
        #expect(t.conversationStarted != nil)
        #expect(t.speechSynthesisStarted != nil)
        #expect(t.speechTerminalCallback != nil)
        #expect(t.playbackCompleted != nil)
        #expect(t.wakePassiveArmed != nil)
        // Ordering (non-decreasing — a monotonic clock can tick twice in
        // the same millisecond for two synchronous marks).
        let ordered = [t.wakeDetected, t.commandCaptureStarted, t.commandCaptureStopped, t.sttFinalReceived, t.conversationStarted, t.speechSynthesisStarted, t.speechTerminalCallback, t.wakePassiveArmed].compactMap { $0 }
        #expect(ordered == ordered.sorted(), "every recorded checkpoint for one ordinary turn must appear in non-decreasing time order")
    }
}
