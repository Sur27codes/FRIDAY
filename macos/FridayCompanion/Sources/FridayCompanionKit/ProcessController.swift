import Foundation

/// Everything the Supervisor needs to know when a managed process ends,
/// regardless of why.
public struct ProcessTermination: Sendable {
    public let exitCode: Int32
    public let wasSignaled: Bool
    public init(exitCode: Int32, wasSignaled: Bool) {
        self.exitCode = exitCode
        self.wasSignaled = wasSignaled
    }
}

/// One running child process, abstracted so `Supervisor`'s tests can use
/// a deterministic fake instead of a real OS process (`docs/PHASE-2-...`
/// P2-M1 §19: "Do not test supervision entirely with mocks... use a
/// combination of pure unit tests, fake deterministic child-process
/// fixtures, and real Phase-1 service-process integration where safe" —
/// this protocol is what makes the first two possible; the real
/// implementation below is what the third uses).
public protocol RunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The real OS process ID — recorded by `Supervisor` at spawn time
    /// so a FUTURE Supervisor instance (e.g. after this app quits and
    /// relaunches) can later tell an orphaned child of THIS session
    /// apart from an unrelated/unknown process merely answering the
    /// same socket (`docs/PHASE-2-...` P2-PROD-BOOTSTRAP-R2.6 §8's
    /// deterministic stale-process recovery). Never used for signaling
    /// directly through this protocol — only `terminate()`/`forceKill()`
    /// (which apply to a process THIS instance still holds a live
    /// handle to) do that; a recorded PID from a past instance is acted
    /// on only via the separate, explicitly-scoped
    /// `OrphanProcessSignaling` below.
    var processIdentifier: Int32 { get }
    /// Sends SIGTERM (graceful) — matches the real daemons' own
    /// `signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)` handling
    /// (confirmed present in both `policyengined`/`capabilitybusd`
    /// before this was written), so a real supervised process cleans up
    /// its own socket file on this signal rather than needing the
    /// supervisor to do it.
    func terminate()
    /// Sends SIGKILL — the bounded escalation path if `terminate()`
    /// doesn't result in exit within a deadline.
    func forceKill()
    /// Registers a callback invoked exactly once, off the caller's
    /// thread, when the process exits for any reason (normal exit,
    /// SIGTERM, SIGKILL, or crash).
    func onTermination(_ handler: @escaping @Sendable (ProcessTermination) -> Void)
}

public protocol ProcessSpawning: Sendable {
    /// Spawns a new process. Throws if the executable cannot be launched
    /// at all (e.g., missing binary) — this is distinct from the process
    /// later exiting with a non-zero code, which is reported via
    /// `onTermination` instead.
    func spawn(executableURL: URL, arguments: [String], environment: [String: String]?) throws -> RunningProcess
}

// MARK: - Real implementation

final class RealRunningProcess: RunningProcess, @unchecked Sendable {
    private let process: Process
    private var handler: (@Sendable (ProcessTermination) -> Void)?
    private let lock = NSLock()

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] p in
            self?.deliverTermination(exitCode: p.terminationStatus, wasSignaled: p.terminationReason == .uncaughtSignal)
        }
    }

    var isRunning: Bool { process.isRunning }

    var processIdentifier: Int32 { process.processIdentifier }

    func terminate() { process.terminate() } // SIGTERM

    func forceKill() {
        // Foundation's Process.terminate() sends SIGTERM; escalate to a
        // real SIGKILL via the POSIX API when a hard kill is required.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func onTermination(_ handler: @escaping @Sendable (ProcessTermination) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    private func deliverTermination(exitCode: Int32, wasSignaled: Bool) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(ProcessTermination(exitCode: exitCode, wasSignaled: wasSignaled))
    }
}

/// Spawns real OS processes via `Foundation.Process`. Used in production
/// and in the integration tests that exercise the real `policyengined`/
/// `capabilitybusd` binaries.
public struct RealProcessSpawner: ProcessSpawning {
    public init() {}

    public func spawn(executableURL: URL, arguments: [String], environment: [String: String]?) throws -> RunningProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        // Never attach the child's stdio to a Terminal-shaped pipe by
        // accident — production runs with no controlling terminal at
        // all (FR-AMBIENT-002), and tests redirect explicitly if they
        // need output.
        try process.run()
        return RealRunningProcess(process: process)
    }
}

// MARK: - Orphan reclaim signaling (P2-PROD-BOOTSTRAP-R2.6 §5/§8)

/// Sending a real POSIX signal to a PID this process did NOT itself
/// `Process.run()` (so `RunningProcess.terminate()`/`forceKill()` don't
/// apply — those require a live `Foundation.Process` handle, which only
/// exists for a child THIS instance spawned). Used exactly once, by
/// `Supervisor`'s deterministic orphan-reclaim path, and ONLY after that
/// path has already independently proven (via the recorded
/// `OrphanOwnershipRecord`'s dead owner PID — never guessed, never
/// "whatever answers this socket") that the target PID is a genuine
/// leftover child of a previous, now-dead instance of this same app —
/// never an arbitrary or unrelated process.
public protocol OrphanProcessSignaling: Sendable {
    /// Whether a process with this PID currently exists — `kill(pid, 0)`
    /// succeeding means "yes, and I have permission to signal it," which
    /// is exactly what matters here (this app never needs to reason
    /// about another user's processes).
    func isRunning(pid: Int32) -> Bool
    func terminate(pid: Int32) // SIGTERM
    func forceKill(pid: Int32) // SIGKILL
}

public struct RealOrphanProcessSignaling: OrphanProcessSignaling {
    public init() {}

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    public func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    public func forceKill(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }
}
