import Foundation

/// P2-M5V9-B.2 §15 — a minimal, honest mirror of the power states macOS
/// actually exposes (`ProcessInfo.isLowPowerModeEnabled`, battery/AC
/// state), kept as this codebase's own small enum rather than depending
/// on IOKit power-source APIs directly from this pure policy type — a
/// caller (future wiring, out of this milestone's bounded scope per §28)
/// maps real system state into this enum at one boundary.
public enum DevicePowerState: Sendable, Equatable {
    case acPower
    case battery
    case lowPowerMode
    case criticalBattery
}

/// Which local/remote speech backend a given power state should prefer.
/// Never a THIRD, competing decision authority over `SpeechLanguageRouter`'s
/// own provider choice — this only narrows which LOCAL Chatterbox variant
/// (if any) is appropriate, and separately says when Cartesia (remote,
/// power-cheap-on-device) is preferable to a heavy local model.
public enum LocalModelBackend: Sendable, Equatable {
    case cartesia
    case chatterboxTurbo
    case chatterboxNano
    case chatterboxMultilingual
}

/// §15's own policy table, reproduced as pure, deterministic, testable
/// logic — never a background poller (§15: "do not continuously poll...
/// use event-driven state changes"): `recommendedBackend` is a pure
/// function callers invoke ON a real state-change event, and
/// `shouldUnload` is a pure function checked against the model's own
/// last-use timestamp when such an event fires — no timer/loop lives
/// inside this type itself.
public struct LocalModelLifecyclePolicy: Sendable {
    /// How long a heavy local model may stay warm after its last use
    /// before this policy recommends releasing it (§15: "add a
    /// configurable model idle timeout... after inactivity, release
    /// heavy local model resources").
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 120) {
        self.idleTimeout = idleTimeout
    }

    /// §15's table:
    /// - AC power: local Turbo/Multilingual may run (only reached when
    ///   privacy actually requires local — Cartesia otherwise, since
    ///   remote inference keeps FRIDAY's OWN device work minimal).
    /// - Battery: prefer Cartesia when allowed; Nano (never Multilingual)
    ///   when local is required.
    /// - Low power mode: avoid the large multilingual model regardless;
    ///   Nano or cloud only.
    /// - Critical battery: the minimal path either way — Nano if local
    ///   is required, Cartesia otherwise. Never Turbo/Multilingual.
    public func recommendedBackend(powerState: DevicePowerState, privacyModeOnly: Bool) -> LocalModelBackend {
        switch powerState {
        case .acPower:
            return privacyModeOnly ? .chatterboxTurbo : .cartesia
        case .battery, .lowPowerMode, .criticalBattery:
            return privacyModeOnly ? .chatterboxNano : .cartesia
        }
    }

    /// Whether a currently-warm local model should be released given how
    /// long it has sat idle since its last real use.
    public func shouldUnload(lastUsedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUsedAt) >= idleTimeout
    }
}
