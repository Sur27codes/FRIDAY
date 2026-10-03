import Foundation

/// Provider-independent command-transcription interface (P2-M4 §4) —
/// mirrors `WakeWordDetecting`'s own separation from any specific
/// engine. `WakeCoordinator` depends only on this protocol; a future
/// provider swap (whisper.cpp, sherpa-onnx offline ASR, a cloud
/// fallback) plugs in here without touching the command-capture state
/// machine or any test exercising this protocol via a fake.
///
/// Speech transcription is inherently asynchronous/streaming (frames
/// arrive over time, the engine decides when an utterance is complete),
/// so this is callback-based rather than a single synchronous call —
/// `startSession` registers the one handler invoked exactly once per
/// session with the final outcome.
public protocol SpeechTranscribing: Sendable {
    /// Begins a new transcription session. `onResult` is invoked exactly
    /// once for this session, on an arbitrary thread, when the engine
    /// either finalizes an utterance or fails.
    func startSession(onResult: @escaping @Sendable (SpeechTranscriptionOutcome) -> Void) throws
    /// Feeds one bounded audio frame captured during the session.
    func append(_ frame: AudioFrame)
    /// P2-M4D: tells the engine no more audio is coming and it should
    /// finalize using whatever it has heard so far — the graceful
    /// counterpart to `cancelSession()`. For a streaming engine like
    /// `SFSpeechAudioBufferRecognitionRequest`, silence in the buffered
    /// audio alone does NOT trigger finalization; an explicit signal is
    /// required (`endAudio()`) or the recognition task will wait
    /// indefinitely for more input, never delivering a final result —
    /// this was the actual P2-M4D root cause (see
    /// `docs/E-traceability-matrix.md`'s P2-M4D section). `onResult` is
    /// still expected to fire afterward — this call does not itself
    /// resolve the session, it only signals end-of-input.
    func finishSession()
    /// Ends the session immediately (cancellation/timeout/device error)
    /// without waiting for or expecting a result — `onResult` must NOT
    /// be invoked after this call.
    func cancelSession()
    /// A short, stable identifier for diagnostics (mirrors
    /// `WakeWordDetecting.engineIdentifier`) — never appears near actual
    /// transcript content.
    var engineIdentifier: String { get }
}

public enum SpeechTranscriptionOutcome: Sendable, Equatable {
    /// The engine finalized an utterance. May be empty/whitespace-only
    /// (e.g. background noise briefly opened a session) — validation of
    /// the raw text happens in `WakeCoordinator`/`TranscriptValidation`,
    /// not here.
    case finalized(String)
    case failed(String)
}

public enum SpeechTranscriptionError: Error, Equatable {
    case notAuthorized
    case engineUnavailable(String)
}

/// The macOS Speech-Recognition permission states (`SFSpeechRecognizerAuthorizationStatus`,
/// re-declared here so `FridayCompanionKit` files that only reason about
/// the state don't need to import `Speech` — same pattern as
/// `MicrophonePermissionStatus`/`RealMicrophonePermission`).
public enum SpeechRecognitionPermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public protocol SpeechRecognitionPermissionChecking: Sendable {
    func currentStatus() -> SpeechRecognitionPermissionStatus
    func requestAccess() async -> SpeechRecognitionPermissionStatus
}

/// A transcriber that never produces a result — the P2-M4 analogue of
/// `NullWakeWordDetector`. `startSession` succeeds trivially and
/// `append`/`cancelSession` are no-ops, so a `WakeCoordinator`
/// constructed without a real transcriber (every pre-P2-M4 test, and any
/// future explicitly-disabled-STT configuration) behaves EXACTLY as it
/// did before P2-M4: a wake event fires, `.listening` is entered, and
/// the existing bounded timeout returns to `.wakeOnly` with no
/// transcript ever produced — preserving every P2-M3/P2-M3C/P2-M3D test
/// unchanged by construction, not by special-casing.
public struct NullSpeechTranscriber: SpeechTranscribing {
    public let engineIdentifier = "none (no STT configured)"
    public init() {}
    public func startSession(onResult: @escaping @Sendable (SpeechTranscriptionOutcome) -> Void) throws {}
    public func append(_ frame: AudioFrame) {}
    public func finishSession() {}
    public func cancelSession() {}
}

/// The narrow interface `WakeCoordinator` uses to submit a validated
/// transcript through the EXISTING P2-M2 runtime path (P2-M4 §3/§13) —
/// deliberately just the one method `RuntimeClient` already exposes,
/// so voice input is architecturally incapable of reaching anything
/// `RuntimeClient` itself couldn't already reach (no `executeCapability`,
/// no direct Capability Bus access, nothing new).
public protocol CommandRuntimeSubmitting: Sendable {
    func submitText(_ text: String, requestID: String, correlationID: String) throws -> RuntimeTextResult
}

extension RuntimeClient: CommandRuntimeSubmitting {}

/// Safe default when no real runtime client is wired up — mirrors
/// `NullSpeechTranscriber`'s role. Never reached in practice unless
/// `NullSpeechTranscriber` is also in play (which never produces a
/// transcript to submit), but implemented as a truthful failure rather
/// than a silent success in case that assumption is ever violated.
public struct NullCommandRuntimeSubmitting: CommandRuntimeSubmitting {
    public init() {}
    public func submitText(_ text: String, requestID: String, correlationID: String) throws -> RuntimeTextResult {
        throw RuntimeClientError.transport("no runtime submitter configured")
    }
}
