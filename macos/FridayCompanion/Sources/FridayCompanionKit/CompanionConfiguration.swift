import Foundation

/// Where the Companion keeps its own runtime artifacts (sockets, the
/// Policy Engine's published public key) and where the two Phase-1
/// binaries it supervises live. Deliberately its own directory tree —
/// distinct from any path a developer might choose when running
/// `cmd/friday`/`policyengined`/`capabilitybusd` manually — so
/// Companion-managed and developer-managed instances never collide on
/// the same socket path merely by using the same defaults
/// (`docs/PHASE-2-...` P2-M1 §10: "Developer mode must not silently
/// conflict with production Companion-managed mode").
public struct CompanionConfiguration: Sendable, Equatable {
    public let runtimeDirectory: URL
    public let policyEngineBinary: URL
    public let capabilityBusBinary: URL
    public let workspaceRoot: URL

    public init(runtimeDirectory: URL, policyEngineBinary: URL, capabilityBusBinary: URL, workspaceRoot: URL) {
        self.runtimeDirectory = runtimeDirectory
        self.policyEngineBinary = policyEngineBinary
        self.capabilityBusBinary = capabilityBusBinary
        self.workspaceRoot = workspaceRoot
    }

    /// The default production location:
    /// `~/Library/Application Support/FridayCompanion/`. Binary paths are
    /// NOT defaulted here — P2-M1 does no packaging (P2-M8 scope), so the
    /// caller (production app shell, or a test) always supplies exactly
    /// where the two Go binaries actually are.
    public static func defaultRuntimeDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("FridayCompanion", isDirectory: true)
    }

    public var policySocketPath: String { runtimeDirectory.appendingPathComponent("policy.sock").path }
    public var policyPubkeyPath: String { runtimeDirectory.appendingPathComponent("policy.pub").path }
    public var busSocketPath: String { runtimeDirectory.appendingPathComponent("bus.sock").path }
    /// New in P2-M2 — friday-daemon's own socket and durable store.
    public var daemonSocketPath: String { runtimeDirectory.appendingPathComponent("daemon.sock").path }
    public var storeDatabasePath: String { runtimeDirectory.appendingPathComponent("runtime.db").path }
}

/// Builds the exact `SupervisedServiceConfig` list for P2-M1: exactly
/// `policyengined` then `capabilitybusd`, in that order — the order the
/// real startup dependency requires (`capabilitybusd` reads
/// `policyPubkeyPath`, which only exists once `policyengined` has
/// written it). No third entry — `friday-daemon` is P2-M2 and is not
/// constructed by this function.
public func makeP2M1ServiceConfigs(_ config: CompanionConfiguration) -> [SupervisedServiceConfig] {
    [
        SupervisedServiceConfig(
            name: "policyengined",
            executableURL: config.policyEngineBinary,
            arguments: ["-socket", config.policySocketPath, "-pubkey-out", config.policyPubkeyPath],
            healthSocketPath: config.policySocketPath
        ),
        SupervisedServiceConfig(
            name: "capabilitybusd",
            executableURL: config.capabilityBusBinary,
            arguments: [
                "-socket", config.busSocketPath,
                "-policy-pubkey", config.policyPubkeyPath,
                "-workspace-root", config.workspaceRoot.path,
            ],
            healthSocketPath: config.busSocketPath
        ),
    ]
}

/// Builds the P2-M2 service list: the same `policyengined`/
/// `capabilitybusd` pair P2-M1 already supervises, PLUS `friday-daemon`
/// as a third, dependent service — extending, not replacing, the
/// existing dependency chain (`docs/PHASE-2-...` P2-M2 §12: "Policy
/// Engine READY -> Capability Bus READY -> friday-daemon READY").
/// `friday-daemon` is mandatory: `Supervisor.overall` (unchanged since
/// P2-M1) already computes readiness over every mandatory service, so
/// the Companion cannot show overall READY unless the daemon can itself
/// serve requests — no new Supervisor logic was needed for this.
public func makeP2M2ServiceConfigs(_ config: CompanionConfiguration, daemonBinary: URL) -> [SupervisedServiceConfig] {
    var configs = makeP2M1ServiceConfigs(config)
    configs.append(
        SupervisedServiceConfig(
            name: "friday-daemon",
            executableURL: daemonBinary,
            arguments: [
                "-socket", config.daemonSocketPath,
                "-policy-socket", config.policySocketPath,
                "-bus-socket", config.busSocketPath,
                "-store", config.storeDatabasePath,
                "-workspace-root", config.workspaceRoot.path,
            ],
            healthSocketPath: config.daemonSocketPath,
            // friday-daemon's own dependency chain (Policy Engine, Bus)
            // needs more time to be reachable than the two daemons need
            // to become ready themselves, since it performs live Health
            // calls to both as part of its own readiness computation.
            startupTimeout: 12
        )
    )
    return configs
}

/// Ensures the runtime directory and workspace root exist before the
/// Supervisor tries to spawn anything into them (both Go binaries expect
/// their parent directories to already exist for the socket/pubkey
/// paths they're given).
public func prepareRuntimeDirectories(_ config: CompanionConfiguration) throws {
    try FileManager.default.createDirectory(at: config.runtimeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config.workspaceRoot, withIntermediateDirectories: true)
}
