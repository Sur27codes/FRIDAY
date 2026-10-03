import Foundation

/// Why a service's pre-spawn socket check came out the way it did —
/// surfaced so a "duplicate instance" situation is reported, not
/// silently resolved by guessing (`docs/PHASE-2-...` P2-M1 §10: "Prevent
/// duplicate service instances where the architecture requires singleton
/// behavior").
public enum SocketPrecheck: Equatable, Sendable {
    /// No file at the path — normal case, nothing to do.
    case clear
    /// A file existed but nothing answered `Health` on it — a stale
    /// artifact from an unclean prior shutdown; removed so the fresh
    /// process can bind the path (Unix-domain-socket binds fail with
    /// "address in use" if a file already occupies the path, even with
    /// no live listener).
    case staleFileRemoved
    /// A real process answered `Health` on this path already. This
    /// Supervisor did not spawn it and has no handle to it — spawning a
    /// second process on the same path would either fail to bind or,
    /// worse, silently create two processes purporting to be the same
    /// service. Treated as a hard precondition failure for that service,
    /// not resolved automatically.
    case liveProcessDetected
    /// A real, healthy process answered `Health` on this path, but it
    /// was PROVEN — not guessed — to be an orphaned leftover of a
    /// previous, now-dead instance of this same app: the
    /// `OrphanOwnershipRecord` this Supervisor itself wrote the last
    /// time it spawned a service on this exact socket path names an
    /// owning app process that no longer exists. Gracefully reclaimed
    /// (SIGTERM, bounded wait, SIGKILL escalation only if still alive)
    /// before this precheck returns, so the caller can proceed straight
    /// to a fresh spawn (`docs/PHASE-2-...` P2-PROD-BOOTSTRAP-R2.6 §5/§8:
    /// "Start/Resume... owner requested recovery... implement
    /// deterministic safe cleanup/recovery... do not kill -9 arbitrary
    /// processes"). Never applied to a process this Supervisor has no
    /// ownership record for — that unconditionally stays
    /// `.liveProcessDetected`, exactly as before this case existed.
    case staleProcessReclaimed
}

/// What `Supervisor` itself wrote to a small sidecar file
/// (`<healthSocketPath>.owner.json`) the moment it last successfully
/// spawned a service on that socket path — the ONLY evidence
/// `precheckSocket` ever acts on to decide a live process there is a
/// safe-to-reclaim orphan rather than an unknown/foreign one. `ownerPID`
/// is THIS APP'S OWN process ID at spawn time (never the daemon's) —
/// checking whether it still exists is what distinguishes "the app that
/// owns this daemon already quit" (safe to reclaim) from "a sibling
/// FRIDAY.app instance is still alive and actively supervising this
/// daemon right now" (never touch — same precondition the pre-existing
/// `.liveProcessDetected` case already protects).
struct OrphanOwnershipRecord: Codable, Equatable {
    let ownerPID: Int32
    let childPID: Int32
}

/// Orchestrates exactly the services it's given, in the order given,
/// respecting each one's readiness before starting the next
/// (`docs/PHASE-2-...` P2-M1 §7). P2-M1's production configuration is
/// exactly two services — `policyengined`, then `capabilitybusd` — and
/// nothing else; `friday-daemon` does not exist yet (P2-M2).
///
/// An `actor` because health-poll loops for multiple services run
/// concurrently and all mutate shared runtime state — actor isolation
/// makes that safe without hand-rolled locking, and is the correct tool
/// here (not one this codebase reaches for by default — Go's goroutines
/// use channels/mutexes for the equivalent problem on that side of the
/// Companion↔Runtime boundary).
public actor Supervisor {
    private let configs: [SupervisedServiceConfig]
    private let spawner: ProcessSpawning
    private let healthChecker: HealthChecking
    private let engine: SupervisorEngine
    private let orphanSignaling: OrphanProcessSignaling
    /// This app's own process ID — written into every
    /// `OrphanOwnershipRecord` this Supervisor creates, so a FUTURE
    /// Supervisor instance (this app relaunched) can tell whether the
    /// instance that owns a given live daemon is this exact process
    /// (still running — never touch it) or one that has already exited.
    private let ownerPID: Int32

    private var runtimeStates: [String: ServiceRuntimeState] = [:]
    private var runningProcesses: [String: RunningProcess] = [:]
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var restartTasks: [String: Task<Void, Never>] = [:]

    /// Last socket-precheck outcome per service, surfaced for tests and
    /// for the menu bar's failure explanation.
    public private(set) var lastPrecheck: [String: SocketPrecheck] = [:]

    public init(
        services: [SupervisedServiceConfig],
        spawner: ProcessSpawning = RealProcessSpawner(),
        healthChecker: HealthChecking = RealHealthClient(),
        engine: SupervisorEngine = SupervisorEngine(),
        orphanSignaling: OrphanProcessSignaling = RealOrphanProcessSignaling(),
        ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.configs = services
        self.spawner = spawner
        self.healthChecker = healthChecker
        self.engine = engine
        self.orphanSignaling = orphanSignaling
        self.ownerPID = ownerPID
        for c in services { runtimeStates[c.name] = ServiceRuntimeState() }
    }

    // MARK: - Public state access

    public func state(for name: String) -> ServiceLifecycleState {
        runtimeStates[name]?.lifecycle ?? .stopped
    }

    public func snapshot() -> [String: ServiceLifecycleState] {
        runtimeStates.mapValues { $0.lifecycle }
    }

    public var overall: ServiceLifecycleState {
        overallState(mandatoryStates: configs.filter(\.isMandatory).map { state(for: $0.name) })
    }

    // MARK: - Startup

    /// Spawns each configured service IN ORDER, waiting for a service to
    /// become `.ready` (or exhaust its startup timeout) before spawning
    /// the next. This is what makes `capabilitybusd` never start before
    /// `policyengined` has actually written its public key file and
    /// begun listening — a real dependency, not just a cosmetic ordering
    /// preference (`capabilitybusd` requires that file to exist at its
    /// own startup).
    public func startAll() async {
        for config in configs {
            await start(config)
            // `start` only kicks off spawning + background health
            // polling — it does not itself wait for the result. Block
            // here, polling our own settled state, until the service
            // reaches `.ready` or `.failed` (bounded by that service's
            // own `startupTimeout`, which will flip `.starting` ->
            // `.failed` if readiness never arrives) — otherwise a
            // dependent service could be started before its dependency
            // has actually written the artifacts it requires (e.g.
            // `capabilitybusd` needs `policyengined`'s published public
            // key file to already exist).
            let settled = await waitUntilSettled(config.name)
            if config.isMandatory && settled != .ready {
                // A mandatory dependency failed to become ready — do not
                // proceed to start services that depend on it existing.
                // (P2-M1's own two services are both mandatory and
                // sequentially dependent; a future optional/non-blocking
                // service would still appear in `configs` but this check
                // only halts the sequence for mandatory failures.)
                return
            }
        }
    }

    /// Polls this Supervisor's own state until the named service reaches
    /// a startup-settled state (`.ready` or `.failed`), or forever if
    /// somehow neither ever arrives (in practice bounded by the
    /// service's `startupTimeout` timer, which always eventually fires).
    private func waitUntilSettled(_ name: String) async -> ServiceLifecycleState {
        while true {
            let s = state(for: name)
            if s == .ready || s == .failed { return s }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms poll
        }
    }

    /// Starts (or restarts) exactly one service.
    public func start(_ config: SupervisedServiceConfig) async {
        let precheck = await precheckWithBoundedRetry(config: config)
        lastPrecheck[config.name] = precheck
        if precheck == .liveProcessDetected {
            // Do not spawn a second instance and do not adopt the
            // unknown existing one — surfaced as `.failed` with the
            // precheck reason recorded in `lastPrecheck`, not silently
            // resolved either way.
            runtimeStates[config.name]?.lifecycle = .failed
            return
        }

        let (_, action) = apply(.startRequested, to: config.name)
        guard action == .spawnProcess else { return }
        await spawnAndWatch(config)
    }

    /// A single `.liveProcessDetected` reading is not necessarily a
    /// permanent duplicate — it is also exactly what a genuinely-owned
    /// sibling instance looks like for the few seconds it spends inside
    /// its own `applicationWillTerminate`/`stopAll()` (bounded to ~5s by
    /// the outer semaphore in `AppDelegate`): its helper is still alive
    /// and its `OrphanOwnershipRecord` still names a live `ownerPID`
    /// (itself), because it hasn't reached this socket's `stop()` /
    /// record removal yet. P2-PROD-BOOTSTRAP-R2.7 reproduced this live:
    /// quitting FRIDAY and relaunching it while the old instance was
    /// still mid-shutdown left the new instance permanently `.failed`
    /// even though the old helper exited on its own a moment later.
    /// Re-running the precheck for up to that same ~5s ceiling — instead
    /// of deciding once and giving up — lets that race resolve itself
    /// the moment the dying sibling's helper actually exits;
    /// `precheckSocket` already turns a now-free resource into
    /// `.clear`/`.staleFileRemoved`/`.staleProcessReclaimed` on its own.
    /// A real, permanent sibling instance still exhausts this bounded
    /// window and settles on `.liveProcessDetected` exactly as before
    /// this retry existed — this changes timing for a transient race,
    /// not the safety rule that an unknown/foreign live process is never
    /// touched.
    private func precheckWithBoundedRetry(
        config: SupervisedServiceConfig,
        window: TimeInterval = 5.0
    ) async -> SocketPrecheck {
        let deadline = Date().addingTimeInterval(window)
        while true {
            let result = await precheckSocket(config: config)
            if result != .liveProcessDetected || Date() >= deadline {
                return result
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

    private func spawnAndWatch(_ config: SupervisedServiceConfig) async {
        do {
            let process = try spawner.spawn(
                executableURL: config.executableURL,
                arguments: config.arguments,
                environment: config.environment
            )
            runningProcesses[config.name] = process
            // P2-PROD-BOOTSTRAP-R2.6 §5/§8 — recorded BEFORE registering
            // the termination handler (spawn is already complete by this
            // point either way): the only fact a future Supervisor
            // instance needs to safely reclaim this exact daemon if this
            // app later dies without a clean `stopAll()`.
            writeOwnershipRecord(childPID: process.processIdentifier, for: config)
            process.onTermination { [weak self] _ in
                guard let self else { return }
                Task { await self.handleExit(config) }
            }
        } catch {
            runtimeStates[config.name]?.lifecycle = .failed
            return
        }

        startHealthPolling(config)
        scheduleStartupTimeout(config)
    }

    private func handleExit(_ config: SupervisedServiceConfig) async {
        pollTasks[config.name]?.cancel()
        pollTasks[config.name] = nil
        runningProcesses[config.name] = nil

        let (_, action) = apply(.processExited, to: config.name)
        if case .scheduleRestart(let delay) = action {
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.spawnAndWatch(config)
            }
            restartTasks[config.name] = task
        }
    }

    // MARK: - Health polling

    private func startHealthPolling(_ config: SupervisedServiceConfig) {
        pollTasks[config.name]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let health = try await self.pollHealth(config)
                    await self.apply(.healthCheckSucceeded(health), to: config.name)
                } catch {
                    await self.apply(.healthCheckFailed, to: config.name)
                }
                try? await Task.sleep(nanoseconds: UInt64(config.healthPollInterval * 1_000_000_000))
            }
        }
        pollTasks[config.name] = task
    }

    private nonisolated func pollHealth(_ config: SupervisedServiceConfig) async throws -> DaemonHealth {
        try healthChecker.checkHealth(socketPath: config.healthSocketPath)
    }

    private func scheduleStartupTimeout(_ config: SupervisedServiceConfig) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(config.startupTimeout * 1_000_000_000))
            guard let self else { return }
            if await self.state(for: config.name) == .starting {
                await self.apply(.startupTimedOut, to: config.name)
            }
        }
    }

    // MARK: - Shutdown

    /// Stops every service in REVERSE start order (`capabilitybusd` then
    /// `policyengined`), sending SIGTERM and waiting up to `deadline`
    /// seconds for exit before escalating to SIGKILL — never leaving an
    /// uncontrolled orphan when this Supervisor owns the process
    /// (`docs/PHASE-2-...` P2-M1 §21).
    public func stopAll(deadline: TimeInterval = 5.0) async {
        for config in configs.reversed() {
            await stop(config, deadline: deadline)
        }
    }

    public func stop(_ config: SupervisedServiceConfig, deadline: TimeInterval = 5.0) async {
        pollTasks[config.name]?.cancel()
        restartTasks[config.name]?.cancel()
        guard let process = runningProcesses[config.name] else {
            runtimeStates[config.name]?.lifecycle = .stopped
            return
        }
        _ = apply(.stopRequested, to: config.name) // -> .stopping, action: terminateProcess
        process.terminate()

        let deadlineDate = Date().addingTimeInterval(deadline)
        while process.isRunning && Date() < deadlineDate {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.forceKill()
        }
        // The `onTermination` handler (registered at spawn time) is what
        // actually drives the final `.stopped` transition via
        // `handleExit`/`processExited` — not duplicated here, so there
        // is exactly one code path that decides "this process is gone."

        // Hygiene, not load-bearing: the daemon's own SIGTERM handler
        // already unlinks its socket file on a clean stop (see
        // `RunningProcess.terminate()`'s doc comment), so a genuinely
        // clean shutdown already leaves `precheckSocket` nothing to find
        // next launch regardless. Removing the sidecar too just avoids a
        // stale, pointless record lingering after an intentional stop.
        removeOwnershipRecord(for: config)
    }

    // MARK: - Socket precheck (stale-artifact / duplicate detection / orphan reclaim)

    private nonisolated func precheckSocket(config: SupervisedServiceConfig) async -> SocketPrecheck {
        let path = config.healthSocketPath
        guard FileManager.default.fileExists(atPath: path) else { return .clear }
        guard let health = try? healthChecker.checkHealth(socketPath: path), health.alive else {
            try? FileManager.default.removeItem(atPath: path)
            removeOwnershipRecord(for: config)
            return .staleFileRemoved
        }
        // A real, healthy process answered — the pre-existing, safe
        // default is to refuse to touch it (`.liveProcessDetected`)
        // unless THIS Supervisor's own past self left proof it is a
        // dead session's orphan (P2-PROD-BOOTSTRAP-R2.6 §5/§8).
        if let record = readOwnershipRecord(for: config), !orphanSignaling.isRunning(pid: record.ownerPID) {
            await reclaimOrphan(pid: record.childPID, config: config)
            return .staleProcessReclaimed
        }
        return .liveProcessDetected
    }

    /// Gracefully terminates a PID already proven (by `precheckSocket`,
    /// via a dead `ownerPID`) to be an orphaned child of a previous
    /// instance of this same app — never an arbitrary or unidentified
    /// process. SIGTERM first, a bounded wait, SIGKILL only as the
    /// last-resort escalation if the orphan does not honor SIGTERM in
    /// time — the identical graceful-then-forceKill shape `stop()`
    /// already uses for processes this Supervisor spawned itself, so
    /// there is exactly one termination philosophy in this file, applied
    /// to two different categories of process handle.
    private nonisolated func reclaimOrphan(pid: Int32, config: SupervisedServiceConfig, deadline: TimeInterval = 3.0) async {
        orphanSignaling.terminate(pid: pid)
        let deadlineDate = Date().addingTimeInterval(deadline)
        while orphanSignaling.isRunning(pid: pid) && Date() < deadlineDate {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if orphanSignaling.isRunning(pid: pid) {
            orphanSignaling.forceKill(pid: pid)
        }
        // The orphan's own SIGTERM handler normally unlinks its socket
        // file itself (same handler `RunningProcess.terminate()`'s doc
        // comment already relies on) — removed here too regardless, so
        // a SIGKILL escalation (which skips that handler entirely) still
        // leaves a clean path for the imminent fresh spawn.
        try? FileManager.default.removeItem(atPath: config.healthSocketPath)
        removeOwnershipRecord(for: config)
    }

    // MARK: - Orphan ownership record (sidecar file, one per socket path)

    private nonisolated func ownershipRecordPath(for config: SupervisedServiceConfig) -> String {
        config.healthSocketPath + ".owner.json"
    }

    private nonisolated func writeOwnershipRecord(childPID: Int32, for config: SupervisedServiceConfig) {
        let record = OrphanOwnershipRecord(ownerPID: ownerPID, childPID: childPID)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: URL(fileURLWithPath: ownershipRecordPath(for: config)), options: .atomic)
    }

    private nonisolated func readOwnershipRecord(for config: SupervisedServiceConfig) -> OrphanOwnershipRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ownershipRecordPath(for: config))) else { return nil }
        return try? JSONDecoder().decode(OrphanOwnershipRecord.self, from: data)
    }

    private nonisolated func removeOwnershipRecord(for config: SupervisedServiceConfig) {
        try? FileManager.default.removeItem(atPath: ownershipRecordPath(for: config))
    }

    // MARK: - Engine bridge

    @discardableResult
    private func apply(_ event: ServiceEvent, to name: String) -> (ServiceRuntimeState, SupervisorAction) {
        let current = runtimeStates[name] ?? ServiceRuntimeState()
        let (next, action) = engine.transition(state: current, event: event)
        runtimeStates[name] = next
        return (next, action)
    }
}
