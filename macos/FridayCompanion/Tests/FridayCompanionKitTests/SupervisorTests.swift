import Testing
@testable import FridayCompanionKit
import Foundation

/// Actor-level Supervisor tests, driven entirely by `FakeProcessSpawning`
/// / `FakeHealthChecking` — no real OS processes. Short timeouts/poll
/// intervals keep this fast; `SupervisorIntegrationTests` covers the
/// real-binary case separately (`docs/PHASE-2-...` P2-M1 §19).
@Suite struct SupervisorTests {

    private func fastConfig(name: String, mandatory: Bool = true) -> SupervisedServiceConfig {
        SupervisedServiceConfig(
            name: name,
            executableURL: URL(fileURLWithPath: "/usr/bin/\(name)"), // never actually executed (fake spawner)
            arguments: [],
            healthSocketPath: "/tmp/fake-\(name)-\(UUID().uuidString).sock",
            isMandatory: mandatory,
            startupTimeout: 0.6,
            healthPollInterval: 0.02
        )
    }

    // MARK: - P2M1-SUP-001: clean startup reaches READY only after mandatory services are ready

    @Test func sup001_cleanStartup_reachesReady_onlyAfterBothMandatoryServicesReady() async {
        let a = fastConfig(name: "policyengined")
        let b = fastConfig(name: "capabilitybusd")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        let sup = Supervisor(services: [a, b], spawner: spawner, healthChecker: health)

        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: b.healthSocketPath)

        await sup.startAll()

        let overall = await sup.overall
        #expect(overall == .ready)
        let snap = await sup.snapshot()
        #expect(snap["policyengined"] == .ready)
        #expect(snap["capabilitybusd"] == .ready)
        // Startup order: capabilitybusd must have been spawned, proving
        // policyengined's readiness was actually awaited first, not
        // spawned concurrently.
        #expect(spawner.spawnedNames == ["policyengined", "capabilitybusd"])
    }

    // MARK: - P2M1-SUP-002 / P2M1-SUP-003: dependency startup failure prevents READY

    @Test func sup002_policyEngineStartupFailure_preventsOverallReady_andCapabilityBusNeverStarts() async {
        let a = fastConfig(name: "policyengined")
        let b = fastConfig(name: "capabilitybusd")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        let sup = Supervisor(services: [a, b], spawner: spawner, healthChecker: health)
        // policyengined never reports ready -> its own startup timeout fires -> .failed.

        await sup.startAll()

        let overall = await sup.overall
        #expect(overall == .failed)
        #expect(!spawner.spawnedNames.contains("capabilitybusd"),
                "a service must never be started while its mandatory dependency isn't ready")
    }

    @Test func sup003_capabilityBusStartupFailure_preventsOverallReady() async {
        let a = fastConfig(name: "policyengined")
        let b = fastConfig(name: "capabilitybusd")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        // capabilitybusd never becomes ready.
        let sup = Supervisor(services: [a, b], spawner: spawner, healthChecker: health)

        await sup.startAll()

        let snap = await sup.snapshot()
        #expect(snap["policyengined"] == .ready)
        #expect(snap["capabilitybusd"] == .failed)
        let overall = await sup.overall
        #expect(overall == .failed, "overall state must reflect the failed mandatory dependency even though the other one is ready")
    }

    // MARK: - P2M1-SUP-004 / 005 / 006: crash detection + bounded restart

    @Test func sup004_serviceCrash_isDetected() async {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)
        await sup.startAll()
        #expect(await sup.state(for: "policyengined") == .ready)

        spawner.process(named: "policyengined")?.simulateExit(exitCode: 1, wasSignaled: false)

        let observed = await waitFor(timeout: 1.0) {
            await sup.state(for: "policyengined") == .restarting
        }
        #expect(observed, "an unexpected exit while ready must be detected and enter .restarting")
    }

    @Test func sup005_crashedService_entersBoundedRestartPath_andBecomesReadyAgain() async {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)
        await sup.startAll()

        spawner.process(named: "policyengined")?.simulateExit()

        let respawned = await waitFor(timeout: 3.0) {
            spawner.spawnedNames.filter { $0 == "policyengined" }.count == 2
        }
        #expect(respawned, "expected exactly one automatic respawn after a single crash")

        let readyAgain = await waitFor(timeout: 1.0) { await sup.state(for: "policyengined") == .ready }
        #expect(readyAgain)
    }

    @Test func sup006_repeatedCrashLoop_eventuallyBecomesFailed_notInfiniteRestart() async {
        let a = fastConfig(name: "policyengined")
        let policy = RestartPolicy(baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, attemptWindow: 3600)
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health, engine: SupervisorEngine(policy: policy))
        await sup.startAll()

        for _ in 0..<5 {
            spawner.process(named: "policyengined")?.simulateExit()
            try? await Task.sleep(nanoseconds: 150_000_000) // let the (short) restart delay elapse
        }

        let becameFailed = await waitFor(timeout: 2.0) { await sup.state(for: "policyengined") == .failed }
        #expect(becameFailed, "a permanently crash-looping service must settle into .failed, not restart forever")
    }

    // MARK: - P2M1-SUP-007: intentional stop is not mistaken for crash

    @Test func sup007_intentionalStop_doesNotTriggerRestart() async {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)
        await sup.startAll()

        await sup.stop(a)
        spawner.process(named: "policyengined")?.simulateExit()

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await sup.state(for: "policyengined") == .stopped)
        #expect(spawner.spawnedNames.filter { $0 == "policyengined" }.count == 1,
                "an intentional stop must never cause a second spawn")
    }

    // MARK: - P2M1-SUP-008: graceful shutdown stops managed children, in reverse order

    @Test func sup008_stopAll_terminatesEveryChild_inReverseStartOrder() async {
        let a = fastConfig(name: "policyengined")
        let b = fastConfig(name: "capabilitybusd")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: b.healthSocketPath)
        let sup = Supervisor(services: [a, b], spawner: spawner, healthChecker: health)
        await sup.startAll()

        let watcher = Task {
            while true {
                if let p = spawner.process(named: "capabilitybusd"), p.terminateCallCount > 0, p.isRunning {
                    p.simulateExit()
                }
                if let p = spawner.process(named: "policyengined"), p.terminateCallCount > 0, p.isRunning {
                    p.simulateExit()
                }
                if spawner.process(named: "policyengined")?.isRunning == false,
                   spawner.process(named: "capabilitybusd")?.isRunning == false {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await sup.stopAll(deadline: 2.0)
        watcher.cancel()

        #expect(spawner.process(named: "policyengined")?.terminateCallCount == 1)
        #expect(spawner.process(named: "capabilitybusd")?.terminateCallCount == 1)
        let snap = await sup.snapshot()
        #expect(snap["policyengined"] == .stopped)
        #expect(snap["capabilitybusd"] == .stopped)
    }

    // MARK: - P2M1-SUP-010: duplicate/singleton conflict handled deterministically

    @Test func sup010_liveProcessAlreadyOnSocketPath_isNotAdopted_andPreventsSpawn() async throws {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        try "not a real socket, just a marker file".write(toFile: a.healthSocketPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: a.healthSocketPath) }

        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)
        await sup.start(a)

        #expect(await sup.state(for: "policyengined") == .failed)
        #expect(spawner.spawnedNames.isEmpty, "must never spawn a second instance on top of a live one")
        let precheck = await sup.lastPrecheck["policyengined"]
        #expect(precheck == .liveProcessDetected)
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.6 §5/§8: orphaned child of a dead owner is reclaimed, never adopted blindly

    @Test func sup011_orphanFromDeadOwner_isGracefullyReclaimed_thenFreshSpawnSucceeds() async throws {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        // A live process really is answering on this path (same setup as
        // sup010) — the ONLY thing that should ever change the outcome
        // from "refuse" to "reclaim" is a matching ownership record
        // whose recorded owner is provably dead.
        try "not a real socket, just a marker file".write(toFile: a.healthSocketPath, atomically: true, encoding: .utf8)
        let ownerRecordPath = a.healthSocketPath + ".owner.json"
        let orphanChildPID: Int32 = 424242
        let deadOwnerPID: Int32 = 313131
        try JSONEncoder().encode(OrphanOwnershipRecord(ownerPID: deadOwnerPID, childPID: orphanChildPID))
            .write(to: URL(fileURLWithPath: ownerRecordPath))
        defer {
            try? FileManager.default.removeItem(atPath: a.healthSocketPath)
            try? FileManager.default.removeItem(atPath: ownerRecordPath)
        }

        let signaling = FakeOrphanProcessSignaling(initiallyAlive: [orphanChildPID]) // deadOwnerPID deliberately absent -> dead
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health, orphanSignaling: signaling)

        await sup.start(a)

        #expect(await sup.lastPrecheck["policyengined"] == .staleProcessReclaimed)
        #expect(signaling.terminatedPIDs == [orphanChildPID], "the orphan's OWN recorded PID must be signaled — never the dead owner's PID, never a guess")
        #expect(signaling.forceKilledPIDs.isEmpty, "the fake orphan honors SIGTERM immediately — no escalation should have been needed")
        #expect(spawner.spawnedNames == ["policyengined"], "reclaim must be followed by a genuine fresh spawn, not merely 'no-op success'")

        let becameReady = await waitFor(timeout: 1.0) { await sup.state(for: "policyengined") == .ready }
        #expect(becameReady, "the fresh spawn after reclaim must reach the exact same READY path as any normal startup")
    }

    @Test func sup012_liveProcessWithNoOwnershipRecord_isStillNeverTouched_evenIfALaterRecordExistsForADifferentPID() async throws {
        // Guards against a broadened match ever creeping in: an
        // ownership record whose OWNER PID actually IS still running
        // must never be reclaimed, even though a real process answers
        // the socket — this is the "a sibling FRIDAY.app instance is
        // genuinely still alive right now" case, and must behave
        // identically to sup010 (refuse, do not spawn, do not touch).
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking()
        health.setResult(.health(DaemonHealth(alive: true, ready: true)), forSocketPath: a.healthSocketPath)
        try "not a real socket, just a marker file".write(toFile: a.healthSocketPath, atomically: true, encoding: .utf8)
        let ownerRecordPath = a.healthSocketPath + ".owner.json"
        let stillAliveOwnerPID: Int32 = 202020
        let childPID: Int32 = 505050
        try JSONEncoder().encode(OrphanOwnershipRecord(ownerPID: stillAliveOwnerPID, childPID: childPID))
            .write(to: URL(fileURLWithPath: ownerRecordPath))
        defer {
            try? FileManager.default.removeItem(atPath: a.healthSocketPath)
            try? FileManager.default.removeItem(atPath: ownerRecordPath)
        }

        let signaling = FakeOrphanProcessSignaling(initiallyAlive: [stillAliveOwnerPID, childPID])
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health, orphanSignaling: signaling)

        await sup.start(a)

        #expect(await sup.state(for: "policyengined") == .failed)
        #expect(await sup.lastPrecheck["policyengined"] == .liveProcessDetected)
        #expect(spawner.spawnedNames.isEmpty, "a live owner's daemon must never be spawned over, exactly like the no-record case")
        #expect(signaling.terminatedPIDs.isEmpty, "must never signal any process while its recorded owner is still alive")
    }

    // MARK: - P2M1-SEC-003: policy-unavailable never creates a permissive fallback

    @Test func sec003_healthAlwaysUnreachable_neverBecomesReady_staysFailedAfterTimeout() async {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        let health = FakeHealthChecking() // no result ever set -> always throws unreachable
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)

        await sup.startAll()

        #expect(await sup.state(for: "policyengined") == .failed)
        #expect(await sup.overall != .ready)
    }

    // MARK: - P2-PROD-BOOTSTRAP §B16: missing/unspawnable executable

    @Test func missingExecutable_spawnFailure_reportsFailedImmediately_neverHangs() async {
        let a = fastConfig(name: "policyengined")
        let spawner = FakeProcessSpawning()
        spawner.shouldFailToSpawn = ["policyengined"]
        let health = FakeHealthChecking()
        let sup = Supervisor(services: [a], spawner: spawner, healthChecker: health)

        await sup.startAll()

        #expect(await sup.state(for: "policyengined") == .failed)
        #expect(await sup.overall == .failed)
        #expect(spawner.spawnedNames.isEmpty, "a failed spawn must never be counted as a successful launch")
    }

    // MARK: - test helper

    private func waitFor(timeout: TimeInterval, condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }
}
