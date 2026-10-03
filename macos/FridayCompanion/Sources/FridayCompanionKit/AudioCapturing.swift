import Foundation

/// Bounded PCM frame delivery, abstracted so `WakeCoordinator`'s
/// state-machine logic can be tested deterministically (with a fake
/// implementation replaying fixture frames) independently of real
/// microphone hardware, which this coding environment cannot exercise
/// interactively (§39 of the P2-M3 authorization already anticipates
/// this: real-microphone acceptance is a separate, owner-run step).
public protocol AudioCapturing: Sendable {
    /// Starts capture, invoking `onFrame` once per bounded frame. The
    /// callback MUST remain lightweight (§22: no blocking I/O, no
    /// network, no database work) — a real implementation calls it
    /// directly from (or immediately adjacent to) the real-time audio
    /// callback, so heavy work (the wake detector's own `process(_:)`)
    /// belongs downstream of this callback, not inside it.
    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void) throws
    func stop()
}

public enum AudioCaptureError: Error, Equatable {
    case engineStartFailed(String)
    case noInputDeviceAvailable
}
