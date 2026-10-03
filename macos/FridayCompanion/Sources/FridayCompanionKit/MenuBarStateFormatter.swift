import Foundation

/// Pure mapping from real Supervisor state to what the menu bar shows —
/// separated from `MenuBarController` (which lives in the executable
/// target and needs AppKit) specifically so the truthfulness property
/// (`docs/PHASE-2-...` P2-M1 §12: "Menu-bar state must reflect actual
/// supervisor/service state... do not display READY unless required
/// services passed readiness checks") is testable without launching a
/// GUI app.
public struct MenuBarDisplay: Equatable {
    public let title: String
    public let detail: String
    /// Whether the "Start/Resume" action should be enabled — true only
    /// when the overall state is `.stopped` or `.failed` (nothing to
    /// stop that's already running/starting).
    public let canStart: Bool
    /// Whether "Stop/Pause" should be enabled — true only when
    /// something is actually running or on its way up.
    public let canStop: Bool
}

public enum MenuBarStateFormatter {
    public static func display(overall: ServiceLifecycleState, perService: [String: ServiceLifecycleState]) -> MenuBarDisplay {
        let title: String
        switch overall {
        case .stopped: title = "FRIDAY ○ Stopped"
        case .starting: title = "FRIDAY ● Starting…"
        case .ready: title = "FRIDAY ● Ready"
        case .degraded: title = "FRIDAY ● Degraded"
        case .restarting: title = "FRIDAY ● Restarting…"
        case .failed: title = "FRIDAY ● Failed"
        case .stopping: title = "FRIDAY ○ Stopping…"
        }

        let detail = perService
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(describe($0.value))" }
            .joined(separator: "\n")

        let canStart = (overall == .stopped || overall == .failed)
        let canStop = !(overall == .stopped)

        return MenuBarDisplay(title: title, detail: detail, canStart: canStart, canStop: canStop)
    }

    private static func describe(_ state: ServiceLifecycleState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .ready: return "ready"
        case .degraded: return "degraded"
        case .restarting: return "restarting"
        case .failed: return "failed"
        case .stopping: return "stopping"
        }
    }
}
