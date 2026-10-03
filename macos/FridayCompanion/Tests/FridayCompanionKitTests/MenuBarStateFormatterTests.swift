import Testing
@testable import FridayCompanionKit

/// P2M1-UI-001 / P2M1-UI-002: the menu bar must never claim readiness
/// (or any other state) it hasn't actually reached.
@Suite struct MenuBarStateFormatterTests {

    @Test func ui001_readyDisplay_onlyWhenOverallIsActuallyReady() {
        let ready = MenuBarStateFormatter.display(overall: .ready, perService: ["a": .ready, "b": .ready])
        #expect(ready.title.contains("Ready"))

        for state: ServiceLifecycleState in [.stopped, .starting, .degraded, .restarting, .failed, .stopping] {
            let display = MenuBarStateFormatter.display(overall: state, perService: ["a": .ready, "b": state])
            #expect(!display.title.contains("● Ready"), "state \(state) must not render as Ready")
        }
    }

    @Test func ui002_degradedAndFailedStates_displayedTruthfully_notAsReadyOrGeneric() {
        let degraded = MenuBarStateFormatter.display(overall: .degraded, perService: ["a": .ready, "b": .degraded])
        #expect(degraded.title.contains("Degraded"))
        #expect(degraded.detail.contains("degraded"))

        let failed = MenuBarStateFormatter.display(overall: .failed, perService: ["a": .ready, "b": .failed])
        #expect(failed.title.contains("Failed"))
        #expect(failed.detail.contains("failed"))
    }

    @Test func startStopButtonEnablement_matchesActualState() {
        let stopped = MenuBarStateFormatter.display(overall: .stopped, perService: [:])
        #expect(stopped.canStart)
        #expect(!stopped.canStop)

        let ready = MenuBarStateFormatter.display(overall: .ready, perService: [:])
        #expect(!ready.canStart)
        #expect(ready.canStop)

        let failed = MenuBarStateFormatter.display(overall: .failed, perService: [:])
        #expect(failed.canStart, "Start/Resume must be available to retry from a failed state")
        #expect(failed.canStop, "Stop must remain available in case a child process is still lingering")
    }
}
