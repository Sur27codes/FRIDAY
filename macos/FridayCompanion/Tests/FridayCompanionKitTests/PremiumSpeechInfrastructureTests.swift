import Testing
@testable import FridayCompanionKit
import Foundation

/// A network-free fake `PremiumSpeechStreamProviding` for P2-M5V9 tests —
/// scriptable to deliver a sequence of events, optionally with a stale
/// (superseded) interaction/utterance ID, so adversarial scenarios (§33,
/// §28) are directly testable without any real provider.
final class FakePremiumSpeechStreamProvider: PremiumSpeechStreamProviding, @unchecked Sendable {
    let capabilities = PremiumSpeechCapabilities.none
    var scriptedEvents: [(delaySeconds: TimeInterval, makeEvent: (String, String) -> SpeechSynthesisEvent)] = []
    private let lock = NSLock()
    private(set) var synthesizeCallCount = 0
    private(set) var cancelCallCount = 0
    /// When set, events are tagged with THIS id instead of the request's
    /// own — simulates a provider returning stale/mismatched chunks.
    var overrideEventIDs: (interactionID: String, utteranceID: String)?

    func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken {
        lock.lock(); synthesizeCallCount += 1; lock.unlock()
        let ids = overrideEventIDs ?? (request.interactionID, request.utteranceID)
        var cancelled = false
        let cancelLock = NSLock()
        for scripted in scriptedEvents {
            let deliver = {
                cancelLock.lock(); let isCancelled = cancelled; cancelLock.unlock()
                guard !isCancelled else { return }
                onEvent(scripted.makeEvent(ids.interactionID, ids.utteranceID))
            }
            if scripted.delaySeconds > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + scripted.delaySeconds, execute: deliver)
            } else {
                deliver()
            }
        }
        return SpeechProviderCancelToken(cancelAction: { [weak self] in
            cancelLock.lock(); cancelled = true; cancelLock.unlock()
            self?.lock.lock(); self?.cancelCallCount += 1; self?.lock.unlock()
        })
    }

    func waitForSynthesizeCall(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while synthesizeCallCount == 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

/// Blocks the calling thread briefly to let async-delivered scripted
/// events land — every test here uses SHORT, bounded delays (<0.2s), so
/// this stays fast.
private func pump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@Suite struct PremiumSpeechInfrastructureTests {
    // MARK: - UtteranceIdentityGuard (§33)

    @Test func identityGuard_matchesCurrentUtterance() {
        let guardObj = UtteranceIdentityGuard()
        guardObj.begin(interactionID: "i1", utteranceID: "u1")
        #expect(guardObj.isCurrent(interactionID: "i1", utteranceID: "u1"))
    }

    @Test func identityGuard_rejectsStaleUtterance_afterNewOneBegins() {
        let guardObj = UtteranceIdentityGuard()
        guardObj.begin(interactionID: "i1", utteranceID: "u1")
        guardObj.begin(interactionID: "i2", utteranceID: "u2")
        #expect(!guardObj.isCurrent(interactionID: "i1", utteranceID: "u1"))
        #expect(guardObj.isCurrent(interactionID: "i2", utteranceID: "u2"))
    }

    @Test func identityGuard_rejectsEverything_afterInvalidate() {
        let guardObj = UtteranceIdentityGuard()
        guardObj.begin(interactionID: "i1", utteranceID: "u1")
        guardObj.invalidate()
        #expect(!guardObj.isCurrent(interactionID: "i1", utteranceID: "u1"))
    }

    // MARK: - AudioChunkValidator (§35)

    private let validFormat = AudioFormatDescriptor(sampleRate: 24000, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true)

    @Test func chunkValidator_rejectsEmptyPayload() {
        #expect(!AudioChunkValidator.validate(Data(), format: validFormat))
    }

    @Test func chunkValidator_rejectsOversizedPayload() {
        let huge = Data(repeating: 0, count: AudioChunkValidator.maxChunkBytes + 1)
        #expect(!AudioChunkValidator.validate(huge, format: validFormat))
    }

    @Test func chunkValidator_rejectsInvalidSampleRateOrChannelCount() {
        let badFormat = AudioFormatDescriptor(sampleRate: 0, channelCount: 1, sampleFormat: "pcm_s16le", interleaved: true)
        #expect(!AudioChunkValidator.validate(Data(repeating: 0, count: 100), format: badFormat))
    }

    @Test func chunkValidator_rejectsMisalignedSampleData() {
        // 16-bit mono needs an even byte count.
        #expect(!AudioChunkValidator.validate(Data(repeating: 0, count: 7), format: validFormat))
    }

    @Test func chunkValidator_acceptsWellFormedChunk() {
        #expect(AudioChunkValidator.validate(Data(repeating: 0, count: 4800), format: validFormat))
    }

    // MARK: - AudioChunkBuffer (§36/§38)

    @Test func chunkBuffer_enqueueDequeue_roundTrips() {
        let buffer = AudioChunkBuffer()
        let data = Data(repeating: 1, count: 10)
        #expect(buffer.enqueue(data, durationEstimate: 0.1))
        #expect(buffer.dequeue() == data)
    }

    @Test func chunkBuffer_rejectsBeyondByteLimit() {
        let buffer = AudioChunkBuffer(limits: .init(maxQueuedBytes: 100, maxChunkCount: 100, maxQueuedDuration: 100))
        #expect(buffer.enqueue(Data(repeating: 0, count: 90), durationEstimate: 0.1))
        #expect(!buffer.enqueue(Data(repeating: 0, count: 90), durationEstimate: 0.1), "must reject once the byte bound would be exceeded")
    }

    @Test func chunkBuffer_rejectsBeyondChunkCountLimit() {
        let buffer = AudioChunkBuffer(limits: .init(maxQueuedBytes: 1_000_000, maxChunkCount: 2, maxQueuedDuration: 100))
        #expect(buffer.enqueue(Data([1]), durationEstimate: 0.01))
        #expect(buffer.enqueue(Data([2]), durationEstimate: 0.01))
        #expect(!buffer.enqueue(Data([3]), durationEstimate: 0.01))
    }

    @Test func chunkBuffer_rejectsBeyondDurationLimit() {
        let buffer = AudioChunkBuffer(limits: .init(maxQueuedBytes: 1_000_000, maxChunkCount: 100, maxQueuedDuration: 1.0))
        #expect(buffer.enqueue(Data([1]), durationEstimate: 0.6))
        #expect(!buffer.enqueue(Data([2]), durationEstimate: 0.6))
    }

    @Test func chunkBuffer_dequeueOnEmpty_recordsUnderrun_neverCrashes() {
        let buffer = AudioChunkBuffer()
        #expect(buffer.dequeue() == nil)
        #expect(buffer.snapshotUnderrunCount() == 1)
    }

    @Test func chunkBuffer_drain_clearsQueue() {
        let buffer = AudioChunkBuffer()
        _ = buffer.enqueue(Data([1]), durationEstimate: 0.1)
        buffer.drain()
        #expect(buffer.queuedChunkCount == 0)
    }

    // MARK: - LatencyStatistics reuse / SpeechLatencyMetrics (§43)

    @Test func speechLatencyMetrics_onlyReportsWhatWasActuallyMeasured() {
        var metrics = SpeechLatencyMetrics()
        #expect(metrics.timeToFirstAudioByteMs == nil, "unmeasured timestamps must never fabricate a value")
        let start = Date()
        metrics.networkRequestStartedAt = start
        metrics.firstValidAudioByteAt = start.addingTimeInterval(0.05)
        #expect(metrics.timeToFirstAudioByteMs != nil)
        #expect(metrics.timeToFirstAudioByteMs! > 0)
    }

    // MARK: - ProviderCircuitBreaker (§46)

    @Test func circuitBreaker_startsClosedAndAllowsAttempts() {
        let breaker = ProviderCircuitBreaker()
        #expect(breaker.shouldAttempt())
        #expect(breaker.currentState() == .closed)
    }

    @Test func circuitBreaker_opensAfterThresholdTransientFailures() {
        let breaker = ProviderCircuitBreaker(failureThreshold: 2, cooldown: 30)
        breaker.recordFailure(.network)
        #expect(breaker.currentState() == .closed)
        breaker.recordFailure(.network)
        #expect(breaker.currentState() == .open)
        #expect(!breaker.shouldAttempt())
    }

    @Test func circuitBreaker_opensImmediately_onPermanentFailureCategory() {
        let breaker = ProviderCircuitBreaker(failureThreshold: 10, cooldown: 30)
        breaker.recordFailure(.authentication)
        #expect(breaker.currentState() == .open, "auth failures must open the circuit immediately, never wait for a threshold")
    }

    @Test func circuitBreaker_neverTreatsPermanentFailuresAsTransient() {
        #expect(SpeechProviderFailureCategory.authentication.isPermanentUntilReconfigured)
        #expect(SpeechProviderFailureCategory.authorization.isPermanentUntilReconfigured)
        #expect(SpeechProviderFailureCategory.configuration.isPermanentUntilReconfigured)
        #expect(!SpeechProviderFailureCategory.network.isPermanentUntilReconfigured)
        #expect(!SpeechProviderFailureCategory.timeout.isPermanentUntilReconfigured)
    }

    @Test func circuitBreaker_recoversAfterCooldown_toHalfOpen() {
        let breaker = ProviderCircuitBreaker(failureThreshold: 1, cooldown: 10)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        breaker.recordFailure(.network, now: epoch)
        #expect(breaker.currentState() == .open)
        #expect(!breaker.shouldAttempt(now: epoch.addingTimeInterval(1)))
        #expect(breaker.shouldAttempt(now: epoch.addingTimeInterval(11)), "must allow a bounded recovery probe after cooldown")
        #expect(breaker.currentState() == .halfOpen)
    }

    @Test func circuitBreaker_successResetsToClosed() {
        let breaker = ProviderCircuitBreaker(failureThreshold: 1, cooldown: 0.01)
        breaker.recordFailure(.network)
        #expect(breaker.currentState() == .open)
        pump(seconds: 0.02)
        _ = breaker.shouldAttempt() // transitions to halfOpen
        breaker.recordSuccess()
        #expect(breaker.currentState() == .closed)
    }

    // MARK: - SpeechTextNormalizer / PronunciationDictionary / SSMLSafety (§51/§52/§53/§54)

    @Test func textNormalizer_expandsPercentSign() {
        #expect(SpeechTextNormalizer.normalize("3.7%").contains("percent"))
    }

    @Test func textNormalizer_passesThroughUnhandledTextUnchanged() {
        let text = "Done. Your note's ready."
        #expect(SpeechTextNormalizer.normalize(text) == text)
    }

    @Test func textNormalizer_neverChangesTruthWords() {
        // Structural sanity: normalization must never alter the specific
        // truth-boundary words `ResponseValidation` depends on.
        for truthWord in ["Done.", "Completed.", "That didn't go through."] {
            #expect(SpeechTextNormalizer.normalize(truthWord) == truthWord)
        }
    }

    @Test func pronunciationDictionary_findsKnownWord_caseInsensitive() {
        #expect(PronunciationDictionary.override(forWord: "friday")?.respelling == "FRY-day")
        #expect(PronunciationDictionary.override(forWord: "FRIDAY")?.respelling == "FRY-day")
    }

    @Test func pronunciationDictionary_unknownWord_returnsNil() {
        #expect(PronunciationDictionary.override(forWord: "banana") == nil)
    }

    @Test func ssmlSafety_escapesSpecialCharacters() {
        let escaped = SSMLSafety.escape("<speak>&\"'")
        #expect(!escaped.contains("<speak>"))
        #expect(escaped.contains("&lt;"))
        #expect(escaped.contains("&amp;"))
    }

    // MARK: - PremiumSpeechCapabilities.none (§31)

    @Test func capabilitiesNone_reportsNoSupport() {
        let none = PremiumSpeechCapabilities.none
        #expect(!none.streaming && !none.cancellation && !none.ssml && !none.nativeProsody)
        #expect(none.sampleRates.isEmpty)
    }

    // MARK: - PremiumNeuralSpeechSynthesizer (§32/§33/§35/§36/§39/§40/§46) via fake provider

    private func minimalOutcome(_ synth: PremiumNeuralSpeechSynthesizer, text: String = "Hello there") -> [SpeechSynthesisOutcome] {
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak(text, category: .information, onFinished: { outcomes.append($0) })
        return outcomes
    }

    @Test func premiumSynthesizer_unconfigured_throwsImmediately_unchangedFromPriorMilestones() {
        let synth = PremiumNeuralSpeechSynthesizer()
        #expect(throws: PremiumNeuralSpeechSynthesizer.NotConfiguredError.self) {
            try synth.speak("hello", category: .information, onFinished: { _ in })
        }
    }

    @Test func premiumSynthesizer_configuredProvider_successPath_reportsFinished() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .started(interactionID: i, utteranceID: u) }),
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .completed(interactionID: i, utteranceID: u) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        #expect(outcome == .finished)
    }

    @Test func premiumSynthesizer_failureBeforeAnyChunk_reportsFailed_neverInterrupted() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .failed(interactionID: i, utteranceID: u, category: .network) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        // §39: nothing was heard yet -> `.failed` so FallbackSpeechSynthesizer speaks the FULL response via Samantha.
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(String(describing: outcome))") }
    }

    @Test func premiumSynthesizer_failureAfterChunkAccepted_reportsInterrupted_neverFailed() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .failed(interactionID: i, utteranceID: u, category: .streamInterrupted) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        // §39/§40: some audio was already heard -> `.interrupted`, so FallbackSpeechSynthesizer
        // must NEVER retry via Samantha (which would duplicate already-spoken content).
        #expect(outcome == .interrupted)
    }

    @Test func premiumSynthesizer_failureAfterChunk_neverTriggersFallbackReplay_throughFallbackSpeechSynthesizer() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .failed(interactionID: i, utteranceID: u, category: .streamInterrupted) }),
        ]
        let premium = PremiumNeuralSpeechSynthesizer(provider: fake)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premium, secondary: secondary)
        var outcome: SpeechSynthesisOutcome?
        try? fallback.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        #expect(secondary.speakCallCount == 0, "secondary must NEVER be asked to replay content already partially spoken by premium")
        #expect(outcome == .interrupted)
    }

    @Test func premiumSynthesizer_failureBeforeAnyChunk_doesTriggerFallbackReplay_throughFallbackSpeechSynthesizer() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [(0, { i, u in .failed(interactionID: i, utteranceID: u, category: .network) })]
        let premium = PremiumNeuralSpeechSynthesizer(provider: fake)
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: premium, secondary: secondary)
        var outcome: SpeechSynthesisOutcome?
        try? fallback.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        #expect(secondary.speakCallCount == 1, "nothing was heard yet -> secondary SHOULD speak the full response")
        #expect(outcome == .finished)
    }

    @Test func premiumSynthesizer_staleChunk_fromSupersededUtterance_isSilentlyDropped() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.overrideEventIDs = ("stale-interaction", "stale-utterance") // simulates a provider echoing an OLD id
        fake.scriptedEvents = [
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0, { i, u in .completed(interactionID: i, utteranceID: u) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello there", category: .information, onFinished: { outcomes.append($0) })
        #expect(outcomes.isEmpty, "every event carried a stale id (mismatched from the real request) — none should ever reach onFinished")
    }

    @Test func premiumSynthesizer_corruptChunk_rejectedButDoesNotCrashOrFailUtterance() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(), sequence: 0) }), // empty -> rejected by validator
            (0, { i, u in .completed(interactionID: i, utteranceID: u) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcome: SpeechSynthesisOutcome?
        try? synth.speak("Hello there", category: .information, onFinished: { outcome = $0 })
        #expect(outcome == .finished, "a rejected corrupt chunk must not crash or fail the whole utterance")
    }

    @Test func premiumSynthesizer_stop_invalidatesInFlightUtterance_lateEventsIgnored() {
        let fake = FakePremiumSpeechStreamProvider()
        fake.scriptedEvents = [
            (0.05, { i, u in .audioChunk(interactionID: i, utteranceID: u, samples: Data(repeating: 0, count: 4800), sequence: 0) }),
            (0.05, { i, u in .completed(interactionID: i, utteranceID: u) }),
        ]
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake)
        var outcomes: [SpeechSynthesisOutcome] = []
        try? synth.speak("Hello there", category: .information, onFinished: { outcomes.append($0) })
        synth.stop() // invalidate identity BEFORE the delayed events fire
        pump(seconds: 0.15)
        // P2-M5V9-B.2B — a deliberate enrichment, not a regression:
        // `stop()` now GUARANTEES the `SpeechSynthesizing` protocol's own
        // documented contract itself (exactly one `onFinished(.interrupted)`),
        // matching `AVSpeechSynthesizerAdapter.stop()`'s existing,
        // already-correct behavior, instead of silently delivering
        // NOTHING and leaving a caller waiting forever for a callback
        // that would never arrive. The property this test still verifies
        // — the late, PROVIDER-originated `.audioChunk`/`.completed`
        // events for the invalidated utterance are dropped and never
        // reach the caller — still holds: `outcomes` contains ONLY the
        // one interruption `stop()` itself delivered, never `.finished`.
        #expect(outcomes == [.interrupted], "stop() must deliver exactly one .interrupted, and the late provider events for the invalidated utterance must never be additionally applied")
    }

    @Test func premiumSynthesizer_circuitOpen_throwsImmediately_neverAttemptsProvider() {
        let fake = FakePremiumSpeechStreamProvider()
        let breaker = ProviderCircuitBreaker(failureThreshold: 1)
        breaker.recordFailure(.authentication) // opens immediately
        let synth = PremiumNeuralSpeechSynthesizer(provider: fake, circuitBreaker: breaker)
        #expect(throws: PremiumNeuralSpeechSynthesizer.CircuitOpenError.self) {
            try synth.speak("hello", category: .information, onFinished: { _ in })
        }
        #expect(fake.synthesizeCallCount == 0, "an open circuit must skip the network attempt entirely (§66)")
    }

    @Test func premiumSynthesizer_engineIdentifier_reflectsConfigurationState() {
        #expect(PremiumNeuralSpeechSynthesizer().engineIdentifier.contains("not configured"))
        let configured = PremiumNeuralSpeechSynthesizer(provider: FakePremiumSpeechStreamProvider(), voiceProfile: PremiumVoiceProfile(voiceProfileID: "v1", providerID: "test-provider", providerVoiceID: "voice-1", profileVersion: "1"))
        #expect(configured.engineIdentifier.contains("test-provider"))
    }

    // MARK: - §76: provider-neutral swap proof

    @Test func fallbackSpeechSynthesizer_swapsProviders_withoutTouchingCallerLogic() {
        // Proves candidate A, candidate B, and Samantha (a `FakeSpeechSynthesizer`
        // standing in for `AVSpeechSynthesizerAdapter`) are all swappable
        // purely via constructor injection — no caller-side logic differs.
        func run(_ primary: SpeechSynthesizing) -> SpeechSynthesisOutcome? {
            let secondary = FakeSpeechSynthesizer()
            let fallback = FallbackSpeechSynthesizer(primary: primary, secondary: secondary)
            var outcome: SpeechSynthesisOutcome?
            try? fallback.speak("hello", category: .information, onFinished: { outcome = $0 })
            return outcome
        }
        let candidateA = FakePremiumSpeechStreamProvider()
        candidateA.scriptedEvents = [(0, { i, u in .completed(interactionID: i, utteranceID: u) })]
        let candidateB = FakePremiumSpeechStreamProvider()
        candidateB.scriptedEvents = [(0, { i, u in .failed(interactionID: i, utteranceID: u, category: .network) })]
        #expect(run(PremiumNeuralSpeechSynthesizer(provider: candidateA)) == .finished)
        #expect(run(PremiumNeuralSpeechSynthesizer(provider: candidateB)) == .finished) // falls back to Samantha successfully
        #expect(run(PremiumNeuralSpeechSynthesizer()) == .finished) // unconfigured also falls back cleanly
    }
}
