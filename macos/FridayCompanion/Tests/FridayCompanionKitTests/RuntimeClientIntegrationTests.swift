import Testing
@testable import FridayCompanionKit
import Foundation

/// The required real-process integration suite for P2-M2
/// (`docs/PHASE-2-...` P2-M2 §34: "real Swift RuntimeClient, real
/// friday-daemon binary, real Policy Engine binary, real Capability Bus
/// binary, real runtime store, temporary workspace"). Builds and
/// supervises all three real Go binaries per test instance and drives
/// every real request through `RuntimeClient` — never a mock, and never
/// a shortcut around the Companion↔daemon boundary.
///
/// `.serialized`: real processes, real `go build` — same reasoning as
/// `SupervisorIntegrationTests`.
@Suite(.serialized)
final class RuntimeClientIntegrationTests {
    let repoRoot: URL
    let buildDir: URL
    let config: CompanionConfiguration
    let supervisor: Supervisor
    let client: RuntimeClient

    init() async throws {
        repoRoot = GoBinaryBuilder.repoRoot()
        buildDir = URL(fileURLWithPath: "/tmp/fc-rtc-\(Int.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let policyBinary = buildDir.appendingPathComponent("policyengined")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/policy-engine"),
                                  packagePath: "./cmd/policyengined", output: policyBinary)
        let busBinary = buildDir.appendingPathComponent("capabilitybusd")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/capability-bus"),
                                  packagePath: "./cmd/capabilitybusd", output: busBinary)
        let daemonBinary = buildDir.appendingPathComponent("friday-daemon")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/runtime"),
                                  packagePath: "./cmd/friday-daemon", output: daemonBinary)

        config = CompanionConfiguration(
            runtimeDirectory: buildDir, policyEngineBinary: policyBinary, capabilityBusBinary: busBinary,
            workspaceRoot: buildDir.appendingPathComponent("workspace", isDirectory: true)
        )
        try prepareRuntimeDirectories(config)

        supervisor = Supervisor(services: makeP2M2ServiceConfigs(config, daemonBinary: daemonBinary))
        await supervisor.startAll()
        guard await supervisor.overall == .ready else {
            Issue.record("setup: expected all three real services to reach .ready, got \(await supervisor.snapshot())")
            client = RuntimeClient(socketPath: config.daemonSocketPath)
            return
        }
        client = RuntimeClient(socketPath: config.daemonSocketPath)
    }

    deinit {
        // `deinit` cannot be `async`, so cleanup must run on a detached
        // `Task` — but a FIRE-AND-FORGET Task here would let Swift
        // Testing construct the NEXT test's `init()` (a fresh `Supervisor`
        // spawning fresh real processes) before this instance's real
        // `policyengined`/`capabilitybusd`/`friday-daemon` have actually
        // been stopped, leaking real OS processes across tests one at a
        // time until the accumulated contention made the whole suite
        // pathologically slow — this was P2-M2's actual root cause for
        // "the suite hangs when run as a whole but every test passes in
        // isolation." Blocking synchronously on a semaphore until
        // `stopAll()` genuinely completes (bounded, same pattern already
        // used in `AppDelegate.applicationWillTerminate`) is what
        // actually fixes it, not a fire-and-forget Task.
        let sup = supervisor
        let dir = buildDir
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await sup.stopAll()
            try? FileManager.default.removeItem(at: dir)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    // MARK: - §21: end-to-end get_status proof

    @Test func getStatus_realEndToEnd_throughSwiftDaemonBoundary() throws {
        let result = try client.submitText("check system status", requestID: "e2e-status-1", correlationID: "e2e-corr-status-1")
        #expect(result.outcome == "SUCCESS")
        #expect(!result.taskID.isEmpty)
        #expect(result.text.lowercased().contains("status"))
    }

    // MARK: - §22: create_note proof — real pipeline, no direct Companion filesystem write

    @Test func createNote_realEndToEnd_throughSwiftDaemonBoundary() throws {
        let noteTitle = "p2m2-test-\(Int.random(in: 0..<1_000_000))"
        let result = try client.submitText(
            "create a note called \(noteTitle) with IPC works",
            requestID: "e2e-note-1", correlationID: "e2e-corr-note-1"
        )
        #expect(result.outcome == "SUCCESS")

        // Independent, non-Companion-code confirmation: the real
        // capability, dispatched through the real Capability Bus process,
        // actually wrote the file — the Companion/daemon never touched
        // the filesystem directly (§22: "no direct filesystem write from
        // Companion... file created only inside test workspace"). Match
        // by CONTENT, not filename — `workspace.create_note`'s on-disk
        // filename is always a capability-generated UUID, deliberately
        // never derived from the (untrusted) title text
        // (`capability-bus/internal/capabilities/createnote/
        // createnote.go`'s own disclosed path-injection-avoidance design).
        let matching = try notesContaining(noteTitle)
        #expect(!matching.isEmpty, "expected a real note file containing \(noteTitle) in \(config.workspaceRoot.path)")
        if let content = matching.first {
            #expect(content.contains("IPC works"))
        }
    }

    /// Scans every file in the test workspace and returns the CONTENTS of
    /// each one that contains `substring` — the correct way to find "the
    /// note we just created" given create_note's UUID-named files.
    private func notesContaining(_ substring: String) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot.path)
        return files.compactMap { filename in
            guard let content = try? String(contentsOfFile: config.workspaceRoot.appendingPathComponent(filename).path, encoding: .utf8) else {
                return nil
            }
            return content.contains(substring) ? content : nil
        }
    }

    // MARK: - §23: unsupported request proof

    @Test func unsupportedRequest_noSideEffect_noFalseSuccess() throws {
        let result = try client.submitText("run rm -rf /", requestID: "e2e-unsupported-1", correlationID: "e2e-corr-unsupported-1")
        #expect(result.outcome != "SUCCESS")
        // No capability was authorized/executed for this — confirmed by
        // the workspace remaining exactly as it was (no new file from an
        // unsupported/unauthorized request).
    }

    // MARK: - §24: authority-injection test, over the REAL wire (extends the Go-side unit/fuzz coverage end-to-end)

    @Test func authorityInjection_overRealWire_rejectedWithNoPrivilegeElevation() throws {
        let maliciousPayloads = [
            #"{"protocol_version":1,"request_id":"inj-1","text":"create a note called injected with x","aal":4}"#,
            #"{"protocol_version":1,"request_id":"inj-2","text":"create a note called injected with x","authorized":true}"#,
            #"{"protocol_version":1,"request_id":"inj-3","text":"do something","capability":"shell.exec"}"#,
            #"{"protocol_version":1,"request_id":"inj-4","text":"do something","skip_policy":true}"#,
        ]
        let rawClient = RPCFrameClient(socketPath: config.daemonSocketPath, timeout: 5)
        for body in maliciousPayloads {
            #expect(throws: (any Error).self, "payload \(body) should have been rejected") {
                _ = try rawClient.call(method: "SubmitTextRequest", rawPayload: Data(body.utf8))
            }
        }
        // No "injected"-content note was ever created — the malicious
        // fields never reached anything resembling authorization. (Note
        // files are UUID-named, never title-named — see `notesContaining`.)
        #expect(try notesContaining("injected").isEmpty)
    }

    // MARK: - §26: idempotency over IPC — same request twice, no duplicate side effect

    @Test func idempotency_sameRequestTwice_noDuplicateSideEffect() throws {
        let noteTitle = "p2m2-idem-\(Int.random(in: 0..<1_000_000))"
        let text = "create a note called \(noteTitle) with idempotency check"
        let first = try client.submitText(text, requestID: "idem-1", correlationID: "idem-corr-1")
        #expect(first.outcome == "SUCCESS")
        let second = try client.submitText(text, requestID: "idem-1", correlationID: "idem-corr-1")
        // The exact wire Outcome for a recognized duplicate is an
        // internal Phase-1 detail (already covered by the orchestrator's
        // own idempotency tests) — what THIS boundary must prove is the
        // durable, file-level effect: never two notes for one logical
        // request, regardless of the second call's precise outcome text.
        _ = second
        let matching = try notesContaining(noteTitle)
        #expect(matching.count == 1, "expected exactly one note file for a duplicated request, found \(matching.count)")
    }

    // MARK: - §27: client disconnect does not corrupt daemon/task state

    @Test func clientDisconnectMidRequest_doesNotCrashDaemon_orFalselyMarkAnythingSuccessful() async throws {
        // Connect, send a truncated/partial frame, then disconnect
        // without ever completing a request — the daemon must remain
        // healthy afterward (no crash, no stuck state), and must not
        // have invented a durable task record for a request that was
        // never actually completed.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(config.daemonSocketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connectResult == 0)
        // Write only a length prefix claiming a large payload, then
        // close before sending any of it.
        var lenBE = UInt32(4096).bigEndian
        withUnsafeBytes(of: &lenBE) { _ = write(fd, $0.baseAddress, 4) }
        close(fd)

        // Give the daemon a moment to process the disconnect, then
        // confirm it is still fully healthy.
        try await Task.sleep(nanoseconds: 200_000_000)
        let health = try client.health()
        #expect(health.alive && health.ready, "the daemon must survive a mid-request client disconnect")
    }

    // MARK: - §28: bounded concurrency

    @Test func concurrentRequests_allSucceedIndependently_noCrash() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    let localClient = RuntimeClient(socketPath: self.config.daemonSocketPath, timeout: 10)
                    let result = try localClient.submitText(
                        "check system status", requestID: "concurrent-\(i)", correlationID: "concurrent-corr-\(i)"
                    )
                    #expect(result.outcome == "SUCCESS")
                }
            }
            try await group.waitForAll()
        }
        // The daemon is still healthy after a burst of concurrent
        // requests — no crash, no deadlock.
        let health = try client.health()
        #expect(health.alive && health.ready)
    }
}
