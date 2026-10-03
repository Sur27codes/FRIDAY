import Testing
@testable import FridayCompanionKit
import Foundation

/// Pure state-machine tests — no real time elapses, since `now` is
/// injected. Covers the restart-budget/backoff correctness that's
/// cheapest to get subtly wrong and most valuable to test exhaustively
/// (P2M1-SUP-005, P2M1-SUP-006, and the intentional-stop-vs-crash
/// disambiguation behind P2M1-SUP-007).
@Suite struct SupervisorEngineTests {

    // MARK: - Health interpretation

    @Test func healthCheckSucceeded_readyTrue_transitionsToReady() {
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .starting)
        let (next, action) = engine.transition(state: state, event: .healthCheckSucceeded(DaemonHealth(alive: true, ready: true)))
        #expect(next.lifecycle == .ready)
        #expect(action == .none)
    }

    @Test func healthCheckSucceeded_aliveButNotReady_staysStarting_notReady() {
        // P2M1-SEC-003: a not-yet-ready response must never become
        // `.ready` — "Policy unavailable never creates permissive
        // fallback," restated at the state-machine level.
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .starting)
        let (next, _) = engine.transition(state: state, event: .healthCheckSucceeded(DaemonHealth(alive: true, ready: false)))
        #expect(next.lifecycle == .starting)
        #expect(next.lifecycle != .ready)
    }

    @Test func wasReady_thenHealthCheckFails_becomesDegraded_notFailed() {
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .ready)
        let (next, _) = engine.transition(state: state, event: .healthCheckFailed)
        #expect(next.lifecycle == .degraded)
    }

    @Test func startupTimedOut_whileStarting_becomesFailed() {
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .starting)
        let (next, _) = engine.transition(state: state, event: .startupTimedOut)
        #expect(next.lifecycle == .failed)
    }

    @Test func startupTimedOut_whileAlreadyReady_isANoOp() {
        // A stale timer firing after the service already became ready
        // must not regress its state.
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .ready)
        let (next, _) = engine.transition(state: state, event: .startupTimedOut)
        #expect(next.lifecycle == .ready)
    }

    // MARK: - Intentional stop vs. crash (P2M1-SUP-007)

    @Test func stopRequested_setsIntentionalFlag_andRequestsTermination() {
        let engine = SupervisorEngine()
        let state = ServiceRuntimeState(lifecycle: .ready)
        let (next, action) = engine.transition(state: state, event: .stopRequested)
        #expect(next.lifecycle == .stopping)
        #expect(next.intentionalStop)
        #expect(action == .terminateProcess)
    }

    @Test func processExited_afterIntentionalStop_becomesStopped_notRestarting() {
        let engine = SupervisorEngine()
        var state = ServiceRuntimeState(lifecycle: .ready)
        (state, _) = engine.transition(state: state, event: .stopRequested)
        let (next, action) = engine.transition(state: state, event: .processExited)
        #expect(next.lifecycle == .stopped)
        #expect(!next.intentionalStop, "flag should be cleared once consumed")
        #expect(action == .none, "an intentional stop must never schedule a restart")
    }

    @Test func processExited_withoutStopRequested_isTreatedAsCrash_schedulesRestart() {
        let engine = SupervisorEngine(policy: .standard, now: { Date() })
        let state = ServiceRuntimeState(lifecycle: .ready)
        let (next, action) = engine.transition(state: state, event: .processExited)
        #expect(next.lifecycle == .restarting)
        if case .scheduleRestart(let delay) = action {
            #expect(delay == 1.0, "first restart attempt uses the policy's base delay")
        } else {
            Issue.record("expected .scheduleRestart, got \(action)")
        }
    }

    // MARK: - Bounded backoff / no tight crash loop (P2M1-SUP-005, P2M1-SUP-006)

    @Test func repeatedCrashes_backoffDelayGrowsExponentially_thenCaps() {
        let engine = SupervisorEngine(policy: RestartPolicy(baseDelay: 1, maxDelay: 8, maxAttempts: 10, attemptWindow: 3600), now: { Date() })
        var state = ServiceRuntimeState(lifecycle: .ready)
        var delays: [TimeInterval] = []

        for _ in 0..<5 {
            let (next, action) = engine.transition(state: state, event: .processExited)
            state = next
            state.lifecycle = .ready // simulate the restart succeeding before the next crash
            if case .scheduleRestart(let d) = action { delays.append(d) }
        }

        #expect(delays == [1, 2, 4, 8, 8], "delay should double each attempt, capped at maxDelay")
    }

    @Test func repeatedCrashes_exceedingMaxAttempts_withinWindow_becomesFailed_notRestarting() {
        let policy = RestartPolicy(baseDelay: 1, maxDelay: 30, maxAttempts: 3, attemptWindow: 3600)
        let engine = SupervisorEngine(policy: policy, now: { Date() })
        var state = ServiceRuntimeState(lifecycle: .ready)

        var lastAction: SupervisorAction = .none
        for _ in 0..<4 {
            let (next, action) = engine.transition(state: state, event: .processExited)
            state = next
            lastAction = action
            // Simulate "the restart succeeded" only when the engine
            // actually scheduled one — once it returns `.failed` there
            // is no restart in flight to have succeeded, and clobbering
            // that back to `.ready` would hide the very budget-exhaustion
            // behavior this test exists to check.
            if state.lifecycle == .restarting { state.lifecycle = .ready }
        }

        #expect(state.lifecycle == .failed, "the 4th crash within the window must exhaust the budget")
        #expect(lastAction == .none, "no further restart may be scheduled once the budget is exhausted")
    }

    @Test func crashOutsideAttemptWindow_doesNotCountTowardBudget() {
        final class Box: @unchecked Sendable { var value: Date; init(_ v: Date) { value = v } }
        let box = Box(Date())
        let now: @Sendable () -> Date = { box.value }
        let policy = RestartPolicy(baseDelay: 1, maxDelay: 30, maxAttempts: 2, attemptWindow: 10)
        let engine = SupervisorEngine(policy: policy, now: now)
        var state = ServiceRuntimeState(lifecycle: .ready)

        // Two crashes back to back, right at the budget edge. Only the
        // FIRST is simulated as "restart succeeded" — the second's
        // resulting state is what the assertion below actually checks,
        // so it must not be overwritten before that check.
        var (next1, _) = engine.transition(state: state, event: .processExited)
        next1.lifecycle = .ready
        state = next1
        let (next2, _) = engine.transition(state: state, event: .processExited)
        state = next2
        #expect(state.lifecycle == .restarting, "still within budget after exactly maxAttempts crashes")

        // Jump well past the attempt window — old attempts should be pruned.
        box.value = box.value.addingTimeInterval(3600)
        let (next, action) = engine.transition(state: state, event: .processExited)
        #expect(next.lifecycle == .restarting, "a crash after the window resets, should not immediately fail")
        if case .scheduleRestart = action {} else { Issue.record("expected a restart to still be scheduled") }
    }

    // MARK: - Overall (system-wide) readiness (P2M1-SUP-001)

    @Test func overallState_requiresEveryMandatoryServiceReady() {
        #expect(overallState(mandatoryStates: [.ready, .ready]) == .ready)
        #expect(overallState(mandatoryStates: [.ready, .starting]) == .starting)
        #expect(overallState(mandatoryStates: [.ready, .failed]) == .failed)
        #expect(overallState(mandatoryStates: [.ready, .degraded]) == .degraded)
        #expect(overallState(mandatoryStates: [.stopped, .stopped]) == .stopped)
        #expect(overallState(mandatoryStates: []) == .stopped)
    }

    @Test func overallState_failedTakesPrecedenceOverEverythingElse() {
        #expect(overallState(mandatoryStates: [.failed, .ready, .starting, .degraded]) == .failed)
    }
}
