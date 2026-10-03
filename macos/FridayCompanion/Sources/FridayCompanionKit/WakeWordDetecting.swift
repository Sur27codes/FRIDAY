import Foundation

/// Provider-independent wake-word detection interface (§6 of the P2-M3
/// authorization). Nothing else in `FridayCompanionKit` depends on
/// Porcupine, openWakeWord, or any other specific engine — a real
/// implementation for either (once ADR-007 is unblocked, see
/// `docs/W-adr-backlog.md`) plugs in here without touching
/// `WakeCoordinator`, the state machine, or any test that already
/// exercises this protocol via `FakeWakeWordDetector`.
///
/// A conforming type is expected to be lightweight per call — see
/// `WakeCoordinator`'s doc comment on real-time audio safety (§22): the
/// audio capture callback only enqueues frames; `process(_:)` runs on a
/// separate, non-real-time task.
public protocol WakeWordDetecting: Sendable {
    /// Called once before the first `process(_:)` call for a session.
    func start() throws
    /// Feeds one bounded audio frame. Returns a `WakeEvent` if (and only
    /// if) the configured phrase was detected in this frame — most calls
    /// return `nil`. `sessionID` is supplied by the coordinator so the
    /// resulting event can be attributed to the caller's own session
    /// bookkeeping, not decided by the detector.
    func process(_ frame: AudioFrame, sessionID: String) -> WakeEvent?
    /// Called when detection should stop (mic disabled, mute, shutdown).
    func stop()
    /// A short, stable identifier for audit/observability metadata
    /// (§11: "engine version" is legitimate operational metadata; the
    /// engine never appears anywhere near raw audio content).
    var engineIdentifier: String { get }
}

/// The macOS microphone permission states this milestone must handle
/// truthfully (§12) — a direct mirror of `AVAuthorizationStatus`,
/// re-declared here so `FridayCompanionKit` doesn't need to import
/// `AVFoundation` in files that only reason about the state, not the
/// real API (kept in `RealMicrophonePermission.swift` instead).
public enum MicrophonePermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public protocol MicrophonePermissionChecking: Sendable {
    func currentStatus() -> MicrophonePermissionStatus
    /// Triggers the real macOS permission prompt exactly once per
    /// `.notDetermined` state — callers must not invoke this repeatedly
    /// on an already-decided (`.denied`/`.restricted`) status (§12: "do
    /// not repeatedly hammer permission prompts").
    func requestAccess() async -> MicrophonePermissionStatus
}
