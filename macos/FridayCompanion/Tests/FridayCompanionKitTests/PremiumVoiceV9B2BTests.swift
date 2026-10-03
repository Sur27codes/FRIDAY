import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.2B — regression coverage for the barge-in/cancellation
/// correctness fix: `PremiumNeuralSpeechSynthesizer.stop()` previously
/// only invalidated the LOCAL `UtteranceIdentityGuard` — the provider's
/// own `SpeechProviderCancelToken` (e.g. Cartesia's `context_id`-scoped
/// cancel message) was silently discarded (`_ = provider.synthesize(...)`)
/// and never actually invoked. Every test here uses the existing fake
/// provider — no real network/socket call is made.
@Suite struct PremiumVoiceV9B2BTests {
    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    @Test func stop_actuallyInvokesTheProviderCancelToken() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0.05, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        try? synth.speak("A sufficiently long utterance for a real barge-in scenario.", category: .information, onFinished: { _ in })
        fake.waitForSynthesizeCall()
        synth.stop()
        #expect(fake.cancelCallCount == 1, "stop() must reach the provider's own cancellation path (e.g. Cartesia's context_id cancel), not merely the local identity guard")
    }

    @Test func stop_beforeAnySpeak_isHarmlessNoOp() {
        let fake = FakePremiumSpeechStreamProvider()
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        synth.stop() // nothing in flight
        #expect(fake.cancelCallCount == 0)
    }

    @Test func stop_afterUtteranceAlreadyCompleted_doesNotRecancelANewerUtterance() {
        // Guards the exact race the `nil`-out-before-calling-cancel
        // ordering in `stop()` exists to prevent: a stray late `stop()`
        // for turn A must never reach into turn B's own, unrelated
        // in-flight cancel token.
        let fakeA = FakePremiumSpeechStreamProvider()
        fakeA.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fakeA)
        try? synth.speak("First, short utterance.", category: .information, onFinished: { _ in })
        // Turn A already finished synchronously — its own token is
        // spent, and `currentCancelToken` was cleared. A stop() here
        // must be a harmless no-op, never crash, never double-cancel.
        synth.stop()
        #expect(fakeA.cancelCallCount == 0, "a completed utterance's own token was never re-cancelled")
    }

    @Test func afterCancellation_aSecondUtteranceCanStillSpeakSuccessfully() {
        // §9 of P2-M5V9-B.2B's own required proof: cancelling one turn
        // must never poison the synthesizer for the NEXT turn.
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0.05, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        try? synth.speak("A long utterance that will be interrupted.", category: .information, onFinished: { _ in })
        fake.waitForSynthesizeCall()
        synth.stop()
        #expect(fake.cancelCallCount == 1)

        // Second, independent utterance — a fresh script, fresh outcome.
        fake.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        var secondOutcome: SpeechSynthesisOutcome?
        try? synth.speak("Second, short utterance.", category: .information, onFinished: { secondOutcome = $0 })
        #expect(secondOutcome == .finished, "the synthesizer must remain fully usable for a new turn after a cancellation")
    }

    @Test func fallbackSpeechSynthesizer_stop_stillReachesPremiumProviderCancelToken() {
        // The full production composition (`FallbackSpeechSynthesizer`
        // wrapping `PremiumNeuralSpeechSynthesizer`) must still propagate
        // stop() correctly through to the provider-level cancel.
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0.05, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
        ]
        let premium = PremiumNeuralSpeechSynthesizer(provider: fake)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premium, secondary: secondary)
        try? fallback.speak("A long utterance spoken through the real production composition.", category: .information, onFinished: { _ in })
        fake.waitForSynthesizeCall()
        fallback.stop()
        #expect(fake.cancelCallCount == 1)
        #expect(secondary.stopCallCount == 1, "the secondary engine must also receive stop(), matching FallbackSpeechSynthesizer's existing contract")
    }

    @Test func cartesiaProvider_cancelToken_sendsRealCancelMessage_whenReachedThroughStop() {
        // End-to-end proof (fake WebSocket transport only) that a real
        // `stop()` call, routed through `PremiumNeuralSpeechSynthesizer`,
        // now genuinely results in Cartesia's own `context_id`-scoped
        // cancel message being sent — not just a local no-op.
        final class SlowFakeHandle: CartesiaWebSocketHandle, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var sentMessages: [String] = []
            private(set) var closeCallCount = 0
            func send(_ message: String) { lock.lock(); sentMessages.append(message); lock.unlock() }
            func close() { lock.lock(); closeCallCount += 1; lock.unlock() }
        }
        final class SlowFakeTransport: CartesiaWebSocketTransport, @unchecked Sendable {
            let handle = SlowFakeHandle()
            func open(url: URL, headers: [String: String], onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) -> CartesiaWebSocketHandle {
                // No scripted messages at all — simulates an utterance
                // still mid-generation when stop() arrives.
                handle
            }
        }
        let transport = SlowFakeTransport()
        let config = PremiumVoiceProviderConfig(
            endpoint: URL(string: "wss://api.cartesia.ai/tts/websocket"), apiKey: "dummy-test-key", providerName: "cartesia",
            modelName: "sonic-3.6", voiceID: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", locale: "en-US", apiVersion: "2026-08-14"
        )
        let cartesiaProvider = CartesiaSpeechStreamProvider(config: config, transport: transport)
        let synth = PremiumNeuralSpeechSynthesizer(provider: cartesiaProvider)
        try? synth.speak("A long, multi-sentence utterance meant to still be generating when barge-in occurs.", category: .information, onFinished: { _ in })
        synth.stop()
        let cancelSent = transport.handle.sentMessages.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(cancelSent?["cancel"] as? Bool == true, "stop() must result in Cartesia's real context_id cancel message being sent")
        #expect(transport.handle.closeCallCount == 1)
    }

    // MARK: - §6 report field: "late chunks discarded: count"

    /// Unlike `FakePremiumSpeechStreamProvider` (which idealizes a
    /// well-behaved provider that stops sending events once its OWN
    /// cancel action fires), this double simulates a REAL network race:
    /// a chunk already in flight over the wire when cancellation was
    /// requested still arrives afterward — exactly what
    /// `UtteranceIdentityGuard`/`recordPremiumStaleChunkDiscarded` exist
    /// to handle safely.
    private final class RacyLateChunkProvider: PremiumSpeechStreamProviding, @unchecked Sendable {
        let capabilities = PremiumSpeechCapabilities.none
        func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken {
            onEvent(.audioChunk(interactionID: request.interactionID, utteranceID: request.utteranceID, samples: Data(repeating: 0, count: 4800), sequence: 0))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
                // Delivered regardless of any cancel request — the race this test exists to prove is handled safely.
                onEvent(.audioChunk(interactionID: request.interactionID, utteranceID: request.utteranceID, samples: Data(repeating: 0, count: 4800), sequence: 1))
            }
            return SpeechProviderCancelToken(cancelAction: {})
        }
    }

    @Test func lateAudioChunk_afterStop_isCountedAsDiscarded_neverAccepted() {
        let diagnostics = WakeDiagnosticsRecorder()
        let synth = PremiumNeuralSpeechSynthesizer(provider: RacyLateChunkProvider(), diagnostics: diagnostics)
        try? synth.speak("A long utterance.", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().premiumChunksReceivedCount == 1, "the first, genuinely in-time chunk must be accepted")
        synth.stop()
        pump(seconds: 0.15) // let the second, now-stale chunk arrive despite the race
        #expect(diagnostics.snapshot().premiumChunksReceivedCount == 1, "no chunk arriving after stop() may ever be accepted")
        #expect(diagnostics.snapshot().premiumStaleChunksDiscardedCount == 1, "the late chunk must be counted as discarded, not silently invisible")
    }

    @Test func noLateChunks_discardedCountStaysZero() {
        let diagnostics = WakeDiagnosticsRecorder()
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, diagnostics: diagnostics)
        try? synth.speak("Short.", category: .information, onFinished: { _ in })
        #expect(diagnostics.snapshot().premiumStaleChunksDiscardedCount == 0)
    }
}
