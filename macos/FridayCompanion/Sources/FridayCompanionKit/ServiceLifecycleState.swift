import Foundation

/// The state of one supervised process, or of the Supervisor as a whole
/// (the overall state is the worst/most-relevant state among mandatory
/// services — see `Supervisor.overallState`).
///
/// Matches `docs/PHASE-2-DAEMON-...` P2-M1 authorization §6 exactly:
/// STOPPED / STARTING / READY / DEGRADED / RESTARTING / FAILED / STOPPING.
public enum ServiceLifecycleState: Equatable, Sendable {
    /// Not running, no restart in progress. The initial state, and the
    /// state after an intentional stop.
    case stopped

    /// Process has been spawned; health checks have not yet reported
    /// `ready: true`. A process merely existing is NOT `.ready` — see
    /// `Supervisor`'s polling loop.
    case starting

    /// The process's own Health RPC reported `alive: true, ready: true`.
    /// This is the ONLY state that may count toward overall system
    /// readiness.
    case ready

    /// The process is alive but not (or no longer) reporting ready —
    /// e.g. a mandatory dependency it needs is itself not ready. Distinct
    /// from `.failed`: degraded is not necessarily terminal.
    case degraded

    /// The process exited unexpectedly and a bounded restart attempt is
    /// in progress (see `RestartPolicy`).
    case restarting

    /// The process exited unexpectedly and the restart-attempt budget
    /// has been exhausted, OR it never became ready within its startup
    /// timeout. Terminal until an explicit user action (Start/Resume).
    case failed

    /// An intentional shutdown (user Quit, or Supervisor.shutdown()) is
    /// in progress. Distinguishes "we are stopping this on purpose" from
    /// `.restarting`'s "this crashed and we're bringing it back."
    case stopping
}
