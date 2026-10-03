import Foundation

/// Every state-affecting thing that can happen to one supervised
/// service, from the Supervisor's point of view. Deliberately narrow —
/// spawning itself is a synchronous, throwing call the async driver
/// performs directly (see `Supervisor.swift`); this engine handles the
/// judgment calls that most need to be correct and are cheapest to get
/// wrong: health-result interpretation, crash-vs-intentional-stop
/// disambiguation, and the restart-budget decision.
public enum ServiceEvent: Equatable, Sendable {
    case healthCheckSucceeded(DaemonHealth)
    case healthCheckFailed
    case startupTimedOut
    case processExited
    case stopRequested
    case startRequested
}

public enum SupervisorAction: Equatable, Sendable {
    case none
    case spawnProcess
    case scheduleRestart(after: TimeInterval)
    case terminateProcess
}

public struct ServiceRuntimeState: Equatable, Sendable {
    public var lifecycle: ServiceLifecycleState
    public var restartAttemptTimestamps: [Date]
    /// Set the moment a stop is requested, so a `processExited` event
    /// that arrives afterward (the normal, expected order — SIGTERM,
    /// then the OS reports exit) is recognized as intentional rather
    /// than treated as a crash (`docs/PHASE-2-...` P2-M1 §9: "intentional
    /// user shutdown is not mistaken for crash").
    public var intentionalStop: Bool

    public init(lifecycle: ServiceLifecycleState = .stopped, restartAttemptTimestamps: [Date] = [], intentionalStop: Bool = false) {
        self.lifecycle = lifecycle
        self.restartAttemptTimestamps = restartAttemptTimestamps
        self.intentionalStop = intentionalStop
    }
}

/// The pure per-service state machine. No I/O, no timers, no process
/// handles — just "given this state and this event, what's the next
/// state and what should the driver do about it." Fully deterministic
/// given an injected clock, which is exactly what makes
/// `SupervisorEngineTests` able to assert restart-backoff/budget
/// behavior without a single real `sleep`.
public struct SupervisorEngine: Sendable {
    public let policy: RestartPolicy
    public let now: @Sendable () -> Date

    public init(policy: RestartPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.now = now
    }

    public func transition(state: ServiceRuntimeState, event: ServiceEvent) -> (ServiceRuntimeState, SupervisorAction) {
        var state = state
        switch event {
        case .healthCheckSucceeded(let health):
            if health.alive && health.ready {
                state.lifecycle = .ready
            } else if state.lifecycle == .ready {
                // Was ready, now isn't — a real degradation, not merely
                // "still starting."
                state.lifecycle = .degraded
            }
            // else: still `.starting`, unchanged — a not-yet-ready
            // response while starting is expected, not an error.
            return (state, .none)

        case .healthCheckFailed:
            if state.lifecycle == .ready {
                state.lifecycle = .degraded
            }
            return (state, .none)

        case .startupTimedOut:
            if state.lifecycle == .starting {
                state.lifecycle = .failed
            }
            return (state, .none)

        case .processExited:
            if state.intentionalStop {
                state.lifecycle = .stopped
                state.intentionalStop = false
                state.restartAttemptTimestamps = []
                return (state, .none)
            }
            // A genuine crash: prune restart attempts outside the
            // rolling window, then count this one.
            let cutoff = now().addingTimeInterval(-policy.attemptWindow)
            var attempts = state.restartAttemptTimestamps.filter { $0 >= cutoff }
            attempts.append(now())
            state.restartAttemptTimestamps = attempts
            if attempts.count > policy.maxAttempts {
                // Budget exhausted — stay failed, do NOT schedule
                // another restart. This is the "no tight crash loop"
                // guarantee's terminal case.
                state.lifecycle = .failed
                return (state, .none)
            }
            state.lifecycle = .restarting
            return (state, .scheduleRestart(after: policy.delay(forAttempt: attempts.count)))

        case .stopRequested:
            state.intentionalStop = true
            state.lifecycle = .stopping
            return (state, .terminateProcess)

        case .startRequested:
            state.lifecycle = .starting
            state.restartAttemptTimestamps = []
            state.intentionalStop = false
            return (state, .spawnProcess)
        }
    }
}

/// Overall system readiness is the worst state among MANDATORY services
/// — never merely "at least one is ready" (`docs/PHASE-2-...` P2-M1 §7).
/// Precedence, most to least severe: failed > restarting > degraded >
/// starting > stopping > (ready only if every mandatory service is
/// ready) > stopped.
public func overallState(mandatoryStates: [ServiceLifecycleState]) -> ServiceLifecycleState {
    if mandatoryStates.isEmpty { return .stopped }
    if mandatoryStates.contains(.failed) { return .failed }
    if mandatoryStates.contains(.restarting) { return .restarting }
    if mandatoryStates.contains(.degraded) { return .degraded }
    if mandatoryStates.contains(.starting) { return .starting }
    if mandatoryStates.contains(.stopping) { return .stopping }
    if mandatoryStates.allSatisfy({ $0 == .ready }) { return .ready }
    return .stopped
}
