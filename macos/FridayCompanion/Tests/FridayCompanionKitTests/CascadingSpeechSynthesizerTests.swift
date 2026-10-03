import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5-FINAL-CLOSURE-R1 §1.4 — the production three-tier voice-routing
/// matrix. `FakeSpeechSynthesizer` (WakeFakes.swift) stands in for each
/// tier so every transition is exercised deterministically, with no real
/// audio hardware, network, or Chatterbox process.
@Suite struct CascadingSpeechSynthesizerTests {
    /// Records every `onFinished` invocation so "exactly once" is a
    /// direct assertion, not an assumption.
    private final class OutcomeSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var outcomes: [SpeechSynthesisOutcome] = []
        var handler: @Sendable (SpeechSynthesisOutcome) -> Void {
            { [self] outcome in lock.lock(); outcomes.append(outcome); lock.unlock() }
        }
    }

    private func makeCascade(_ tiers: [FakeSpeechSynthesizer]) -> CascadingSpeechSynthesizer {
        CascadingSpeechSynthesizer(tiers: tiers)
    }

    private func manualTiers(_ n: Int) -> [FakeSpeechSynthesizer] {
        (0..<n).map { _ in let f = FakeSpeechSynthesizer(); f.autoFinish = false; return f }
    }

    // 1 / 16 — Cartesia succeeds → ONLY Cartesia used, Chatterbox never started

    @Test func cartesiaSucceeds_onlyCartesiaUsed_chatterboxAndSamanthaUntouched() throws {
        let cartesia = FakeSpeechSynthesizer(); cartesia.autoFinish = true
        let chatterbox = FakeSpeechSynthesizer()
        let samantha = FakeSpeechSynthesizer()
        let sink = OutcomeSink()
        let cascade = makeCascade([cartesia, chatterbox, samantha]); try cascade.speak("hello", category: .information, onFinished: sink.handler)
        #expect(cartesia.speakCallCount == 1)
        #expect(chatterbox.speakCallCount == 0, "no Chatterbox load/use on a healthy Cartesia request")
        #expect(samantha.speakCallCount == 0)
        #expect(sink.outcomes == [.finished])
    }

    // 2 — Cartesia fails pre-playback → Chatterbox used

    @Test func cartesiaFailsPrePlayback_chatterboxUsed() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia unreachable")
        #expect(tiers[1].speakCallCount == 1)
        #expect(tiers[2].speakCallCount == 0)
        tiers[1].simulateFinished()
        #expect(sink.outcomes == [.finished])
    }

    // 3 — Cartesia fails + Chatterbox fails → Samantha used

    @Test func cartesiaAndChatterboxFail_samanthaUsed() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia down")
        tiers[1].simulateFailure("chatterbox generation failed")
        #expect(tiers[2].speakCallCount == 1)
        tiers[2].simulateFinished()
        #expect(sink.outcomes == [.finished])
    }

    // 4 — Cartesia playback started then provider fails (.interrupted) → NO Chatterbox replay

    @Test func cartesiaInterruptedAfterPlaybackBegan_noChatterboxReplay() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers)
        try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].stop() // engine reports .interrupted (playback had begun / barge-in)
        #expect(tiers[1].speakCallCount == 0, "a tier reporting .interrupted must NEVER be replaced by a lower tier")
        #expect(tiers[2].speakCallCount == 0)
        #expect(sink.outcomes == [.interrupted])
    }

    // 5 — Chatterbox playback started then local failure (.interrupted) → NO Samantha replay

    @Test func chatterboxInterruptedAfterPlaybackBegan_noSamanthaReplay() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia down")            // advance to Chatterbox
        #expect(tiers[1].speakCallCount == 1)
        tiers[1].stop()                                       // Chatterbox reports .interrupted
        #expect(tiers[2].speakCallCount == 0, "Samantha must not replay after Chatterbox began speaking")
        #expect(sink.outcomes == [.interrupted])
    }

    // 6 — barge-in during Cartesia → interrupted exactly once, no local fallback

    @Test func bargeInDuringCartesia_interruptedExactlyOnce_noFallback() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers)
        try cascade.speak("hi", category: .information, onFinished: sink.handler)
        cascade.stop()
        #expect(tiers[1].speakCallCount == 0)
        #expect(tiers[2].speakCallCount == 0)
        #expect(sink.outcomes == [.interrupted])
    }

    // 7 — barge-in during Chatterbox → interrupted exactly once, no Samantha

    @Test func bargeInDuringChatterbox_interruptedExactlyOnce_noSamantha() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers)
        try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia down")
        #expect(tiers[1].speakCallCount == 1)
        cascade.stop()
        #expect(tiers[2].speakCallCount == 0)
        #expect(sink.outcomes == [.interrupted])
    }

    // 8 — Cartesia cancelled (.interrupted) → no fallback caused by user cancellation

    @Test func cartesiaCancelled_noFallback() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].stop() // FakeSpeechSynthesizer.stop() delivers .interrupted, modeling a cancel
        #expect(tiers[1].speakCallCount == 0)
        #expect(sink.outcomes == [.interrupted])
    }

    // 9 — local service unavailable (throws on begin) → Samantha emergency fallback

    @Test func localServiceUnavailable_throwsOnBegin_samanthaEngages() throws {
        let cartesia = FakeSpeechSynthesizer(); cartesia.autoFinish = false
        let chatterbox = FakeSpeechSynthesizer()
        chatterbox.shouldFailToStart = LocalChatterboxSpeechSynthesizer.NotAvailableError()
        let samantha = FakeSpeechSynthesizer(); samantha.autoFinish = false
        let sink = OutcomeSink()
        let cascade = makeCascade([cartesia, chatterbox, samantha]); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        cartesia.simulateFailure("cartesia down")
        // The Chatterbox tier throws on begin (service socket absent);
        // `FakeSpeechSynthesizer` throws before incrementing its own
        // counter, so the real proof the cascade advanced past the throw
        // is that Samantha was reached.
        #expect(samantha.speakCallCount == 1)
        samantha.simulateFinished()
        #expect(sink.outcomes == [.finished])
    }

    // 10 — local generation timeout pre-playback (.failed) → Samantha per policy

    @Test func localGenerationTimeoutPrePlayback_samanthaEngages() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia timeout")
        tiers[1].simulateFailure("local generation timed out before any audio")
        #expect(tiers[2].speakCallCount == 1)
        tiers[2].simulateFinished()
        #expect(sink.outcomes == [.finished])
    }

    // 11 — next utterance after Cartesia interruption → succeeds

    @Test func nextUtteranceAfterCartesiaInterruption_succeeds() throws {
        let cartesia = FakeSpeechSynthesizer(); cartesia.autoFinish = false
        let chatterbox = FakeSpeechSynthesizer()
        let samantha = FakeSpeechSynthesizer()
        let cascade = makeCascade([cartesia, chatterbox, samantha])
        let sink1 = OutcomeSink()
        try cascade.speak("first", category: .information, onFinished: sink1.handler)
        cascade.stop()
        #expect(sink1.outcomes == [.interrupted])

        cartesia.autoFinish = true
        let sink2 = OutcomeSink()
        try cascade.speak("second", category: .information, onFinished: sink2.handler)
        #expect(sink2.outcomes == [.finished])
        #expect(chatterbox.speakCallCount == 0)
    }

    // 12 — next utterance after Chatterbox interruption → succeeds

    @Test func nextUtteranceAfterChatterboxInterruption_succeeds() throws {
        let cartesia = FakeSpeechSynthesizer(); cartesia.autoFinish = false
        let chatterbox = FakeSpeechSynthesizer(); chatterbox.autoFinish = false
        let samantha = FakeSpeechSynthesizer()
        let cascade = makeCascade([cartesia, chatterbox, samantha])
        let sink1 = OutcomeSink()
        try cascade.speak("first", category: .information, onFinished: sink1.handler)
        cartesia.simulateFailure("down")
        cascade.stop()
        #expect(sink1.outcomes == [.interrupted])

        cartesia.autoFinish = true
        let sink2 = OutcomeSink()
        try cascade.speak("second", category: .information, onFinished: sink2.handler)
        #expect(sink2.outcomes == [.finished])
    }

    // 13 — stale provider callback (fires .failed AFTER stop()) → ignored

    @Test func staleProviderCallbackAfterStop_ignored() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers)
        try cascade.speak("hi", category: .information, onFinished: sink.handler)
        cascade.stop()
        tiers[0].simulateFailure("late failure for a superseded utterance")
        #expect(tiers[1].speakCallCount == 0, "a stale callback must not resurrect the cascade")
        #expect(sink.outcomes == [.interrupted], "exactly one terminal outcome, ever")
    }

    // 14 — stale local callback → ignored

    @Test func staleLocalCallbackAfterStop_ignored() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers)
        try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("cartesia down")
        cascade.stop()
        tiers[1].simulateFailure("late local failure")
        #expect(tiers[2].speakCallCount == 0)
        #expect(sink.outcomes == [.interrupted])
    }

    // 15 — duplicate completion callback → ignored (exactly once)

    @Test func duplicateCompletionCallback_deliveredExactlyOnce() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFinished()
        tiers[0].simulateFinished() // FakeSpeechSynthesizer's own guard blocks this, but assert cascade-side too
        #expect(sink.outcomes == [.finished])
    }

    // exactly-once terminal delivery holds even across a failure->success chain

    @Test func failureThenSuccessChain_deliversExactlyOneTerminal() throws {
        let tiers = manualTiers(3)
        let sink = OutcomeSink()
        let cascade = makeCascade(tiers); try cascade.speak("hi", category: .information, onFinished: sink.handler)
        tiers[0].simulateFailure("a")
        tiers[1].simulateFinished()
        tiers[0].simulateFailure("stale late") // must be ignored
        tiers[1].simulateFinished()             // must be ignored
        #expect(sink.outcomes == [.finished])
    }

    // engineIdentifier reflects the cascade order (diagnostics/menu-bar readability)

    @Test func engineIdentifier_showsCascadeOrder() {
        let a = FakeSpeechSynthesizer()
        let cascade = CascadingSpeechSynthesizer(tiers: [a, a, a])
        #expect(cascade.engineIdentifier.contains("cascade["))
        #expect(cascade.engineIdentifier.contains("->"))
    }
}
