import Testing
@testable import FridayCompanionKit
import Foundation

/// Actor-level `WakeCoordinator` tests — real async driver, fake
/// capture/detector/permission. Complements `WakeCoordinatorEngineTests`
/// (pure logic) by proving the actual frame-delivery/permission/timeout
/// wiring behaves correctly, end to end through the actor.
@Suite struct WakeCoordinatorTests {

    private func makeCoordinator(
        permissionStatus: MicrophonePermissionStatus = .authorized,
        config: WakeSessionConfig = WakeSessionConfig(listeningTimeout: 0.3, cooldown: 0.1)
    ) -> (WakeCoordinator, FakeAudioCapturing, FakeWakeWordDetector, FakeMicrophonePermission) {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: permissionStatus)
        let coordinator = WakeCoordinator(capture: capture, detector: detector, permission: permission, engine: WakeCoordinatorEngine(config: config))
        return (coordinator, capture, detector, permission)
    }

    @Test func enable_withAuthorizedPermission_startsCapture_reachesWakeOnly() async {
        let (coordinator, capture, detector, _) = makeCoordinator()
        await coordinator.enable()
        #expect(await coordinator.state == .wakeOnly)
        #expect(capture.startCallCount == 1)
        #expect(detector.startCallCount == 1)
    }

    @Test func enable_withDeniedPermission_neverStartsCapture_reportsTruthfulUnavailableReason() async {
        let (coordinator, capture, _, _) = makeCoordinator(permissionStatus: .denied)
        await coordinator.enable()
        #expect(await coordinator.state == .unavailable)
        #expect(await coordinator.lastUnavailableReason == .microphonePermissionDenied)
        #expect(capture.startCallCount == 0, "must never start capture without real permission")
    }

    @Test func enable_withRestrictedPermission_reportsRestricted_notGenericDenied() async {
        let (coordinator, _, _, _) = makeCoordinator(permissionStatus: .restricted)
        await coordinator.enable()
        #expect(await coordinator.lastUnavailableReason == .microphonePermissionRestricted)
    }

    @Test func enable_withNotDetermined_requestsAccessExactlyOnce() async {
        let (coordinator, capture, _, permission) = makeCoordinator(permissionStatus: .notDetermined)
        await coordinator.enable()
        #expect(permission.requestAccessCallCount == 1)
        #expect(await coordinator.state == .wakeOnly) // fake permission grants on request
        #expect(capture.startCallCount == 1)
    }

    // MARK: - Real end-to-end wake flow through the actor

    @Test func positiveWakeFixture_producesExactlyOneWakeEvent() async {
        let (coordinator, capture, _, _) = makeCoordinator()
        await coordinator.enable()

        final class Box: @unchecked Sendable { var events: [WakeEvent] = [] }
        let box = Box()
        await coordinator.onWakeEvent { event in box.events.append(event) }

        capture.deliver(AudioFixtures.positiveWakePhrase())
        // Frame handling hops through a Task onto the actor — give it a
        // moment to complete before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(box.events.count == 1)
        #expect(box.events.first?.phraseID == "hey_friday")
        if case .listening = await coordinator.state {} else {
            Issue.record("expected .listening after a real wake event, got \(await coordinator.state)")
        }
    }

    @Test func silenceAndOrdinarySpeechAndNoise_neverProduceAWakeEvent() async {
        let (coordinator, capture, _, _) = makeCoordinator()
        await coordinator.enable()
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        await coordinator.onWakeEvent { _ in box.count += 1 }

        capture.deliver(AudioFixtures.silence())
        capture.deliver(AudioFixtures.ordinarySpeech())
        capture.deliver(AudioFixtures.noise())
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(box.count == 0)
        #expect(await coordinator.state == .wakeOnly, "must remain in wake-only, never fabricate a listening session")
    }

    @Test func listeningSession_timesOutBackToWakeOnly() async {
        // P2-M4D: with no real transcriber wired up (this suite's default
        // `WakeWordDetecting`-only fixtures), the max-duration backstop
        // still calls `finishSession()` gracefully first (a no-op on the
        // default `NullSpeechTranscriber`), then the separate,
        // short-here grace period's safety net returns to `.wakeOnly` —
        // still bounded, just via one additional configurable delay.
        let (coordinator, capture, _, _) = makeCoordinator(config: WakeSessionConfig(listeningTimeout: 0.2, cooldown: 0.05, finalizeGracePeriod: 0.15))
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard case .listening = await coordinator.state else {
            Issue.record("expected .listening immediately after wake")
            return
        }

        try? await Task.sleep(nanoseconds: 600_000_000) // past the 0.2s timeout + 0.15s grace period
        #expect(await coordinator.state == .wakeOnly, "a listening session with no downstream pipeline must safely time out")
    }

    @Test func disable_stopsCaptureAndDetector_wakeNoLongerFires() async {
        let (coordinator, capture, detector, _) = makeCoordinator()
        await coordinator.enable()
        await coordinator.disable()
        #expect(await coordinator.state == .microphoneOff)
        #expect(capture.stopCallCount == 1)
        #expect(detector.stopCallCount == 1)
        #expect(!capture.isCapturing)
    }

    @Test func deviceUnavailable_thenRecovered_resumesWakeOnly() async {
        let (coordinator, capture, _, _) = makeCoordinator()
        await coordinator.enable()
        await coordinator.reportDeviceUnavailable(.deviceError("simulated disconnect"))
        #expect(await coordinator.state == .unavailable)
        #expect(capture.stopCallCount >= 1)

        await coordinator.reportDeviceRecovered()
        #expect(await coordinator.state == .wakeOnly)
        #expect(capture.startCallCount == 2, "recovery should re-start capture")
    }

    @Test func captureStartFailure_reportsDeviceError_neverCrashes() async {
        let capture = FakeAudioCapturing()
        capture.shouldFailToStart = .noInputDeviceAvailable
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let coordinator = WakeCoordinator(capture: capture, detector: detector, permission: permission)

        await coordinator.enable()
        #expect(await coordinator.state == .unavailable)
        if case .deviceError = await coordinator.lastUnavailableReason {} else {
            Issue.record("expected a .deviceError reason, got \(await coordinator.lastUnavailableReason as Any)")
        }
    }

    // MARK: - P2-M3D §10: a construction-time detector fallback must never look operational

    @Test func detectorUnavailableReason_setAtConstruction_neverReachesWakeOnly_evenWithAuthorizedPermission() async {
        // Mirrors AppDelegate's real fallback: the real detector failed
        // to construct, `NullWakeWordDetector` (which trivially succeeds
        // at `start()`) is passed in as the harmless stand-in, but
        // `detectorUnavailableReason` is also set — this must make
        // `enable()` refuse `.wakeOnly` even though permission is
        // authorized and the fake/null detector would happily "start."
        let capture = FakeAudioCapturing()
        let detector = NullWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            detectorUnavailableReason: "sherpa-onnx model resource missing (simulated)"
        )

        await coordinator.enable()

        #expect(await coordinator.state == .unavailable, "must never present as Wake Listening when the real detector could not be constructed")
        #expect(capture.startCallCount == 0, "must not even start capture for a detector that can never fire")
        guard case .detectorFailedToStart(let detail) = await coordinator.lastUnavailableReason else {
            Issue.record("expected .detectorFailedToStart, got \(await coordinator.lastUnavailableReason as Any)")
            return
        }
        #expect(detail.contains("simulated"))
    }

    @Test func detectorUnavailableReason_nil_behavesExactlyAsBefore() async {
        // Regression guard on the new parameter's default: existing
        // callers that never pass `detectorUnavailableReason` (every
        // test above, and any real, successfully-constructed detector)
        // must be completely unaffected.
        let (coordinator, capture, detector, _) = makeCoordinator()
        await coordinator.enable()
        #expect(await coordinator.state == .wakeOnly)
        #expect(capture.startCallCount == 1)
        #expect(detector.startCallCount == 1)
    }
}
