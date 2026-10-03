import Speech
import AVFoundation
import Foundation

/// Real speech-recognition permission (TCC), mirroring
/// `RealMicrophonePermission` exactly — the only file besides
/// `AppleSpeechTranscriber` itself that imports `Speech` for a
/// permission-only concern.
public struct RealSpeechRecognitionPermission: SpeechRecognitionPermissionChecking {
    public init() {}

    public func currentStatus() -> SpeechRecognitionPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> SpeechRecognitionPermissionStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                let mapped: SpeechRecognitionPermissionStatus
                switch status {
                case .authorized: mapped = .authorized
                case .denied: mapped = .denied
                case .restricted: mapped = .restricted
                case .notDetermined: mapped = .notDetermined
                @unknown default: mapped = .denied
                }
                continuation.resume(returning: mapped)
            }
        }
    }
}

/// Real, on-device command transcription via Apple's Speech framework
/// (ADR-008, updated in `docs/W-adr-backlog.md` during P2-M4).
/// `requiresOnDeviceRecognition = true` is set unconditionally — this
/// type has no code path that can upload audio to Apple's servers (P2-M4
/// §6: "must NOT be uploaded"). Feeds directly from the same
/// `AudioFrame` type `RealAudioCaptureEngine` already produces (P2-M4
/// §9: no second, fragile audio pipeline) — samples are converted back
/// to a `Float32` `AVAudioPCMBuffer` (the format `SFSpeechAudioBufferRecognitionRequest`
/// requires) via a pure, unit-testable function, mirroring
/// `RealAudioCaptureEngine.extractSamples(from:)`'s own factoring.
public final class AppleSpeechTranscriber: SpeechTranscribing, @unchecked Sendable {
    public let engineIdentifier: String

    private let recognizer: SFSpeechRecognizer?
    private let diagnostics: WakeDiagnosticsRecorder?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onResult: (@Sendable (SpeechTranscriptionOutcome) -> Void)?
    private var delivered = false
    /// Set by `finishSession()` — once true, `append(_:)` becomes a
    /// no-op (§2 of the P2-M4D instruction: "no additional buffers are
    /// appended afterward").
    private var finished = false

    public init(locale: Locale = Locale(identifier: "en-US"), diagnostics: WakeDiagnosticsRecorder? = nil) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.diagnostics = diagnostics
        self.engineIdentifier = "apple-speech-on-device (\(locale.identifier))"
    }

    public func startSession(onResult: @escaping @Sendable (SpeechTranscriptionOutcome) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechTranscriptionError.engineUnavailable("SFSpeechRecognizer unavailable for the configured locale")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.engineUnavailable("on-device recognition not supported/downloaded for this locale")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true // never upload — P2-M4 §6
        self.request = req
        self.onResult = onResult
        self.delivered = false
        self.finished = false

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handleTaskCallback(result: result, error: error)
        }
    }

    public func append(_ frame: AudioFrame) {
        lock.lock()
        let req = request
        let alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished, let req, let buffer = Self.makeFloat32Buffer(from: frame) else { return }
        req.append(buffer)
        diagnostics?.recordFrameForwardedToSTT()
    }

    /// P2-M4D root-cause fix: `SFSpeechAudioBufferRecognitionRequest` is
    /// a continuous streaming request — it does NOT finalize on its own
    /// from silence in the buffered audio. Without an explicit signal
    /// that input has ended, the recognition task waits indefinitely,
    /// never delivering `result.isFinal == true` and never erroring
    /// either, which is exactly the "0 finalized, 0 failed" symptom the
    /// owner's real hardware test surfaced. `endAudio()` is that signal
    /// — it does NOT itself resolve the session (the already-registered
    /// `recognitionTask` callback still delivers the eventual final
    /// result or error asynchronously), and unlike `cancelSession()` it
    /// does not tear down `task`/`request`/`onResult` or suppress the
    /// callback, so a genuine result can still reach `onResult`.
    public func finishSession() {
        lock.lock()
        finished = true
        let req = request
        lock.unlock()
        req?.endAudio()
    }

    /// Genuine abandonment (user disabled wake, device error) — unlike
    /// `finishSession()`, no result is wanted or expected; `onResult` is
    /// suppressed immediately so a result racing in from the real
    /// recognizer cannot reach a caller who has already moved on.
    public func cancelSession() {
        lock.lock()
        let t = task
        let req = request
        delivered = true // suppress any late callback from still invoking onResult
        finished = true
        task = nil
        request = nil
        onResult = nil
        lock.unlock()
        t?.cancel()
        req?.endAudio()
    }

    private func handleTaskCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            deliverOnce(.failed(String(describing: error)))
            return
        }
        guard let result, result.isFinal else { return }
        deliverOnce(.finalized(result.bestTranscription.formattedString))
    }

    private func deliverOnce(_ outcome: SpeechTranscriptionOutcome) {
        lock.lock()
        guard !delivered, let handler = onResult else { lock.unlock(); return }
        delivered = true
        let capturedHandler = handler
        onResult = nil
        lock.unlock()
        capturedHandler(outcome)
    }

    /// P2-M4 §9 — the exact real conversion boundary, factored out as a
    /// pure, unit-testable function (mirrors
    /// `RealAudioCaptureEngine.extractSamples(from:)`'s own reasoning):
    /// a test can construct a real `AudioFrame` (Int16, whatever real
    /// sample rate the hardware reports — confirmed 48kHz mono Float32
    /// captured-then-converted-to-Int16 on the owner's own Mac) and
    /// verify the resulting `AVAudioPCMBuffer` is well-formed Float32 at
    /// the same rate, without needing Speech-Recognition permission or a
    /// live recognizer at all.
    static func makeFloat32Buffer(from frame: AudioFrame) -> AVAudioPCMBuffer? {
        guard !frame.samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, s) in frame.samples.enumerated() {
            channel[i] = Float(s) / 32768.0
        }
        return buffer
    }
}
