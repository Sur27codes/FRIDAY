import Foundation
@testable import FridayCompanionKit

/// A deterministic fake `RunningProcess` — no real OS process involved.
/// Lets `SupervisorTests` simulate "the process exited" / "the process
/// is still running" without depending on real process scheduling
/// timing, per `docs/PHASE-2-...` P2-M1 §19's explicit instruction to
/// use fake deterministic child-process fixtures for the bulk of
/// supervision testing.
final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    private static let counterLock = NSLock()
    private static var nextFakePID: Int32 = 1_000_000 // arbitrary, never a real PID range
    private static func allocateFakePID() -> Int32 {
        counterLock.lock(); defer { counterLock.unlock() }
        nextFakePID += 1
        return nextFakePID
    }

    private let lock = NSLock()
    private var _isRunning = true
    private var handler: (@Sendable (ProcessTermination) -> Void)?
    private(set) var terminateCallCount = 0
    private(set) var forceKillCallCount = 0
    /// A distinct, deterministic fake value per instance — real value
    /// only matters to the (separately fake-driven) orphan-reclaim
    /// tests, which set up their own `OrphanOwnershipRecord` files
    /// directly rather than relying on this happening to match.
    let processIdentifier: Int32 = FakeRunningProcess.allocateFakePID()

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    func terminate() {
        lock.lock()
        terminateCallCount += 1
        lock.unlock()
    }

    func forceKill() {
        lock.lock()
        forceKillCallCount += 1
        _isRunning = false
        lock.unlock()
    }

    func onTermination(_ handler: @escaping @Sendable (ProcessTermination) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// Test-driver hook: simulate the process actually exiting (crash,
    /// or a clean exit after `terminate()`), delivering the registered
    /// termination handler exactly as the real implementation would.
    func simulateExit(exitCode: Int32 = 0, wasSignaled: Bool = false) {
        lock.lock()
        _isRunning = false
        let h = handler
        lock.unlock()
        h?(ProcessTermination(exitCode: exitCode, wasSignaled: wasSignaled))
    }
}

final class FakeProcessSpawning: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spawnedNames: [String] = [] // last path component of executableURL, for assertions
    private(set) var processesByName: [String: FakeRunningProcess] = [:]
    var shouldFailToSpawn: Set<String> = []

    func spawn(executableURL: URL, arguments: [String], environment: [String: String]?) throws -> RunningProcess {
        let name = executableURL.lastPathComponent
        lock.lock()
        defer { lock.unlock() }
        if shouldFailToSpawn.contains(name) {
            throw NSError(domain: "FakeProcessSpawning", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated spawn failure"])
        }
        spawnedNames.append(name)
        let p = FakeRunningProcess()
        processesByName[name] = p
        return p
    }

    func process(named name: String) -> FakeRunningProcess? {
        lock.lock(); defer { lock.unlock() }
        return processesByName[name]
    }
}

/// A deterministic fake `HealthChecking` — lets tests drive exactly what
/// each service's health check reports at each poll, without any real
/// socket I/O.
final class FakeHealthChecking: HealthChecking, @unchecked Sendable {
    enum Result {
        case health(DaemonHealth)
        case unreachable
    }
    private let lock = NSLock()
    private var resultsBySocketPath: [String: Result] = [:]

    func setResult(_ result: Result, forSocketPath path: String) {
        lock.lock()
        resultsBySocketPath[path] = result
        lock.unlock()
    }

    func checkHealth(socketPath: String) throws -> DaemonHealth {
        lock.lock()
        let result = resultsBySocketPath[socketPath] ?? .unreachable
        lock.unlock()
        switch result {
        case .health(let h): return h
        case .unreachable: throw RPCFrameError.connectFailed("fake: unreachable")
        }
    }
}

/// A deterministic fake `OrphanProcessSignaling` — lets
/// `SupervisorTests` drive exactly which fake PIDs are "alive" (an
/// owner app still running vs. one that has died) without touching any
/// real OS process, per the same "fake-driven bulk, real integration
/// confirms it" split every other Supervisor mechanism already uses.
final class FakeOrphanProcessSignaling: OrphanProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var alivePIDs: Set<Int32>
    private(set) var terminatedPIDs: [Int32] = []
    private(set) var forceKilledPIDs: [Int32] = []
    /// If set, `terminate(pid:)` also removes the PID from `alivePIDs`
    /// immediately — simulates a graceful SIGTERM the target actually
    /// honors, so reclaim tests don't need a real forceKill escalation
    /// to prove the fast path.
    var terminateActuallyKills = true

    init(initiallyAlive: Set<Int32> = []) {
        alivePIDs = initiallyAlive
    }

    func isRunning(pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alivePIDs.contains(pid)
    }

    func terminate(pid: Int32) {
        lock.lock()
        terminatedPIDs.append(pid)
        if terminateActuallyKills { alivePIDs.remove(pid) }
        lock.unlock()
    }

    func forceKill(pid: Int32) {
        lock.lock()
        forceKilledPIDs.append(pid)
        alivePIDs.remove(pid)
        lock.unlock()
    }
}
