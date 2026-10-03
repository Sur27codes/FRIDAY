import Foundation

/// P2-PROD-BOOTSTRAP §B11 — one normalized status shape shared by every
/// permission this coordinator reports, so callers (setup UI, health
/// snapshot) never branch on a permission-specific enum directly.
public enum CoordinatedPermissionState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
    /// Denied/restricted in a way the user can only fix by opening
    /// System Settings themselves — distinguished from plain `denied`
    /// so a setup UI can show a "Open System Settings" action rather
    /// than a re-request button that TCC will silently ignore.
    case requiresSystemSettings

    fileprivate init(microphone status: MicrophonePermissionStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied: self = .requiresSystemSettings
        case .restricted: self = .restricted
        }
    }

    fileprivate init(speechRecognition status: SpeechRecognitionPermissionStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied: self = .requiresSystemSettings
        case .restricted: self = .restricted
        }
    }
}

public struct PermissionSnapshot: Sendable, Equatable {
    public let microphone: CoordinatedPermissionState
    public let speechRecognition: CoordinatedPermissionState

    public init(microphone: CoordinatedPermissionState, speechRecognition: CoordinatedPermissionState) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }

    /// Whether FRIDAY can actually operate its wake→STT pipeline at all
    /// right now — both permissions must be genuinely granted. Never
    /// true merely because neither has been explicitly denied yet.
    public var readyForVoice: Bool {
        microphone == .granted && speechRecognition == .granted
    }
}

/// P2-PROD-BOOTSTRAP §B11 — aggregates the TWO existing, already-real
/// permission checkers (`MicrophonePermissionChecking`/
/// `SpeechRecognitionPermissionChecking`, both pre-existing from P2-M3/
/// P2-M4) into one queryable snapshot. Never claims permission success
/// unless the underlying system API reports it — this type performs NO
/// permission logic of its own beyond normalizing the two existing
/// enums into `CoordinatedPermissionState`.
public struct PermissionCoordinator: Sendable {
    private let microphone: MicrophonePermissionChecking
    private let speechRecognition: SpeechRecognitionPermissionChecking

    public init(microphone: MicrophonePermissionChecking, speechRecognition: SpeechRecognitionPermissionChecking) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }

    public func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: CoordinatedPermissionState(microphone: microphone.currentStatus()),
            speechRecognition: CoordinatedPermissionState(speechRecognition: speechRecognition.currentStatus())
        )
    }

    /// Requests both permissions (each underlying checker decides
    /// whether a request is actually needed/possible given its current
    /// state — e.g. a real `notDetermined` triggers the system prompt;
    /// an already-`denied` status is NOT re-prompted, matching TCC's
    /// own behavior, never faked into looking like a fresh prompt).
    public func requestAll() async -> PermissionSnapshot {
        let micStatus = await microphone.requestAccess()
        let speechStatus = await speechRecognition.requestAccess()
        return PermissionSnapshot(
            microphone: CoordinatedPermissionState(microphone: micStatus),
            speechRecognition: CoordinatedPermissionState(speechRecognition: speechStatus)
        )
    }
}
