import AVFoundation

/// Real macOS microphone permission (TCC) — the second and last file in
/// `FridayCompanionKit` that touches `AVFoundation` directly. Every
/// caller elsewhere in the kit reasons only about `MicrophonePermissionStatus`.
public struct RealMicrophonePermission: MicrophonePermissionChecking {
    public init() {}

    public func currentStatus() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied // fail closed on an unrecognized future case
        }
    }

    public func requestAccess() async -> MicrophonePermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }
}
