import Foundation

/// P2-M5V9 §41 — what has ACTUALLY happened to one chunk/sentence, kept
/// separate from provider-generation state (§42: "provider completion !=
/// audible completion" — `.completed` synthesis does not by itself imply
/// `.played`).
public enum ChunkPlaybackState: Sendable, Equatable {
    case queued
    case playing
    case completed
    case cancelled
    case failed
}

/// P2-M5V9 §33 — before accepting EVERY streamed chunk, verify it still
/// belongs to the CURRENT interaction/utterance. A provider returning
/// stale audio after cancellation/barge-in/a new interaction/disable/
/// route-change/shutdown must never be played — this type is the one
/// place that check happens, so it can never be forgotten at a new call
/// site.
public final class UtteranceIdentityGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var currentInteractionID: String?
    private var currentUtteranceID: String?

    public init() {}

    /// Called once when a NEW utterance begins — supersedes whatever was
    /// current before, so any chunk tagged with the OLD id is
    /// subsequently rejected automatically.
    public func begin(interactionID: String, utteranceID: String) {
        lock.lock(); defer { lock.unlock() }
        currentInteractionID = interactionID
        currentUtteranceID = utteranceID
    }

    /// Called on cancellation/disable/shutdown/route-change — clears
    /// identity entirely, so EVERY subsequent chunk (even one that would
    /// have matched by ID) is rejected until a new `begin` call.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        currentInteractionID = nil
        currentUtteranceID = nil
    }

    /// §33/§21 adversarial contract: returns `true` only when BOTH ids
    /// exactly match the currently active utterance.
    public func isCurrent(interactionID: String, utteranceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentInteractionID == interactionID && currentUtteranceID == utteranceID
    }
}

/// P2-M5V9 §35 — validated before ANY chunk is queued for playback.
/// Never "repairs" a corrupt chunk and plays it anyway (§65's own rule,
/// applied here at the format-validation boundary too) — a violation is
/// simply rejected.
public enum AudioChunkValidator {
    /// A conservative, explicit sanity bound — no single streamed chunk
    /// should represent more than ~10 seconds of 48kHz 16-bit mono audio
    /// (≈960,000 bytes); anything larger reads as a malformed/adversarial
    /// payload rather than a real incremental chunk, and is rejected
    /// rather than trusted (§35: "unbounded audio chunk" is an explicit
    /// required-rejection case).
    public static let maxChunkBytes = 1_000_000

    public static func validate(_ samples: Data, format: AudioFormatDescriptor) -> Bool {
        guard !samples.isEmpty else { return false } // §35: "empty payload masquerading as success"
        guard samples.count <= maxChunkBytes else { return false }
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        // PCM data must be a whole number of samples for its declared
        // format — a truncated/misaligned buffer is corrupt, not
        // "close enough."
        let bytesPerSample = format.sampleFormat.contains("s16") ? 2 : (format.sampleFormat.contains("f32") ? 4 : 0)
        guard bytesPerSample > 0, samples.count % (bytesPerSample * format.channelCount) == 0 else { return false }
        return true
    }
}

/// P2-M5V9 §36 — bounded backpressure: network synthesis must never
/// accumulate unlimited audio if playback is slower than generation.
/// When a limit is reached, `enqueue` returns `false` (backpressure
/// signal) rather than growing memory without bound — the caller (a
/// provider adapter) is expected to pause requesting more audio, or, if
/// it cannot, treat this as `.streamInterrupted` and fail safely (§36:
/// "apply backpressure or fail safely. Never grow memory without
/// bound").
public final class AudioChunkBuffer: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public let maxQueuedBytes: Int
        public let maxChunkCount: Int
        public let maxQueuedDuration: TimeInterval

        public init(maxQueuedBytes: Int = 5_000_000, maxChunkCount: Int = 64, maxQueuedDuration: TimeInterval = 10.0) {
            self.maxQueuedBytes = maxQueuedBytes
            self.maxChunkCount = maxChunkCount
            self.maxQueuedDuration = maxQueuedDuration
        }
    }

    private let lock = NSLock()
    private let limits: Limits
    private var queue: [(data: Data, durationEstimate: TimeInterval)] = []
    private(set) var underrunCount = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.reduce(0) { $0 + $1.data.count }
    }

    public var queuedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    /// Returns `false` (rejected — apply backpressure) if enqueueing
    /// `data` would exceed ANY of the configured bounds.
    @discardableResult
    public func enqueue(_ data: Data, durationEstimate: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let projectedBytes = queue.reduce(0) { $0 + $1.data.count } + data.count
        let projectedDuration = queue.reduce(0) { $0 + $1.durationEstimate } + durationEstimate
        guard queue.count < limits.maxChunkCount, projectedBytes <= limits.maxQueuedBytes, projectedDuration <= limits.maxQueuedDuration else {
            return false
        }
        queue.append((data, durationEstimate))
        return true
    }

    public func dequeue() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else {
            underrunCount += 1 // §38: record every time playback asks for audio that isn't there yet
            return nil
        }
        return queue.removeFirst().data
    }

    public func drain() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
    }

    /// P2-M5V9-B.3C — removes and returns every queued chunk concatenated,
    /// in order, as one contiguous buffer. Used by `PremiumNeuralSpeechSynthesizer`
    /// to hand a provider's full accumulated utterance to `PCMAudioPlaying`
    /// once generation completes — the same "accumulate then play" shape
    /// `LocalChatterboxSpeechSynthesizer` already uses for Chatterbox
    /// (P2-M5V9-B.3B), reused here rather than building a second,
    /// competing playback-assembly mechanism.
    public func drainAllConcatenated() -> Data {
        lock.lock(); defer { lock.unlock() }
        var combined = Data()
        for item in queue { combined.append(item.data) }
        queue.removeAll()
        return combined
    }

    public func snapshotUnderrunCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return underrunCount
    }
}

/// P2-M5V9 §43 — every named timestamp §43 requires, all optional (only
/// set once genuinely observed) so a partial/failed utterance still
/// reports whatever it legitimately measured, never a fabricated zero.
public struct SpeechLatencyMetrics: Sendable, Equatable {
    public var requestCreatedAt: Date?
    public var networkRequestStartedAt: Date?
    public var firstResponseByteAt: Date?
    public var firstValidAudioByteAt: Date?
    public var firstDecodedFrameAt: Date?
    public var firstFrameQueuedAt: Date?
    public var firstFrameSubmittedToDeviceAt: Date?
    public var firstAudibleEstimateAt: Date?
    public var lastProviderAudioReceivedAt: Date?
    public var lastAudioPlayedAt: Date?
    public var utteranceCompletedAt: Date?

    public init() {}

    private func ms(_ from: Date?, _ to: Date?) -> Double? {
        guard let from, let to else { return nil }
        return to.timeIntervalSince(from) * 1000
    }

    /// §43: "TTFB" — time to first (response) byte.
    public var timeToFirstResponseByteMs: Double? { ms(networkRequestStartedAt, firstResponseByteAt) }
    public var timeToFirstAudioByteMs: Double? { ms(networkRequestStartedAt, firstValidAudioByteAt) }
    public var timeToFirstPlayableFrameMs: Double? { ms(networkRequestStartedAt, firstFrameQueuedAt) }
    public var timeToFirstAudibleOutputMs: Double? { ms(networkRequestStartedAt, firstAudibleEstimateAt) }
    public var totalSynthesisTimeMs: Double? { ms(networkRequestStartedAt, lastProviderAudioReceivedAt) }
    public var totalPlaybackTimeMs: Double? { ms(firstFrameSubmittedToDeviceAt, lastAudioPlayedAt) }
}

/// P2-M5V9 §46 — a bounded circuit breaker so a failing premium provider
/// is never hammered on every utterance. Permanent-until-reconfigured
/// failures (`SpeechProviderFailureCategory.isPermanentUntilReconfigured`)
/// open the circuit IMMEDIATELY (§46: "do not treat authentication/
/// configuration failures as transient") rather than waiting for the
/// usual failure-count threshold.
public final class ProviderCircuitBreaker: @unchecked Sendable {
    public enum State: Sendable, Equatable { case closed, open, halfOpen }

    private let lock = NSLock()
    private var state: State = .closed
    private var consecutiveFailures = 0
    private var openedAt: Date?
    private let failureThreshold: Int
    private let cooldown: TimeInterval

    public init(failureThreshold: Int = 3, cooldown: TimeInterval = 30.0) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    /// Whether a new request should even be attempted right now. A
    /// `.halfOpen` transition (one bounded recovery probe after cooldown)
    /// happens here, not via a separate timer — checked lazily on the
    /// next actual attempt, per §46's own "after cooldown, perform a
    /// bounded recovery probe."
    public func shouldAttempt(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed, .halfOpen: return true
        case .open:
            guard let openedAt, now.timeIntervalSince(openedAt) >= cooldown else { return false }
            state = .halfOpen
            return true
        }
    }

    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        openedAt = nil
    }

    public func recordFailure(_ category: SpeechProviderFailureCategory, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if category.isPermanentUntilReconfigured {
            state = .open
            openedAt = now
            return
        }
        consecutiveFailures += 1
        if state == .halfOpen || consecutiveFailures >= failureThreshold {
            state = .open
            openedAt = now
            consecutiveFailures = 0
        }
    }

    public func currentState() -> State {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}
