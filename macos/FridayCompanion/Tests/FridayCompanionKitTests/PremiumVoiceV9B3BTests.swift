import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.3B — real audible local playback coverage. Every test here
/// uses a FAKE `PCMAudioPlaying`/`LocalIPCTransport` — no real socket or
/// audio hardware is touched (the real, empirical audible verification —
/// confirmed playback duration matching reported audio duration to
/// within measurement noise — was performed live and is documented in
/// this pass's own STOP report). Nothing here touches the frozen
/// conversational brain, Cartesia's accepted behavior, or fallback
/// ordering.
@Suite struct PremiumVoiceV9B3BTests {
    // MARK: - Fakes

    private final class FakePCMAudioPlayer: PCMAudioPlaying, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var playCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var lastData: Data?
        private(set) var lastFormat: AudioFormatDescriptor?
        /// When `false`, `play` records the call but does NOT invoke
        /// either callback until `completePendingPlayback` is called —
        /// lets a test simulate playback still in flight when `stop()` arrives.
        var autoComplete = true
        var completionResult = true
        private var pendingCompletion: (@Sendable (Bool) -> Void)?

        func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void) {
            lock.lock(); playCallCount += 1; lastData = data; lastFormat = format; lock.unlock()
            onPlaybackStarted()
            if autoComplete {
                onPlaybackComplete(completionResult)
            } else {
                lock.lock(); pendingCompletion = onPlaybackComplete; lock.unlock()
            }
        }

        func completePendingPlayback(_ result: Bool) {
            lock.lock(); let completion = pendingCompletion; pendingCompletion = nil; lock.unlock()
            completion?(result)
        }

        func stop() {
            lock.lock(); stopCallCount += 1; let completion = pendingCompletion; pendingCompletion = nil; lock.unlock()
            completion?(false)
        }
    }

    private final class FakeLocalIPCTransport: LocalIPCTransport, @unchecked Sendable {
        var scriptedResponse: Result<Data, Error> = .success(Data())
        private(set) var lastRequestJSON: [String: Any]?

        func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
            lastRequestJSON = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            completion(scriptedResponse)
        }
    }

    private func okResponse(sampleRate: Int = 24000, audio: Data = Data(repeating: 0, count: 400), generationMs: Double = 100, audioDurationSec: Double = 1.0, modelClass: String = "chatterbox.tts_turbo.ChatterboxTurboTTS", checkpointRepo: String = "ResembleAI/chatterbox-turbo") -> Data {
        let json: [String: Any] = [
            "status": "ok", "sampleRate": sampleRate, "audioBase64": audio.base64EncodedString(),
            "timing": ["generationStartMs": 0.0, "generationCompleteMs": generationMs, "audioDurationSec": audioDurationSec, "modelClass": modelClass, "checkpointRepo": checkpointRepo],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func errorResponse(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status": "error", "error": message, "timing": [String: Any]()])
    }

    // MARK: - §10: valid audio reaches the playback layer

    @Test func validAudio_reachesPlaybackLayer_withCorrectFormat() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse(sampleRate: 22050, audio: Data(repeating: 7, count: 800)))
        let player = FakePCMAudioPlayer()
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: player, socketExistenceCheck: { _ in true })
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello", category: .information, onFinished: { outcome = $0 })
        #expect(player.playCallCount == 1)
        #expect(player.lastData == Data(repeating: 7, count: 800))
        #expect(player.lastFormat?.sampleRate == 22050)
        #expect(player.lastFormat?.channelCount == 1)
        #expect(player.lastFormat?.sampleFormat == "pcm_f32le")
        #expect(outcome == .finished)
    }

    @Test func requestJSON_sendsExpectedFields() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse())
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "multilingual", transport: transport, player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        try? synth.speak("Bonjour", category: .information, onFinished: { _ in })
        #expect(transport.lastRequestJSON?["text"] as? String == "Bonjour")
        #expect(transport.lastRequestJSON?["variant"] as? String == "multilingual")
    }

    // MARK: - §10: unsupported audio format rejected safely

    @Test func unsupportedSampleFormat_rejectedSafely_neverCrashes() {
        let player = AVAudioEnginePCMPlayer()
        var completed: Bool?
        player.play(Data(repeating: 0, count: 100), format: AudioFormatDescriptor(sampleRate: 24000, channelCount: 1, sampleFormat: "totally-unknown-format", interleaved: true), onPlaybackStarted: {}, onPlaybackComplete: { completed = $0 })
        #expect(completed == false)
    }

    @Test func zeroSampleRate_rejectedSafely() {
        let player = AVAudioEnginePCMPlayer()
        var completed: Bool?
        player.play(Data(repeating: 0, count: 100), format: AudioFormatDescriptor(sampleRate: 0, channelCount: 1, sampleFormat: "pcm_f32le", interleaved: true), onPlaybackStarted: {}, onPlaybackComplete: { completed = $0 })
        #expect(completed == false)
    }

    @Test func emptyAudioData_rejectedSafely() {
        let player = AVAudioEnginePCMPlayer()
        var completed: Bool?
        player.play(Data(), format: AudioFormatDescriptor(sampleRate: 24000, channelCount: 1, sampleFormat: "pcm_f32le", interleaved: true), onPlaybackStarted: {}, onPlaybackComplete: { completed = $0 })
        #expect(completed == false)
    }

    @Test func misalignedByteCount_rejectedSafely() {
        // float32 mono needs a byte count divisible by 4.
        let player = AVAudioEnginePCMPlayer()
        var completed: Bool?
        player.play(Data(repeating: 0, count: 7), format: AudioFormatDescriptor(sampleRate: 24000, channelCount: 1, sampleFormat: "pcm_f32le", interleaved: true), onPlaybackStarted: {}, onPlaybackComplete: { completed = $0 })
        #expect(completed == false)
    }

    // MARK: - §10: sample-rate handling

    @Test func sampleRate_threadedFromServerResponse_notHardcoded() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse(sampleRate: 44100))
        let player = FakePCMAudioPlayer()
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: player, socketExistenceCheck: { _ in true })
        try? synth.speak("Hello", category: .information, onFinished: { _ in })
        #expect(player.lastFormat?.sampleRate == 44100, "the REAL server-reported sample rate must be used, never a hardcoded assumption")
    }

    // MARK: - §10: playback completion exactly once

    @Test func playbackCompletion_deliveredExactlyOnce() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse())
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello", category: .information, onFinished: { outcomes.append($0) })
        #expect(outcomes == [.finished])
    }

    // MARK: - §10/§5: stop -> interrupted exactly once

    @Test func stop_duringPlayback_deliversInterruptedExactlyOnce() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse())
        let player = FakePCMAudioPlayer()
        player.autoComplete = false // simulate playback still in flight
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: player, socketExistenceCheck: { _ in true })
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello", category: .information, onFinished: { outcomes.append($0) })
        #expect(outcomes.isEmpty, "must not have finished yet — playback is still 'in flight'")
        synth.stop()
        #expect(outcomes == [.interrupted])
        #expect(player.stopCallCount == 1)
        // A late, real player completion arriving after stop() must never add a second outcome.
        player.completePendingPlayback(true)
        #expect(outcomes == [.interrupted], "no late player completion may ever add a second delivered outcome")
    }

    @Test func stop_beforeAnySpeak_isHarmlessNoOp() {
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: FakeLocalIPCTransport(), player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        synth.stop() // nothing in flight — must not crash
    }

    // MARK: - §10: stale buffer rejected

    @Test func staleResponse_forSupersededUtterance_isDiscarded() {
        // A transport whose completion fires only when explicitly told
        // to — lets this test call stop() (which starts a NEW, superseding
        // identity generation) BEFORE the "in-flight" response arrives.
        final class DelayedTransport: LocalIPCTransport, @unchecked Sendable {
            var stored: (Result<Data, Error>, @Sendable (Result<Data, Error>, IPCTimingSnapshot) -> Void)?
            func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {}
            func requestWithTiming(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>, IPCTimingSnapshot) -> Void) {
                stored = (.success(Data()), completion)
            }
            func fire(_ data: Data) {
                stored?.1(.success(data), IPCTimingSnapshot(requestStart: Date()))
            }
        }
        let transport = DelayedTransport()
        let player = FakePCMAudioPlayer()
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: player, socketExistenceCheck: { _ in true })
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello", category: .information, onFinished: { outcomes.append($0) })
        synth.stop() // supersedes the utterance BEFORE the response arrives
        #expect(outcomes == [.interrupted])
        transport.fire(okResponse()) // the stale response now arrives
        #expect(outcomes == [.interrupted], "a response for an already-superseded utterance must never be applied")
        #expect(player.playCallCount == 0, "stale audio must never even reach the player")
    }

    // MARK: - §10: no duplicate fallback replay

    @Test func fallbackSynthesizer_prePlaybackFailure_secondaryMaySpeak() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(errorResponse("simulated failure"))
        let chatterbox = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: chatterbox, secondary: secondary)
        var outcome: SpeechSynthesisOutcome?
        try? fallback.speak("Hello", category: .information, onFinished: { outcome = $0 })
        #expect(secondary.speakCallCount == 1, "nothing was heard yet — Samantha may speak the full response")
        #expect(outcome == .finished)
    }

    @Test func fallbackSynthesizer_postPlaybackInterruption_neverReplaysThroughSecondary() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse())
        let player = FakePCMAudioPlayer()
        player.autoComplete = false
        let chatterbox = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: player, socketExistenceCheck: { _ in true })
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: chatterbox, secondary: secondary)
        var outcome: SpeechSynthesisOutcome?
        try? fallback.speak("Hello", category: .information, onFinished: { outcome = $0 })
        fallback.stop() // barge-in AFTER playback had already begun
        #expect(outcome == .interrupted)
        #expect(secondary.speakCallCount == 0, "already-partially-heard content must NEVER be replayed through Samantha")
    }

    // MARK: - §10/§6: model labeling correctness

    @Test func turbo_correctlyLabeled_genuineTurbo() {
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: FakeLocalIPCTransport(), player: FakePCMAudioPlayer())
        #expect(synth.engineIdentifier.contains("turbo"))
        #expect(!synth.engineIdentifier.lowercased().contains("nano"))
    }

    @Test func baseEnglish_neverLabeledNano() {
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "base-english", transport: FakeLocalIPCTransport(), player: FakePCMAudioPlayer())
        #expect(synth.engineIdentifier.contains("base-english"))
        #expect(!synth.engineIdentifier.lowercased().contains("nano"), "the base model must never be labeled Nano anywhere")
    }

    @Test func baseEnglishRequest_sendsRenamedVariantString_neverTheOldNanoString() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .success(okResponse())
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "base-english", transport: transport, player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        try? synth.speak("Hello", category: .information, onFinished: { _ in })
        #expect(transport.lastRequestJSON?["variant"] as? String == "base-english")
    }

    // MARK: - §10: multilingual routing unaffected

    @Test func multilingualVariant_stillRoutesCorrectly_throughLocalChatterboxProvider() {
        // LocalChatterboxProvider itself is UNCHANGED by this milestone —
        // confirms the (renamed-elsewhere) variant relabeling never
        // touched its own, already-tested behavior.
        final class FakeTransport: LocalIPCTransport, @unchecked Sendable {
            func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                let response = try! JSONEncoder().encode(LocalChatterboxProvider.WireResponse(status: "ok", sampleRate: 24000, audioBase64: Data([1, 2, 3]).base64EncodedString(), error: nil))
                completion(.success(response))
            }
        }
        let provider = LocalChatterboxProvider(socketPath: "/tmp/x.sock", variant: "multilingual", transport: FakeTransport())
        var events: [SpeechSynthesisEvent] = []
        let request = SpeechSynthesisRequest(interactionID: "i1", utteranceID: "u1", text: "Bonjour", voiceID: "default", language: "fr", prosody: ProsodyPlan(rate: 0.5, pitchMultiplier: 1, volume: 1, preUtteranceDelay: 0, postUtteranceDelay: 0, emphasisStrength: 0, energy: 0.5))
        _ = provider.synthesize(request) { events.append($0) }
        #expect(events.last == .completed(interactionID: "i1", utteranceID: "u1"))
    }

    // MARK: - Not-available / IPC-failure paths (honest, never fabricated)

    @Test func socketNotFound_throwsNotAvailable_neverFabricatesSuccess() {
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/nonexistent.sock", variant: "turbo", transport: FakeLocalIPCTransport(), player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in false })
        #expect(throws: LocalChatterboxSpeechSynthesizer.NotAvailableError.self) {
            try synth.speak("Hello", category: .information, onFinished: { _ in })
        }
    }

    @Test func ipcFailure_reportsFailed_neverCrashes() {
        let transport = FakeLocalIPCTransport()
        transport.scriptedResponse = .failure(NSError(domain: "test", code: 1))
        let synth = LocalChatterboxSpeechSynthesizer(socketPath: "/tmp/x.sock", variant: "turbo", transport: transport, player: FakePCMAudioPlayer(), socketExistenceCheck: { _ in true })
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello", category: .information, onFinished: { outcome = $0 })
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(String(describing: outcome))") }
    }
}
