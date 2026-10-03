import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5 §32 — `SpeechSynthesizing` lifecycle tests against
/// `FakeSpeechSynthesizer` (deterministic, no real audio hardware) and
/// `NullSpeechSynthesizer` (the safe default). `AVSpeechSynthesizerAdapter`
/// itself is exercised for real on owner hardware (§48/§49) — this suite
/// covers the CONTRACT every implementation must uphold: exactly-once
/// termination, no stuck `.speaking`, no double completion.
@Suite struct SpeechSynthesizingTests {

    @Test func nullSynthesizer_speak_completesImmediately_synchronously() throws {
        let synth = NullSpeechSynthesizer()
        final class Box: @unchecked Sendable { var outcome: SpeechSynthesisOutcome? }
        let box = Box()
        try synth.speak("hello") { box.outcome = $0 }
        #expect(box.outcome == .finished, "a null TTS engine must truthfully and immediately 'finish' — never leave a caller waiting")
    }

    @Test func nullSynthesizer_stop_isHarmlessNoOp() {
        let synth = NullSpeechSynthesizer()
        synth.stop() // must not crash even with nothing in flight
    }

    @Test func fakeSynthesizer_speak_recordsText_startsInFlight() throws {
        let synth = FakeSpeechSynthesizer()
        synth.autoFinish = false
        try synth.speak("System status retrieved successfully.") { _ in }
        #expect(synth.speakCallCount == 1)
        #expect(synth.spokenTexts == ["System status retrieved successfully."])
        #expect(synth.isSpeaking)
    }

    @Test func fakeSynthesizer_simulateFinished_deliversExactlyOnce() throws {
        let synth = FakeSpeechSynthesizer()
        synth.autoFinish = false
        final class Box: @unchecked Sendable { var outcomes: [SpeechSynthesisOutcome] = [] }
        let box = Box()
        try synth.speak("hi") { box.outcomes.append($0) }
        synth.simulateFinished()
        synth.simulateFinished() // duplicate callback — must not double-deliver
        #expect(box.outcomes == [.finished], "exactly-once termination even if the underlying engine calls back twice")
        #expect(!synth.isSpeaking)
    }

    @Test func fakeSynthesizer_simulateFailure_deliversFailureExactlyOnce() throws {
        let synth = FakeSpeechSynthesizer()
        synth.autoFinish = false
        final class Box: @unchecked Sendable { var outcomes: [SpeechSynthesisOutcome] = [] }
        let box = Box()
        try synth.speak("hi") { box.outcomes.append($0) }
        synth.simulateFailure("engine error")
        synth.simulateFinished() // stray late callback after failure — must not fire
        #expect(box.outcomes == [.failed("engine error")])
    }

    @Test func fakeSynthesizer_stopWhileSpeaking_deliversInterruptedExactlyOnce() throws {
        let synth = FakeSpeechSynthesizer()
        synth.autoFinish = false
        final class Box: @unchecked Sendable { var outcomes: [SpeechSynthesisOutcome] = [] }
        let box = Box()
        try synth.speak("hi") { box.outcomes.append($0) }
        synth.stop()
        synth.stop() // duplicate stop — must not double-deliver
        #expect(box.outcomes == [.interrupted])
        #expect(synth.stopCallCount == 2, "stop() itself may be called more than once — only the CALLBACK must be exactly-once")
    }

    @Test func fakeSynthesizer_lateCallbackAfterStop_isSuppressed() throws {
        let synth = FakeSpeechSynthesizer()
        synth.autoFinish = false
        final class Box: @unchecked Sendable { var outcomes: [SpeechSynthesisOutcome] = [] }
        let box = Box()
        try synth.speak("hi") { box.outcomes.append($0) }
        synth.stop()
        // A "late" real-engine callback racing in after stop() — must be
        // suppressed, mirroring `AppleSpeechTranscriber`'s own
        // `delivered` guard on the STT side.
        synth.simulateFinished()
        #expect(box.outcomes == [.interrupted])
    }

    @Test func fakeSynthesizer_shouldFailToStart_throwsBeforeAnyCallback() {
        let synth = FakeSpeechSynthesizer()
        synth.shouldFailToStart = SpeechTranscriptionError.engineUnavailable("simulated")
        final class Box: @unchecked Sendable { var called = false }
        let box = Box()
        #expect(throws: (any Error).self) {
            try synth.speak("hi") { _ in box.called = true }
        }
        #expect(!box.called, "onFinished must never fire for an attempt that failed to even start")
    }

    @Test func fakeSynthesizer_autoFinishDefault_matchesNullSynthesizerConvenience() throws {
        // Default `autoFinish = true` mirrors `NullSpeechSynthesizer`'s
        // synchronous-completion convenience for tests that don't care
        // about timing.
        let synth = FakeSpeechSynthesizer()
        final class Box: @unchecked Sendable { var outcome: SpeechSynthesisOutcome? }
        let box = Box()
        try synth.speak("hi") { box.outcome = $0 }
        #expect(box.outcome == .finished)
    }
}
