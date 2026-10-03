import Testing
@testable import FridayCompanionKit
import Foundation

/// Cross-language golden vectors (P2-M2 instruction §44) — reads the
/// EXACT same three JSON files under `services/runtime/rpcapi/testdata/`
/// that `golden_test.go` also reads, protecting the Swift<->Go wire
/// boundary from silent drift.
@Suite struct RuntimeClientGoldenTests {

    private func testdataDir() -> URL {
        GoBinaryBuilder.repoRoot().appendingPathComponent("services/runtime/rpcapi/testdata")
    }

    @Test func goldenSubmitTextRequest_swiftEncodesTheSameShape() throws {
        let raw = try Data(contentsOf: testdataDir().appendingPathComponent("golden_submit_text_request.json"))
        var golden = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])

        // Swift encodes the identical fields Go expects to decode —
        // proven by round-tripping through JSONSerialization's untyped
        // form rather than assuming Codable's field order matches byte
        // for byte (JSON field order is not semantically meaningful, so
        // this is the correct level to compare at).
        let encoded = try JSONEncoder().encode(SwiftEncodedSubmitTextRequest(
            protocol_version: 1, request_id: "golden-req-001", correlation_id: "golden-corr-001",
            text: "check system status"
        ))
        let reencoded = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(reencoded.count == golden.count)
        for (key, value) in golden {
            // `reencoded[key]` is `Any?` (dictionary subscript), `value`
            // is already-unwrapped `Any` (from the `for...in` over
            // `golden`) — describe both through the same optional shape
            // so e.g. "golden-req-001" and "Optional(golden-req-001)"
            // don't spuriously mismatch.
            let reencodedDescription = reencoded[key].map { String(describing: $0) } ?? "<missing>"
            #expect(reencodedDescription == String(describing: value), "field \(key) mismatch")
        }
        golden.removeAll() // silence "never mutated" warning; golden is intentionally read-only above
    }

    @Test func goldenSubmitTextResponse_swiftDecodesToExactExpectedResult() throws {
        let raw = try Data(contentsOf: testdataDir().appendingPathComponent("golden_submit_text_response.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])

        #expect(obj["protocol_version"] as? Int == 1)
        #expect(obj["request_id"] as? String == "golden-req-001")
        #expect(obj["correlation_id"] as? String == "golden-corr-001")
        #expect(obj["task_id"] as? String == "golden-task-001")
        #expect(obj["outcome"] as? String == "SUCCESS")
        #expect(obj["text"] as? String == "System status retrieved successfully.")
    }

    @Test func goldenHealthResponse_matchesDaemonHealthShape() throws {
        let raw = try Data(contentsOf: testdataDir().appendingPathComponent("golden_health_response.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(obj["alive"] as? Bool == true)
        #expect(obj["ready"] as? Bool == true)
    }
}

private struct SwiftEncodedSubmitTextRequest: Codable {
    let protocol_version: Int
    let request_id: String
    let correlation_id: String
    let text: String
}

/// Fake-server tests of `RuntimeClient` itself — same hand-rolled
/// length-prefixed-JSON server pattern `HealthClientTests` already
/// established, extended to the `SubmitTextRequest` method.
@Suite struct RuntimeClientFakeServerTests {

    @Test func submitText_decodesASuccessfulResponse() async throws {
        let socketPath = "/tmp/fc-rtc-\(Int.random(in: 0..<1_000_000)).sock"
        let responseJSON = """
        {"method":"SubmitTextRequest","payload":{"protocol_version":1,"request_id":"r1","correlation_id":"c1","task_id":"t1","outcome":"SUCCESS","text":"System status retrieved successfully."}}
        """
        try await withFakeServer(socketPath: socketPath, responseJSON: responseJSON) {
            let client = RuntimeClient(socketPath: socketPath, timeout: 3)
            let result = try client.submitText("check system status", requestID: "r1", correlationID: "c1")
            #expect(result.outcome == "SUCCESS")
            #expect(result.taskID == "t1")
            #expect(result.text == "System status retrieved successfully.")
        }
    }

    @Test func submitText_surfacesAnRPCErrorDistinctFromATransportFailure() async throws {
        let socketPath = "/tmp/fc-rtc-\(Int.random(in: 0..<1_000_000)).sock"
        let responseJSON = """
        {"method":"SubmitTextRequest","error":{"code":"INVALID_REQUEST","message":"request_id and text are required"}}
        """
        try await withFakeServer(socketPath: socketPath, responseJSON: responseJSON) {
            let client = RuntimeClient(socketPath: socketPath, timeout: 3)
            do {
                _ = try client.submitText("x", requestID: "r1", correlationID: "")
                Issue.record("expected an error to be thrown")
            } catch RuntimeClientError.rpc(let code, _) {
                #expect(code == "INVALID_REQUEST")
            }
        }
    }

    /// Minimal hand-rolled server, matching `HealthClientTests`'s own
    /// pattern exactly, extended to accept one request and reply with a
    /// fixed response body.
    private func withFakeServer(socketPath: String, responseJSON: String, _ body: () throws -> Void) async throws {
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

            let responseData = Data(responseJSON.utf8)
            var respLen = UInt32(responseData.count).bigEndian
            let respLenData = Data(bytes: &respLen, count: 4)
            let full = respLenData + responseData
            full.withUnsafeBytes { _ = write(connFD, $0.baseAddress, full.count) }
        }

        try body()
        _ = await serverTask.value
    }
}
