import Foundation

/// A detector that never fires. Before P2-M3C this was the shipped
/// default while ADR-007 (local wake-word engine) was BLOCKED on
/// licensing/credential evidence — see `docs/W-adr-backlog.md` for that
/// history. ADR-007 is now RESOLVED FOR LOCAL DEVELOPMENT
/// (`SherpaOnnxWakeWordDetector` is the shipped default, wired in
/// `AppDelegate`), so this type's only remaining legitimate uses are:
/// tests (`FakeWakeWordDetector` is usually a better fit, but this is
/// available too), explicitly wake-disabled configurations, deterministic
/// developer fixtures, and `AppDelegate`'s own fallback if the vendored
/// model resource cannot be loaded. It must never be reintroduced as the
/// normal shipped default while the app claims "Hey Friday" support.
public struct NullWakeWordDetector: WakeWordDetecting {
    public let engineIdentifier = "none (wake disabled or model unavailable — see docs/W-adr-backlog.md)"

    public init() {}
    public func start() throws {}
    public func stop() {}
    public func process(_ frame: AudioFrame, sessionID: String) -> WakeEvent? { nil }
}
