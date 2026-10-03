import Testing
@testable import FridayCompanionKit
import Foundation

/// Fast, no-real-daemon-needed tests of the RPC transport's failure
/// paths — the real-daemon round trip is covered by
/// `SupervisorIntegrationTests` (which also proves the exact wire shape
/// matches the real Go servers, not just this client's own assumptions).
@Suite struct HealthClientTests {

    @Test func connectingToNonexistentSocket_throws_notCrashes() {
        let client = RealHealthClient()
        #expect(throws: (any Error).self) {
            try client.checkHealth(socketPath: "/tmp/friday-companion-tests-definitely-not-a-real-socket-\(UUID().uuidString)")
        }
    }

    @Test func rpcFrameClient_toNonexistentSocket_throwsConnectFailed() {
        let client = RPCFrameClient(socketPath: "/tmp/friday-companion-tests-definitely-not-a-real-socket-\(UUID().uuidString)", timeout: 1)
        #expect(throws: RPCFrameError.self) { try client.call(method: "Health") }
    }

    /// A minimal fake server, hand-rolled with the exact same
    /// length-prefixed-JSON framing, so this test can assert the
    /// client's happy-path decode against a shape we fully control —
    /// distinct from (and in addition to) the real-daemon integration
    /// coverage.
    @Test func rpcFrameClient_decodesRealShapedHealthResponse() async throws {
        // Deliberately `/tmp/...` (short), not `FileManager.default
        // .temporaryDirectory` (a long, per-app-container path on
        // macOS) — a Unix-domain socket path is capped at 104 bytes
        // (`sizeof(sockaddr_un.sun_path)`), and the long form reliably
        // exceeds that, the same class of bug already documented
        // elsewhere in this project (see the Go-side note about
        // `bind: invalid argument` from an overlong scratchpad path).
        let socketPath = "/tmp/fc-health-\(Int.random(in: 0..<1_000_000)).sock"

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(serverFD); try? FileManager.default.removeItem(atPath: socketPath) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bindResult == 0)
        #expect(listen(serverFD, 1) == 0)

        let serverTask = Task.detached {
            let connFD = accept(serverFD, nil, nil)
            guard connFD >= 0 else { return }
            defer { close(connFD) }
            var lenBuf = [UInt8](repeating: 0, count: 4)
            _ = lenBuf.withUnsafeMutableBytes { read(connFD, $0.baseAddress, 4) }
            let n = Int(lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
            var reqBuf = [UInt8](repeating: 0, count: n)
            if n > 0 { _ = reqBuf.withUnsafeMutableBytes { read(connFD, $0.baseAddress, n) } }

            let responseJSON = Data(#"{"method":"Health","payload":{"alive":true,"ready":true}}"#.utf8)
            var respLen = UInt32(responseJSON.count).bigEndian
            let respLenData = Data(bytes: &respLen, count: 4)
            let full = respLenData + responseJSON
            full.withUnsafeBytes { _ = write(connFD, $0.baseAddress, full.count) }
        }

        let client = RPCFrameClient(socketPath: socketPath, timeout: 3)
        let payload = try client.call(method: "Health")
        _ = await serverTask.value

        #expect(payload?["alive"]?.boolValue == true)
        #expect(payload?["ready"]?.boolValue == true)
    }
}
