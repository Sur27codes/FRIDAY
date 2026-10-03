import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5-FINAL-CLOSURE-R1 §1.2/§1.4 — the Chatterbox tier's lazy
/// lifecycle. All synthetic: no real Python service, no real socket.
@Suite struct LazyLocalVoiceTierTests {
    @Test func socketAlreadyPresent_neverAttemptsToStartService_delegatesImmediately() throws {
        let inner = FakeSpeechSynthesizer(); inner.autoFinish = true
        var startCalled = false
        let tier = LazyLocalVoiceTier(
            underlying: inner, socketPath: "/tmp/fake.sock",
            socketExists: { _ in true },
            ensureServiceRunning: { startCalled = true; return true }
        )
        var outcome: SpeechSynthesisOutcome?
        try tier.speak("hi", category: .information, onFinished: { outcome = $0 })
        #expect(startCalled == false, "no service start when the socket is already there (no eager work)")
        #expect(inner.speakCallCount == 1)
        #expect(outcome == .finished)
    }

    @Test func socketAbsent_startsServiceOnce_thenDelegates() throws {
        let inner = FakeSpeechSynthesizer(); inner.autoFinish = true
        var startCount = 0
        var socketNowExists = false
        let tier = LazyLocalVoiceTier(
            underlying: inner, socketPath: "/tmp/fake.sock",
            socketExists: { _ in socketNowExists },
            ensureServiceRunning: { startCount += 1; socketNowExists = true; return true }
        )
        var outcome: SpeechSynthesisOutcome?
        try tier.speak("hi", category: .information, onFinished: { outcome = $0 })
        #expect(startCount == 1)
        #expect(inner.speakCallCount == 1)
        #expect(outcome == .finished)
    }

    @Test func serviceCannotStart_throwsNotAvailable_soCascadeCanAdvanceToSamantha() {
        let inner = FakeSpeechSynthesizer()
        let tier = LazyLocalVoiceTier(
            underlying: inner, socketPath: "/tmp/fake.sock",
            socketExists: { _ in false },
            ensureServiceRunning: { false } // venv/Python/script missing
        )
        #expect(throws: LazyLocalVoiceTier.NotAvailableError.self) {
            try tier.speak("hi", category: .information, onFinished: { _ in })
        }
        #expect(inner.speakCallCount == 0)
    }

    @Test func startAttemptedOnlyOncePerProcess_secondCallDoesNotRespawn() throws {
        let inner = FakeSpeechSynthesizer()
        var startCount = 0
        let tier = LazyLocalVoiceTier(
            underlying: inner, socketPath: "/tmp/fake.sock",
            socketExists: { _ in false },
            ensureServiceRunning: { startCount += 1; return false }
        )
        #expect(throws: LazyLocalVoiceTier.NotAvailableError.self) { try tier.speak("a", category: .information, onFinished: { _ in }) }
        #expect(throws: LazyLocalVoiceTier.NotAvailableError.self) { try tier.speak("b", category: .information, onFinished: { _ in }) }
        #expect(startCount == 1, "a machine that can't run the local service must not respawn on every fallback")
    }

    @Test func launcher_withNoResolvableServiceDirectory_returnsFalse_neverThrows() {
        // No override, and the (fake) env/bundle paths won't resolve in a
        // test — must return false cleanly so the cascade advances.
        let launcher = makeChatterboxServiceLauncher(
            socketPath: "/tmp/definitely-not-real-\(UUID().uuidString).sock",
            serviceDirectoryOverride: "/tmp/does-not-exist-\(UUID().uuidString)"
        )
        #expect(launcher() == false)
    }

    @Test func stop_forwardsToUnderlying() throws {
        let inner = FakeSpeechSynthesizer(); inner.autoFinish = false
        let tier = LazyLocalVoiceTier(
            underlying: inner, socketPath: "/tmp/fake.sock",
            socketExists: { _ in true }, ensureServiceRunning: { true }
        )
        try tier.speak("hi", category: .information, onFinished: { _ in })
        tier.stop()
        #expect(inner.stopCallCount == 1)
    }
}
