import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5 §33/§34/§35 — actor-level tests for the new `.speaking` phase:
/// the full processing -> speaking -> wakeOnly state machine, barge-in,
/// and the structural self-feedback guarantee. Complements
/// `CommandCaptureCoordinatorTests` (P2-M4's wake -> listen -> process
/// phase) by covering everything P2-M5 added downstream of a runtime
/// result.
@Suite struct WakeCoordinatorSpeakingStateTests {

    private func makeCoordinator(
        config: WakeSessionConfig = WakeSessionConfig(listeningTimeout: 0.3, cooldown: 0.05)
    ) -> (WakeCoordinator, FakeAudioCapturing, FakeWakeWordDetector, FakeSpeechTranscriber, FakeCommandRuntimeSubmitting, FakeSpeechSynthesizer) {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let submitter = FakeCommandRuntimeSubmitting()
        let synthesizer = FakeSpeechSynthesizer()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: submitter,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: config)
        )
        return (coordinator, capture, detector, transcriber, submitter, synthesizer)
    }

    // MARK: - §33: processing -> speaking -> wakeOnly (success)

    @Test func successfulCommand_entersSpeaking_thenReturnsToWakeOnly_onceSpeechFinishes() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await coordinator.state == .speaking, "a completed runtime call must enter .speaking, not jump straight back to .wakeOnly")
        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(synthesizer.spokenTexts[0]), "must speak the runtime's own safe response text — got '\(synthesizer.spokenTexts[0])'")

        synthesizer.simulateFinished()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.state == .wakeOnly, "must return to wakeOnly once speech actually finishes")
    }

    // MARK: - §33: processing failure -> safe response -> speaking -> wakeOnly

    @Test func failedRuntimeCall_stillSpeaksATruthfulResponse_thenReturnsToWakeOnly() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        submitter.errorToThrow = RuntimeClientError.transport("daemon unreachable")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(synthesizer.spokenTexts.count == 1)
        #expect(!synthesizer.spokenTexts[0].isEmpty)
        for forbidden in ["Done", "Completed", "Success"] {
            #expect(!synthesizer.spokenTexts[0].contains(forbidden), "a failed runtime result must NEVER map to success speech (§11)")
        }
        #expect(await coordinator.state == .wakeOnly, "with FakeSpeechSynthesizer's default auto-finish, speaking completes immediately")
    }

    @Test func unsupportedIntentOutcome_speaksTruthfulUnsupportedResponse_notFakeSuccess() async {
        // §12: the real owner finding this milestone must not regress —
        // a well-formed UNSUPPORTED_INTENT result must never become
        // "Done."/"Completed."
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("hey friday"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.unsupportedIntentVariants.contains(synthesizer.spokenTexts[0]))
        #expect(await coordinator.state == .wakeOnly)
    }

    // MARK: - §23: Stop/disable while speaking

    @Test func disableWhileSpeaking_stopsSynthesizer_returnsToMicrophoneOff() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await coordinator.state == .speaking)

        await coordinator.disable()
        #expect(await coordinator.state == .microphoneOff, "disable while speaking must not leave FRIDAY stuck reporting .speaking (§23)")
        #expect(synthesizer.stopCallCount >= 1, "disable must stop active speech, never leave it playing after FRIDAY is reported stopped")

        // A late synthesizer callback after disable() must not resurrect
        // .wakeOnly (mirrors the existing STT "no zombie task" guarantee).
        synthesizer.simulateFinished()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await coordinator.state == .microphoneOff)
    }

    // MARK: - §19/§35: barge-in

    @Test func bargeIn_duringSpeaking_stopsSynthesizer_startsFreshListeningSession() async {
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        var wakeEvents: [WakeEvent] = []
        await coordinator.onWakeEvent { wakeEvents.append($0) }
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await coordinator.state == .speaking)
        #expect(wakeEvents.count == 1)

        // Real barge-in: a genuine wake-triggering frame arrives while
        // FRIDAY is still speaking (`synthesizer.autoFinish = false`, so
        // the first utterance is deliberately still "in flight").
        capture.deliver(AudioFixtures.positiveWakePhrase(at: Date().addingTimeInterval(5)))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(wakeEvents.count == 2, "a genuine wake word during active speech must fire a second, real WakeEvent")
        #expect(synthesizer.stopCallCount >= 1, "the active utterance must be stopped, not left playing under the new session")
        if case .listening = await coordinator.state {} else {
            Issue.record("expected .listening (fresh command capture) immediately after barge-in, got \(await coordinator.state)")
        }
    }

    @Test func bargeIn_thenSecondCommand_producesFreshTranscriptAndRequestID_noStaleDataFromFirstInteraction() async {
        // §22: prove the barged-in-on interaction and the new one are
        // fully independent — different requestIDs, no leftover text
        // from interaction A reaching the runtime for interaction B.
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await coordinator.state == .speaking)

        capture.deliver(AudioFixtures.positiveWakePhrase(at: Date().addingTimeInterval(5)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case .listening = await coordinator.state else {
            Issue.record("expected fresh .listening after barge-in")
            return
        }

        transcriber.simulateResult(.finalized("create a note called voice test with p2 m5 passed"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(submitter.submittedTexts == ["check system status", "create a note called voice test with p2 m5 passed"], "interaction B's transcript must be exactly what was spoken after barge-in — nothing carried over from A")
        #expect(Set(submitter.submittedRequestIDs).count == 2, "each interaction must get its own unique request/correlation identity — the P2-M4R fix must still hold across a barge-in")
    }

    @Test func speechFinishesAtSameMomentAsBargeIn_remainsDeterministic_noDoubleTransition() async {
        // Race per §35: the synthesizer's own natural-completion callback
        // and a barge-in wake detection both resolve "at the same time."
        // Whichever the actor processes first must leave the system in
        // exactly one consistent, valid state — never a crash, never two
        // command-capture sessions, never a stuck state.
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        synthesizer.autoFinish = false
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        var wakeEvents: [WakeEvent] = []
        await coordinator.onWakeEvent { wakeEvents.append($0) }
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await coordinator.state == .speaking)

        // Fire both "at once" — the barge-in frame and the natural
        // finish — without waiting between them. Whichever the actor's
        // serial executor happens to process first, the wake-marker
        // frame is always handled by EITHER `handleSpeakingFrame` (if
        // still `.speaking`) OR the ordinary `handleWakeOnlyFrame` path
        // (if the natural finish already landed `.wakeOnly` first) — a
        // real wake event fires either way, so the outcome is actually
        // deterministic despite the race: exactly one fresh listening
        // session, never a stuck/ambiguous state.
        capture.deliver(AudioFixtures.positiveWakePhrase(at: Date().addingTimeInterval(5)))
        synthesizer.simulateFinished()
        try? await Task.sleep(nanoseconds: 100_000_000)

        guard case .listening = await coordinator.state else {
            Issue.record("expected a fresh .listening session regardless of race ordering, got \(await coordinator.state)")
            return
        }
        #expect(wakeEvents.count == 2, "the original wake plus exactly one wake from the race, never zero, never more")
    }

    // MARK: - §34: structural self-feedback guarantee

    @Test func speechOutputHasNoPathIntoTranscriberOrRuntimeSubmitter() async {
        // Structural proof, behaviorally reinforced: speaking a response
        // must never itself append frames to the transcriber or submit
        // a new runtime request — `FakeSpeechSynthesizer`/
        // `DeterministicResponsePresenter` have no reference to either
        // (confirmed statically by `WakeSecurityTests.sec010`); this test
        // additionally proves it BEHAVIORALLY across a real speaking
        // phase: no new transcriber session starts and no new runtime
        // submission happens purely as a result of entering/leaving
        // `.speaking`.
        let (coordinator, capture, _, transcriber, submitter, synthesizer) = makeCoordinator()
        submitter.resultToReturn = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "SUCCESS", text: "System status retrieved successfully.")

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 50_000_000)
        transcriber.simulateResult(.finalized("check system status"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(submitter.submittedTexts.count == 1, "speaking the response must not itself trigger a second runtime submission")
        #expect(transcriber.startCallCount == 1, "speaking the response must not itself start a new STT session")
        #expect(synthesizer.spokenTexts.count == 1)
    }
}
