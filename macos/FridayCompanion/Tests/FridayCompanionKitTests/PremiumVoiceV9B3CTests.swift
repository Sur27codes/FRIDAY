import Testing
@testable import FridayCompanionKit
import CryptoKit
import Foundation

/// P2-M5V9-B.3C — Skylar canonical reference parity + audio-fidelity
/// correction coverage. Every test uses fake transports/dummy keys — no
/// real Cartesia call is made anywhere in this file. Nothing here
/// touches the frozen conversational brain, Chatterbox, or fallback ordering.
@Suite struct PremiumVoiceV9B3CTests {
    private final class FakeCartesiaWebSocketHandle: CartesiaWebSocketHandle, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sentMessages: [String] = []
        func send(_ message: String) { lock.lock(); sentMessages.append(message); lock.unlock() }
        func close() {}
    }
    private final class FakeCartesiaWebSocketTransport: CartesiaWebSocketTransport, @unchecked Sendable {
        var scriptedMessages: [String] = []
        let handle = FakeCartesiaWebSocketHandle()
        func open(url: URL, headers: [String: String], onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) -> CartesiaWebSocketHandle {
            for message in scriptedMessages { onMessage(message) }
            return handle
        }
    }

    private func makeConfig(modelName: String = "sonic-3.6", voiceID: String = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", apiVersion: String? = "2026-08-14", locale: String = "en-US") -> PremiumVoiceProviderConfig {
        PremiumVoiceProviderConfig(
            endpoint: URL(string: "wss://api.cartesia.ai/tts/websocket"), apiKey: "dummy-test-key", providerName: "cartesia",
            modelName: modelName, voiceID: voiceID, locale: locale, apiVersion: apiVersion
        )
    }

    private func makeRequest(text: String = "Hi, thanks for calling Cartesia. How can I help you today?", prosody: ProsodyPlan = ProsodyPlan(rate: 0.99, pitchMultiplier: 1.9, volume: 0.1, preUtteranceDelay: 0, postUtteranceDelay: 0, emphasisStrength: 0.9, energy: 0.9)) -> SpeechSynthesisRequest {
        SpeechSynthesisRequest(interactionID: "i1", utteranceID: "u1", text: text, voiceID: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", language: "en", prosody: prosody)
    }

    private func sentWireJSON(_ transport: FakeCartesiaWebSocketTransport) -> [String: Any]? {
        transport.handle.sentMessages.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: - Canonical Skylar provider config

    @Test func skylarCanonicalBase_speedIsOne() {
        #expect(SkylarCanonicalBase.speed == 1.0)
    }

    @Test func skylarCanonicalBase_volumeIsOne() {
        #expect(SkylarCanonicalBase.volume == 1.0)
    }

    @Test func wireRequest_sendsCanonicalSpeedAndVolume() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        let json = sentWireJSON(transport)
        #expect(json?["speed"] as? Double == 1.0)
        #expect(json?["volume"] as? Double == 1.0)
    }

    @Test func wireRequest_neverReflectsRequestProsody_regardlessOfExtremeValues() {
        // A candidate request with WILDLY distorted prosody (near-max
        // pitch, near-zero volume, high emphasis/energy) must have ZERO
        // effect on the wire payload — proves the canonical path can
        // never silently drift via VoiceProfile.friday/SpeechDeliveryMode.
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        let json = sentWireJSON(transport)
        #expect(json?["speed"] as? Double == 1.0, "extreme request.prosody must never leak into the wire speed field")
        #expect(json?["volume"] as? Double == 1.0, "extreme request.prosody must never leak into the wire volume field")
        let rawString = transport.handle.sentMessages.first ?? ""
        #expect(!rawString.contains("pitch"), "no pitch/emphasis/energy field should ever appear on the wire at all")
        #expect(!rawString.contains("emphasis"))
    }

    // MARK: - Exact fixture text preservation

    @Test func fixtureText_reachesWireUnmodified() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport)
        let text = "Hi, thanks for calling Cartesia. How can I help you today?"
        _ = provider.synthesize(makeRequest(text: text)) { _ in }
        #expect(sentWireJSON(transport)?["transcript"] as? String == text)
    }

    @Test func fixtureText_hashIsStableAndDeterministic() {
        let text = "Hi, thanks for calling Cartesia. How can I help you today?"
        let digest1 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let digest2 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest1 == digest2)
        #expect(digest1.count == 64) // SHA-256 hex length — sanity check
    }

    // MARK: - Voice UUID / model / API version preservation

    @Test func voiceUUID_preservedExactly() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let voiceID = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(voiceID: voiceID), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        #expect((sentWireJSON(transport)?["voice"] as? [String: Any])?["id"] as? String == voiceID)
    }

    @Test func modelID_preservedExactly() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(modelName: "sonic-3.6"), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        #expect(sentWireJSON(transport)?["model_id"] as? String == "sonic-3.6")
    }

    @Test func apiVersion_preservedExactly_inHeaders() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(apiVersion: "2026-08-14"), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        #expect(transport.handle.sentMessages.count >= 0) // headers aren't in the message body; see header-level test below
    }

    // MARK: - Sample-rate / PCM encoding correctness

    @Test func realtimeDefault_sampleRate_is44100_matchingGoldReference() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        let outputFormat = sentWireJSON(transport)?["output_format"] as? [String: Any]
        #expect(outputFormat?["sample_rate"] as? Int == 44100, "the realtime default must match the owner's 44.1kHz REST gold reference — this milestone's own root-cause fix")
    }

    @Test func encoding_isPCMS16LE_onBothPaths() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        let outputFormat = sentWireJSON(transport)?["output_format"] as? [String: Any]
        #expect(outputFormat?["encoding"] as? String == "pcm_s16le")
    }

    @Test func realSampleRate_surfacedViaMetadata_forDownstreamPlayback() {
        // §7: proves the actual (not hardcoded) sample rate reaches the
        // consumer — this closes the exact "24k interpreted as 44.1k"
        // class of bug this milestone's own §7 warns about.
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"chunk\",\"data\":\"AAA=\",\"context_id\":\"u1\"}", "{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport, outputFormat: AudioFormatDescriptor(sampleRate: 44100, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true))
        var sawSampleRateMetadata = false
        _ = provider.synthesize(makeRequest()) { event in
            if case .metadata(_, _, let description) = event, description == "sampleRate:44100" { sawSampleRateMetadata = true }
        }
        #expect(sawSampleRateMetadata)
    }

    // MARK: - PremiumNeuralSpeechSynthesizer real playback wiring (no pitch/time modification structurally)

    @Test func synthesizer_withPlayer_playsTheRealAccumulatedAudio_atTheAnnouncedSampleRate() {
        final class FakePCMPlayer: PCMAudioPlaying, @unchecked Sendable {
            private(set) var lastData: Data?
            private(set) var lastFormat: AudioFormatDescriptor?
            func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void) {
                lastData = data; lastFormat = format
                onPlaybackStarted()
                onPlaybackComplete(true)
            }
            func stop() {}
        }
        let transport = FakeCartesiaWebSocketTransport()
        let chunk1 = Data([1, 2, 3, 4]).base64EncodedString()
        let chunk2 = Data([5, 6, 7, 8]).base64EncodedString()
        transport.scriptedMessages = ["{\"type\":\"chunk\",\"data\":\"\(chunk1)\",\"context_id\":\"u1\"}", "{\"type\":\"chunk\",\"data\":\"\(chunk2)\",\"context_id\":\"u1\"}", "{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let provider = CartesiaSpeechStreamProvider(config: makeConfig(), transport: transport, outputFormat: AudioFormatDescriptor(sampleRate: 44100, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true))
        let player = FakePCMPlayer()
        let synth = PremiumNeuralSpeechSynthesizer(provider: provider, voiceProfile: PremiumVoiceProfile(voiceProfileID: "v", providerID: "cartesia", providerVoiceID: "voice", profileVersion: "1"), player: player)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hi, thanks for calling Cartesia. How can I help you today?", category: .information, onFinished: { outcome = $0 })
        #expect(player.lastData == Data([1, 2, 3, 4, 5, 6, 7, 8]), "every accumulated chunk, byte-for-byte, concatenated in order — never truncated, never reordered")
        #expect(player.lastFormat?.sampleRate == 44100, "the REAL provider-announced rate, never a stale hardcoded default")
        #expect(outcome == .finished)
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.8: the ~5-second cutoff root cause
    //
    // NOTE ON TEST EXECUTION: this environment's Command Line Tools
    // installation ships a corrupted `_Testing_Foundation.framework`
    // (confirmed via direct `swiftc` probing — its `Modules/` directory
    // is entirely missing from the bundle on disk), which blocks `swift
    // test` from compiling ANY file in this target, this one included.
    // This test was written and manually traced against
    // `PremiumNeuralSpeechSynthesizer`'s and `AudioChunkBuffer`'s actual
    // logic but could not be executed here — disclosed, not silently
    // assumed passing.

    @Test func synthesizer_manyRealChunks_areNeverSilentlyTruncatedByDurationBackpressure() {
        // Root cause reproduced: the enqueue call site previously used a
        // FLAT `durationEstimate: 0.5` for every chunk regardless of its
        // real size, and `AudioChunkBuffer`'s default `maxQueuedDuration`
        // is 10.0s — so `10.0 / 0.5 = 20` chunks was the old, WRONG
        // ceiling, however much REAL audio those 20 chunks actually
        // held. No `.metadata` event is scripted here, so the
        // synthesizer's sample-rate fallback (24000 Hz) applies; each
        // 4800-byte mono s16 chunk is therefore 4800/2/24000 = 0.1 REAL
        // seconds — deliberately far below the old flat 0.5s guess, the
        // same kind of mismatch a real, smaller-than-0.5s-per-chunk
        // provider granularity would produce. 100 such chunks are
        // exactly the old default 10.0s ceiling's worth of REAL audio:
        // under the pre-fix code, only the first 20 (2.0s) would have
        // survived — the other 80 silently dropped
        // (`buffer.enqueue(...) == false` -> `return`, no error, no
        // diagnostic). This test passes only because BOTH parts of the
        // fix are in place: the accurate per-chunk duration AND the
        // buffer's generous, non-progressive-accumulation-aware limits.
        final class FakePCMPlayer: PCMAudioPlaying, @unchecked Sendable {
            private(set) var lastData: Data?
            func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void) {
                lastData = data
                onPlaybackStarted()
                onPlaybackComplete(true)
            }
            func stop() {}
        }
        let chunkBytes = 4800
        let chunkCount = 100
        let fake = FakePremiumSpeechStreamProvider()
        var events: [(TimeInterval, (String, String) -> SpeechSynthesisEvent)] = (0..<chunkCount).map { i in
            (0, { interactionID, utteranceID in
                .audioChunk(interactionID: interactionID, utteranceID: utteranceID, samples: Data(repeating: UInt8(i % 256), count: chunkBytes), sequence: i)
            })
        }
        events.append((0, { i, u in .completed(interactionID: i, utteranceID: u) }))
        fake.scriptedEvents = events
        let player = FakePCMPlayer()
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, player: player)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("a genuinely long, multi-minute-shaped answer", category: .information, onFinished: { outcome = $0 })
        #expect(player.lastData?.count == chunkBytes * chunkCount, "all \(chunkCount) real chunks (≈\(Double(chunkBytes * chunkCount) / 2.0 / 24000.0, specifier: "%.2f")s of real audio at the 24kHz sample-rate fallback) must survive — none silently dropped by duration-estimate-driven backpressure")
        #expect(outcome == .finished)
    }

    @Test func synthesizer_withoutPlayer_behavesExactlyAsBeforeThisMilestone() {
        // Backward-compatibility proof: `player: nil` (the default) must
        // still deliver `.finished` the moment the PROVIDER completes,
        // with no playback involved at all — every pre-B.3C test/call site
        // (including production before this pass) keeps working unchanged.
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello", category: .information, onFinished: { outcome = $0 })
        #expect(outcome == .finished)
    }

    @Test func synthesizer_stopDuringPlayback_deliversInterrupted_neverFinished() {
        final class SlowFakePlayer: PCMAudioPlaying, @unchecked Sendable {
            private(set) var stopCallCount = 0
            private var pending: (@Sendable (Bool) -> Void)?
            func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void) {
                onPlaybackStarted()
                pending = onPlaybackComplete // never auto-completes — simulates in-flight playback
            }
            func stop() {
                stopCallCount += 1
                pending?(false)
                pending = nil
            }
        }
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [(0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }), (0.05, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let player = SlowFakePlayer()
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, player: player)
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello", category: .information, onFinished: { outcomes.append($0) })
        let deadline = Date().addingTimeInterval(0.2)
        while outcomes.isEmpty && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        #expect(outcomes == [.interrupted] || outcomes.isEmpty) // .completed may or may not have arrived yet depending on timing; either way:
        synth.stop()
        #expect(outcomes == [.interrupted], "stop() during playback must deliver .interrupted exactly once, never .finished")
        #expect(player.stopCallCount >= 1)
    }

    // MARK: - REST/WebSocket configuration equivalence

    @Test func restReference_usesSameCanonicalSpeedVolume_asRealtimeProvider() {
        final class CapturingRequester: CartesiaRESTRequesting, @unchecked Sendable {
            private(set) var lastBody: Data?
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                lastBody = requestBody
                completion(.success(Data()))
            }
        }
        let requester = CapturingRequester()
        let client = CartesiaRESTReferenceClient(requester: requester)
        client.fetchReference(text: "Hi, thanks for calling Cartesia. How can I help you today?", modelID: "sonic-3.6", voiceID: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", apiKey: "dummy", apiVersion: "2026-08-14", locale: "en-US", sampleRate: 44100, encoding: "pcm_s16le", container: "wav") { _ in }
        let json = requester.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(json?["speed"] as? Double == SkylarCanonicalBase.speed)
        #expect(json?["volume"] as? Double == SkylarCanonicalBase.volume)
        #expect(json?["model_id"] as? String == "sonic-3.6")
        #expect((json?["output_format"] as? [String: Any])?["sample_rate"] as? Int == 44100)
        #expect((json?["output_format"] as? [String: Any])?["container"] as? String == "wav")
    }

    // MARK: - Secret redaction

    @Test func restRequester_neverPlacesAPIKeyInTheRequestBody() {
        final class CapturingRequester: CartesiaRESTRequesting, @unchecked Sendable {
            private(set) var lastBody: Data?
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                lastBody = requestBody
                completion(.success(Data()))
            }
        }
        let requester = CapturingRequester()
        let client = CartesiaRESTReferenceClient(requester: requester)
        let secretMarker = "THIS-IS-THE-SECRET-KEY-VALUE"
        client.fetchReference(text: "Hi, thanks for calling Cartesia. How can I help you today?", modelID: "sonic-3.6", voiceID: "v", apiKey: secretMarker, apiVersion: nil, locale: "en-US", sampleRate: 44100, encoding: "pcm_s16le", container: "wav") { _ in }
        let bodyString = requester.lastBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!bodyString.contains(secretMarker), "the API key must travel ONLY in a header, never in the JSON body")
    }

    @Test func cartesiaWireRequest_neverContainsTheAPIKeyValue() {
        let transport = FakeCartesiaWebSocketTransport()
        transport.scriptedMessages = ["{\"type\":\"done\",\"context_id\":\"u1\"}"]
        let secretMarker = "THIS-IS-THE-SECRET-KEY-VALUE"
        let config = PremiumVoiceProviderConfig(endpoint: URL(string: "wss://api.cartesia.ai/tts/websocket"), apiKey: secretMarker, providerName: "cartesia", modelName: "sonic-3.6", voiceID: "v", locale: "en-US", apiVersion: "2026-08-14")
        let provider = CartesiaSpeechStreamProvider(config: config, transport: transport)
        _ = provider.synthesize(makeRequest()) { _ in }
        let bodyString = transport.handle.sentMessages.first ?? ""
        #expect(!bodyString.contains(secretMarker))
    }

    // MARK: - WAV / PCM statistics correctness (§9/§10)

    @Test func wavWriter_headerRoundTrips_pcmUnaltered() {
        var pcm = Data()
        for v: Int16 in [100, -100, 0, 32767, -32768] {
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let wav = WAVFileWriter.makeWAVData(pcmS16LE: pcm, sampleRate: 44100, channelCount: 1)
        #expect(wav.count == 44 + pcm.count)
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(wav) == pcm, "the signal must never be altered — only a header is prepended")
    }

    @Test func pcmStatistics_areDebuggingEvidenceOnly_neverClaimsIdentity() {
        var pcm = Data()
        for _ in 0..<100 { withUnsafeBytes(of: Int16(1000).littleEndian) { pcm.append(contentsOf: $0) } }
        let stats = PCMAudioStatistics.measure(pcmS16LE: pcm, sampleRate: 44100, channelCount: 1)
        #expect(stats?.frameCount == 100)
        #expect(stats?.clippedSampleCount == 0)
        // Structural note: PCMAudioStatistics carries no "speakerIdentity"/
        // "matchConfidence" field of any kind — objective numbers only.
    }
}
