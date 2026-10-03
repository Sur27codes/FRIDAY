import Foundation
@testable import FridayCompanionKit

/// A deterministic fake `AudioCapturing` — the test drives frame
/// delivery explicitly (`deliver(_:)`) rather than depending on real
/// microphone hardware, which this coding environment cannot exercise
/// interactively (`docs/PHASE-2-...` P2-M3 §30/§39 both anticipate this
/// exact gap and ask for deterministic fixtures instead).
final class FakeAudioCapturing: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var shouldFailToStart: AudioCaptureError?

    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void) throws {
        if let shouldFailToStart { throw shouldFailToStart }
        lock.lock()
        self.onFrame = onFrame
        startCallCount += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        onFrame = nil
        stopCallCount += 1
        lock.unlock()
    }

    /// Test-driver hook: deliver one fixture frame as if it arrived from
    /// real hardware.
    func deliver(_ frame: AudioFrame) {
        lock.lock()
        let callback = onFrame
        lock.unlock()
        callback?(frame)
    }

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return onFrame != nil
    }
}

/// A deterministic fake `WakeWordDetecting` — recognizes a fixed "magic"
/// sample value as the wake phrase, so tests can construct synthetic
/// `AudioFrame`s that deterministically do or don't trigger a wake,
/// without any real ML model or recorded speech (`docs/PHASE-2-...`
/// P2-M3 §30: silence/ordinary-speech/noise/near-phrase fixtures are all
/// expressible this way).
final class FakeWakeWordDetector: WakeWordDetecting, @unchecked Sendable {
    static let wakeMarkerSample: Int16 = 32767 // "positive fixture" marker

    let engineIdentifier = "fake-test-detector-v1"
    private let lock = NSLock()
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var processedFrameCount = 0
    var shouldFailToStart: Error?

    func start() throws {
        if let shouldFailToStart { throw shouldFailToStart }
        lock.lock(); startCallCount += 1; lock.unlock()
    }

    func stop() {
        lock.lock(); stopCallCount += 1; lock.unlock()
    }

    func process(_ frame: AudioFrame, sessionID: String) -> WakeEvent? {
        lock.lock(); processedFrameCount += 1; lock.unlock()
        guard frame.samples.first == Self.wakeMarkerSample else { return nil }
        return WakeEvent(
            eventID: UUID().uuidString, sessionID: sessionID, phraseID: "hey_friday",
            detectedAt: frame.capturedAt, source: "wake_word", engine: engineIdentifier, confidence: 0.99
        )
    }
}

/// Fixture constructors matching P2-M3 §30's named scenarios — named
/// functions instead of inline literals so every test reads as "what
/// scenario is this," not "what array of numbers is this."
enum AudioFixtures {
    static func positiveWakePhrase(at date: Date = Date()) -> AudioFrame {
        AudioFrame(samples: [FakeWakeWordDetector.wakeMarkerSample, 100, 200], sampleRate: 16000, channelCount: 1, capturedAt: date)
    }

    static func silence(at date: Date = Date()) -> AudioFrame {
        AudioFrame(samples: [0, 0, 0, 0], sampleRate: 16000, channelCount: 1, capturedAt: date)
    }

    static func ordinarySpeech(at date: Date = Date()) -> AudioFrame {
        AudioFrame(samples: [120, -85, 340, -220, 90], sampleRate: 16000, channelCount: 1, capturedAt: date)
    }

    static func noise(at date: Date = Date()) -> AudioFrame {
        AudioFrame(samples: (0..<8).map { _ in Int16.random(in: -500...500) }, sampleRate: 16000, channelCount: 1, capturedAt: date)
    }
}

/// A deterministic fake `MicrophonePermissionChecking`.
final class FakeMicrophonePermission: MicrophonePermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var status: MicrophonePermissionStatus
    private(set) var requestAccessCallCount = 0

    init(status: MicrophonePermissionStatus) {
        self.status = status
    }

    func currentStatus() -> MicrophonePermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func requestAccess() async -> MicrophonePermissionStatus {
        // The actual lock-protected mutation is a plain synchronous
        // helper — calling `NSLock.lock()/unlock()` directly inside an
        // `async` function body is flagged (correctly) by newer Swift
        // concurrency checking, so the critical section is isolated in
        // `resolveRequestSynchronously()` instead, called from here.
        resolveRequestSynchronously()
    }

    private func resolveRequestSynchronously() -> MicrophonePermissionStatus {
        lock.lock(); defer { lock.unlock() }
        requestAccessCallCount += 1
        // Simulate the real OS prompt resolving to `.authorized` unless
        // the test pre-set a specific denial outcome.
        if status == .notDetermined { status = .authorized }
        return status
    }

    func setStatus(_ newStatus: MicrophonePermissionStatus) {
        lock.lock(); status = newStatus; lock.unlock()
    }
}

/// A deterministic fake `SpeechTranscribing` — a test triggers the
/// result explicitly via `simulateResult(_:)` rather than depending on a
/// real recognizer, exactly the same "control the moment, not the
/// mechanism" pattern `FakeWakeWordDetector`/`FakeAudioCapturing`
/// already establish. `cancelSession()` clears the stored handler so a
/// `simulateResult` call after cancellation is a provable no-op —
/// mirroring `AppleSpeechTranscriber`'s own `delivered` guard.
final class FakeSpeechTranscriber: SpeechTranscribing, @unchecked Sendable {
    let engineIdentifier = "fake-test-transcriber-v1"
    private let lock = NSLock()
    private var onResult: (@Sendable (SpeechTranscriptionOutcome) -> Void)?
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var appendedFrameCount = 0
    private(set) var appendedFrameCountAfterFinish = 0
    var shouldFailToStart: Error?

    func startSession(onResult: @escaping @Sendable (SpeechTranscriptionOutcome) -> Void) throws {
        if let shouldFailToStart { throw shouldFailToStart }
        lock.lock()
        self.onResult = onResult
        startCallCount += 1
        lock.unlock()
    }

    func append(_ frame: AudioFrame) {
        lock.lock()
        appendedFrameCount += 1
        if finishCallCount > 0 { appendedFrameCountAfterFinish += 1 }
        lock.unlock()
    }

    /// Mirrors `AppleSpeechTranscriber.finishSession()` exactly: does
    /// NOT clear `onResult` — a real/simulated result can still arrive
    /// afterward, asynchronously, exactly as production behaves.
    func finishSession() {
        lock.lock(); finishCallCount += 1; lock.unlock()
    }

    func cancelSession() {
        lock.lock()
        cancelCallCount += 1
        onResult = nil
        lock.unlock()
    }

    /// Test-driver hook: deliver a scripted outcome as if the real
    /// engine had produced it. A no-op if the session was already
    /// cancelled or never started.
    func simulateResult(_ outcome: SpeechTranscriptionOutcome) {
        lock.lock()
        let handler = onResult
        lock.unlock()
        handler?(outcome)
    }

    var isSessionActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return onResult != nil
    }
}

/// A deterministic fake `SpeechSynthesizing` — a test triggers the
/// outcome explicitly via `simulateFinished()`/`simulateFailure(_:)`
/// rather than depending on real audio hardware, the same "control the
/// moment, not the mechanism" pattern `FakeSpeechTranscriber` already
/// establishes for STT. `stop()` delivers `.interrupted` itself (mirrors
/// `AVSpeechSynthesizerAdapter.stop()`'s real behavior) so barge-in/Stop/
/// disable tests can drive it exactly like the production adapter would
/// behave.
final class FakeSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    let engineIdentifier = "fake-test-synthesizer-v1"
    private let lock = NSLock()
    private var onFinished: (@Sendable (SpeechSynthesisOutcome) -> Void)?
    private var delivered = false
    private(set) var speakCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var spokenTexts: [String] = []
    /// P2-M5V: the prosody category passed with each `speak` call, in
    /// order — lets tests prove `WakeCoordinator` threads
    /// `SpokenResponse.category` through to the engine correctly.
    private(set) var spokenCategories: [SpeechResponseCategory] = []
    var shouldFailToStart: Error?
    /// When true, `speak` never calls back on its own — the test drives
    /// completion explicitly via `simulateFinished()`/`simulateFailure(_:)`/
    /// `stop()`. Defaults to auto-finishing synchronously (like
    /// `NullSpeechSynthesizer`) so tests that don't care about timing
    /// don't need to remember to resolve it.
    var autoFinish = true

    func speak(_ text: String, category: SpeechResponseCategory, onFinished handler: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        if let shouldFailToStart { throw shouldFailToStart }
        lock.lock()
        speakCallCount += 1
        spokenTexts.append(text)
        spokenCategories.append(category)
        onFinished = handler
        delivered = false
        let shouldAutoFinish = autoFinish
        lock.unlock()
        if shouldAutoFinish {
            deliverOnce(.finished)
        }
    }

    func stop() {
        lock.lock(); stopCallCount += 1; lock.unlock()
        deliverOnce(.interrupted)
    }

    func simulateFinished() {
        deliverOnce(.finished)
    }

    func simulateFailure(_ reason: String) {
        deliverOnce(.failed(reason))
    }

    /// Test-only: leaves the session "in flight" (never calls back at
    /// all) — for exercising `WakeCoordinator`'s own safety-net timeout.
    func neverCallBack() {
        lock.lock(); autoFinish = false; lock.unlock()
    }

    private func deliverOnce(_ outcome: SpeechSynthesisOutcome) {
        lock.lock()
        guard !delivered, let handler = onFinished else { lock.unlock(); return }
        delivered = true
        onFinished = nil
        lock.unlock()
        handler(outcome)
    }

    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return onFinished != nil
    }
}

/// A deterministic fake `CommandRuntimeSubmitting` — records every
/// submission and returns/throws a scripted outcome, so
/// `WakeCoordinator`'s runtime-submission orchestration is testable
/// without a real `friday-daemon` process (the real, unmodified
/// `RuntimeClient` is exercised separately, for real, in
/// `VoiceCommandRealEndToEndTests`).
final class FakeCommandRuntimeSubmitting: CommandRuntimeSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var submittedTexts: [String] = []
    private(set) var submittedRequestIDs: [String] = []
    var resultToReturn: RuntimeTextResult?
    var errorToThrow: Error?

    func submitText(_ text: String, requestID: String, correlationID: String) throws -> RuntimeTextResult {
        lock.lock()
        submittedTexts.append(text)
        submittedRequestIDs.append(requestID)
        let result = resultToReturn
        let error = errorToThrow
        lock.unlock()
        if let error { throw error }
        return result ?? RuntimeTextResult(protocolVersion: 1, requestID: requestID, correlationID: correlationID, taskID: "task-fake", outcome: "SUCCESS", text: "fake result")
    }
}
