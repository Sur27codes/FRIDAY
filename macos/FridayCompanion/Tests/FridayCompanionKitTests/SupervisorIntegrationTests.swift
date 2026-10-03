import Testing
@testable import FridayCompanionKit
import Foundation

/// Real-process integration tests: builds the REAL, unmodified
/// `policyengined`/`capabilitybusd` Go binaries and drives a real
/// `Supervisor` (real `RealProcessSpawner` + real `RealHealthClient`)
/// against them — satisfying `docs/PHASE-2-...` P2-M1 §19's "at least
/// one integration test should prove the Companion/supervisor can launch
/// and observe real Phase-1 service readiness," and §20's real crash
/// test. Every test here builds its own isolated temp directory and
/// never touches the developer's actual `~/Library/Application Support`.
///
/// A class (not a struct) because setup/teardown need `init`/`deinit`
/// semantics — Swift Testing creates one fresh instance per `@Test`
/// method, so this still gives per-test isolation identical to XCTest's
/// setUp/tearDown.
///
/// `.serialized`: these tests spawn real OS processes and run real `go
/// build` invocations — letting them race each other for CPU (Swift
/// Testing parallelizes `@Test`s by default) makes real startup-timing
/// behavior flaky in a way that has nothing to do with the Supervisor's
/// own correctness (already covered deterministically by the fake-driven
/// `SupervisorTests`). Serializing this specific suite removes that
/// contention as a variable, matching how it would actually run as CI's
/// one real-daemon smoke check, not a parallel stress test.
@Suite(.serialized)
final class SupervisorIntegrationTests {
    let repoRoot: URL
    let buildDir: URL
    let policyBinary: URL
    let busBinary: URL

    init() throws {
        repoRoot = GoBinaryBuilder.repoRoot()
        // Deliberately `/tmp/...` (short), NOT `FileManager.default
        // .temporaryDirectory` — the latter resolves to a long,
        // per-app-container path on macOS that, once a UUID-named
        // subdirectory and a socket filename are appended, reliably
        // exceeds the 104-byte `sockaddr_un.sun_path` limit and fails to
        // bind with `bind: invalid argument` — the same class of bug
        // already documented elsewhere in this project.
        buildDir = URL(fileURLWithPath: "/tmp/fc-it-\(Int.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        policyBinary = buildDir.appendingPathComponent("policyengined")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/policy-engine"),
                                  packagePath: "./cmd/policyengined", output: policyBinary)

        busBinary = buildDir.appendingPathComponent("capabilitybusd")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/capability-bus"),
                                  packagePath: "./cmd/capabilitybusd", output: busBinary)
    }

    deinit {
        try? FileManager.default.removeItem(at: buildDir)
    }

    private func freshRuntimeConfig() -> CompanionConfiguration {
        let dir = buildDir.appendingPathComponent("run-\(Int.random(in: 0..<1_000_000))", isDirectory: true)
        return CompanionConfiguration(
            runtimeDirectory: dir,
            policyEngineBinary: policyBinary,
            capabilityBusBinary: busBinary,
            workspaceRoot: dir.appendingPathComponent("workspace", isDirectory: true)
        )
    }

    // MARK: - Real readiness (extends P2M1-SUP-001 to real binaries)

    @Test func realSupervisor_bothRealDaemons_reachReady() async throws {
        let config = freshRuntimeConfig()
        try prepareRuntimeDirectories(config)
        let configs = makeP2M1ServiceConfigs(config).map { c -> SupervisedServiceConfig in
            SupervisedServiceConfig(name: c.name, executableURL: c.executableURL, arguments: c.arguments,
                                     environment: c.environment, healthSocketPath: c.healthSocketPath,
                                     isMandatory: c.isMandatory, startupTimeout: 8, healthPollInterval: 0.1)
        }
        let sup = Supervisor(services: configs)

        await sup.startAll()

        #expect(await sup.overall == .ready, "both real daemons should reach Ready via their real Health RPC")

        // Independent confirmation, not reusing the Supervisor's own
        // verdict: call Health directly, exactly as a completely
        // separate observer would.
        let directHealth = try RealHealthClient().checkHealth(socketPath: config.policySocketPath)
        #expect(directHealth.alive && directHealth.ready)

        await sup.stopAll()
    }

    // MARK: - P2M1-SEC-004: private signing key never touches the Companion side

    @Test func privateSigningKey_neverWrittenAnywhereCompanionCanReach() async throws {
        let config = freshRuntimeConfig()
        try prepareRuntimeDirectories(config)
        let configs = makeP2M1ServiceConfigs(config)
        let sup = Supervisor(services: configs)
        await sup.startAll()
        #expect(await sup.overall == .ready)

        let contents = try FileManager.default.contentsOfDirectory(atPath: config.runtimeDirectory.path)
        #expect(contents.contains("policy.pub"))
        #expect(!contents.contains(where: { $0.lowercased().contains("private") || $0.lowercased().contains("signing") }),
                "no private-key-shaped file should ever exist in the Companion-visible runtime directory")

        let pubKeyContents = try String(contentsOfFile: config.policyPubkeyPath, encoding: .utf8)
        let decoded = Data(base64Encoded: pubKeyContents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(decoded?.count == 32, "an Ed25519 public key is exactly 32 bytes — a private/seed value would be a different length")

        await sup.stopAll()
    }

    // MARK: - Real crash detection (extends P2M1-SUP-004/020 to a real process)

    @Test func realProcessKill_isDetected_andSupervisorRestartsIt() async throws {
        let config = freshRuntimeConfig()
        try prepareRuntimeDirectories(config)
        let base = makeP2M1ServiceConfigs(config)[0]
        let policyOnly = SupervisedServiceConfig(name: base.name, executableURL: base.executableURL,
                                                  arguments: base.arguments, healthSocketPath: base.healthSocketPath,
                                                  isMandatory: true, startupTimeout: 8, healthPollInterval: 0.1)
        let sup = Supervisor(services: [policyOnly])

        await sup.startAll()
        #expect(await sup.state(for: "policyengined") == .ready)

        let pid = try realPID(forSocketOwningProcessNamed: "policyengined")
        kill(pid, SIGKILL)

        let restarted = await waitFor(timeout: 5.0) {
            let s = await sup.state(for: "policyengined")
            return s == .restarting || s == .ready
        }
        #expect(restarted, "a real SIGKILL must be detected and trigger the restart path")

        let readyAgain = await waitFor(timeout: 8.0) { await sup.state(for: "policyengined") == .ready }
        #expect(readyAgain, "policyengined should come back up and become ready again after the real crash")

        await sup.stopAll()
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.6 §1/§5/§8: real orphaned daemon, real reclaim, real fresh spawn

    /// Reproduces the exact real-hardware defect this mission
    /// investigated: a previous app instance's real `policyengined`
    /// child outlives that instance (crash, force-quit, `kill -9` on the
    /// parent — never a clean `stopAll()`) and is still genuinely alive,
    /// still genuinely healthy, still squatting the real socket path
    /// when the app is relaunched. Proves a brand-new `Supervisor`
    /// instance (standing in for the relaunch) gracefully reclaims the
    /// real orphan and reaches `.ready` on a genuinely fresh process —
    /// never merely "no error," and never by adopting the orphan.
    @Test func realOrphanedDaemon_fromADeadOwner_isReclaimed_andFreshRealProcessReachesReady() async throws {
        let config = freshRuntimeConfig()
        try prepareRuntimeDirectories(config)
        let base = makeP2M1ServiceConfigs(config)[0]
        let policyOnly = SupervisedServiceConfig(name: base.name, executableURL: base.executableURL,
                                                  arguments: base.arguments, healthSocketPath: base.healthSocketPath,
                                                  isMandatory: true, startupTimeout: 8, healthPollInterval: 0.1)

        // A real PID that definitely once existed and definitely does
        // NOT exist anymore — standing in for "the app instance that
        // owned this daemon already died," without guessing at any
        // particular cause.
        let deadOwnerPID = try spawnAndWaitForRealExit()

        // "Instance #1": a real Supervisor whose owner PID is already
        // dead by the time it finishes starting — modeling a crash that
        // happens sometime after startup, before any clean stopAll().
        let firstInstance = Supervisor(services: [policyOnly], ownerPID: deadOwnerPID)
        await firstInstance.startAll()
        #expect(await firstInstance.state(for: "policyengined") == .ready)
        let orphanPID = try realPID(forSocketOwningProcessNamed: "policyengined")

        // Deliberately NOT calling `firstInstance.stopAll()` — the real
        // child process is left running, genuinely orphaned, exactly as
        // a crash/force-quit would leave it. Independently confirm it is
        // still genuinely alive and healthy before treating it as the
        // real "owner recording" evidence.
        #expect(kill(orphanPID, 0) == 0, "the orphan must still be a real, running process before reclaim is exercised")
        let directHealth = try RealHealthClient().checkHealth(socketPath: config.policySocketPath)
        #expect(directHealth.alive)

        // "Instance #2": the relaunch. Its own owner PID (defaulted to
        // THIS test process, genuinely alive) must never be mistaken for
        // the dead one recorded by instance #1.
        let secondInstance = Supervisor(services: [policyOnly])
        await secondInstance.start(policyOnly)

        #expect(await secondInstance.lastPrecheck["policyengined"] == .staleProcessReclaimed)
        let reclaimed = await waitFor(timeout: 2.0) { kill(orphanPID, 0) != 0 }
        #expect(reclaimed, "the real orphan process must actually be gone after reclaim")

        let readyAgain = await waitFor(timeout: 8.0) { await secondInstance.state(for: "policyengined") == .ready }
        #expect(readyAgain, "a genuinely fresh real process must reach READY after reclaiming the orphan's socket")
        let freshPID = try realPID(forSocketOwningProcessNamed: "policyengined")
        #expect(freshPID != orphanPID, "the daemon now serving the socket must be a NEW process, never the reclaimed orphan itself")

        await secondInstance.stopAll()
    }

    /// Spawns a trivial real process and waits for it to exit, returning
    /// its PID — a real, once-valid, now-guaranteed-dead PID, standing
    /// in for "the app instance that used to own this daemon."
    private func spawnAndWaitForRealExit() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func realPID(forSocketOwningProcessNamed name: String) throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pgrep", "-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // Same ordering fix as `runGoBuild` — drain before waiting.
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outData, encoding: .utf8) ?? ""
        guard let pidLine = output.split(separator: "\n").first, let pid = pid_t(pidLine) else {
            Issue.record("could not locate real \(name) process via pgrep")
            return -1
        }
        return pid
    }

    private func waitFor(timeout: TimeInterval, condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }
}
