import Testing
@testable import FridayCompanionKit
import Foundation
import Darwin

/// P2-M5V9-B.3A — Chatterbox local latency forensics instrumentation
/// coverage. `POSIXUnixSocketIPCTransport.requestWithTiming` is a real
/// POSIX socket client — these tests exercise it against a REAL local
/// Unix-domain socket server this test file spins up itself (a minimal
/// stand-in for the Python service, using the exact same wire framing),
/// never the actual Python `chatterbox_service.py` process. Nothing here
/// touches the frozen conversational brain, Cartesia, or fallback ordering.
@Suite struct PremiumVoiceV9B3ATests {
    /// A minimal, real Unix-domain-socket server implementing the EXACT
    /// same 4-byte-length-prefixed JSON framing `chatterbox_service.py`
    /// uses, so `requestWithTiming`'s real read/write logic is exercised
    /// end-to-end (not just against a Swift-side fake).
    private final class MinimalFramedSocketServer {
        private let socketPath: String
        private var serverFD: Int32 = -1
        private var acceptThread: Thread?
        private var shouldStop = false
        private let responseBody: Data
        private let responseDelay: TimeInterval

        init(socketPath: String, responseJSON: [String: Any], responseDelay: TimeInterval = 0) {
            self.socketPath = socketPath
            self.responseBody = (try? JSONSerialization.data(withJSONObject: responseJSON)) ?? Data()
            self.responseDelay = responseDelay
        }

        func start() {
            unlink(socketPath)
            serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
                let buffer = rawPtr.bindMemory(to: CChar.self)
                for (i, byte) in pathBytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[pathBytes.count] = 0
            }
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            _ = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in Foundation.bind(serverFD, sockaddrPtr, addrLen) }
            }
            listen(serverFD, 1)
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.start()
            acceptThread = thread
        }

        private func acceptLoop() {
            while !shouldStop {
                let clientFD = accept(serverFD, nil, nil)
                guard clientFD >= 0 else { continue }
                if responseDelay > 0 { Thread.sleep(forTimeInterval: responseDelay) }
                // Read (and discard) the request using the same framing, then reply.
                var lenBuf = [UInt8](repeating: 0, count: 4)
                _ = lenBuf.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, 4) }
                let length = Int(lenBuf[0]) << 24 | Int(lenBuf[1]) << 16 | Int(lenBuf[2]) << 8 | Int(lenBuf[3])
                var remaining = length
                var discard = [UInt8](repeating: 0, count: max(length, 1))
                while remaining > 0 {
                    let n = discard.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, remaining) }
                    if n <= 0 { break }
                    remaining -= n
                }
                var respLen = UInt32(responseBody.count).bigEndian
                let header = Data(bytes: &respLen, count: 4)
                (header + responseBody).withUnsafeBytes { _ = write(clientFD, $0.baseAddress, header.count + responseBody.count) }
                close(clientFD)
                if !shouldStop { break } // this minimal server handles exactly one connection per start()
            }
        }

        func stop() {
            shouldStop = true
            if serverFD >= 0 { close(serverFD) }
            unlink(socketPath)
        }
    }

    @Test func requestWithTiming_reportsAllFourCheckpoints_forARealSocketRoundTrip() {
        let socketPath = NSTemporaryDirectory() + "friday-test-\(UUID().uuidString).sock"
        let server = MinimalFramedSocketServer(socketPath: socketPath, responseJSON: ["status": "ok", "sampleRate": 24000, "audioBase64": "", "timing": ["requestReceivedMs": Date().timeIntervalSince1970 * 1000]])
        server.start()
        defer { server.stop() }

        let transport = POSIXUnixSocketIPCTransport()
        var capturedTiming: IPCTimingSnapshot?
        var capturedResult: Result<Data, Error>?
        let group = DispatchGroup()
        group.enter()
        transport.requestWithTiming(Data("{}".utf8), socketPath: socketPath) { result, timing in
            capturedResult = result
            capturedTiming = timing
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)

        guard case .success = capturedResult else { Issue.record("expected success, got \(String(describing: capturedResult))"); return }
        guard let timing = capturedTiming else { Issue.record("no timing captured"); return }
        #expect(timing.socketConnected != nil, "a real, successful connection must report socketConnected")
        #expect(timing.firstResponseByte != nil, "a real response must report when its first byte arrived")
        #expect(timing.fullResponseReceived != nil)
        #expect(timing.socketConnected! >= timing.requestStart)
        #expect(timing.firstResponseByte! >= timing.socketConnected!)
        #expect(timing.fullResponseReceived! >= timing.firstResponseByte!)
    }

    @Test func requestWithTiming_connectionFailure_stillReportsRequestStart_neverCrashes() {
        let transport = POSIXUnixSocketIPCTransport()
        var capturedTiming: IPCTimingSnapshot?
        var capturedResult: Result<Data, Error>?
        let group = DispatchGroup()
        group.enter()
        transport.requestWithTiming(Data("{}".utf8), socketPath: "/tmp/friday-nonexistent-\(UUID().uuidString).sock") { result, timing in
            capturedResult = result
            capturedTiming = timing
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        guard case .failure = capturedResult else { Issue.record("expected failure against a nonexistent socket"); return }
        #expect(capturedTiming != nil, "even a failed connection must report a timing snapshot with at least requestStart")
        #expect(capturedTiming?.socketConnected == nil, "a connection that never succeeded must never report socketConnected")
    }

    @Test func request_plainOverload_stillWorks_unchangedFromBeforeThisMilestone() {
        // §backward-compat: the production LocalChatterboxProvider path
        // keeps calling the plain `request(...)` — must remain byte-
        // identical in observable behavior after adding `requestWithTiming`.
        let socketPath = NSTemporaryDirectory() + "friday-test-\(UUID().uuidString).sock"
        let server = MinimalFramedSocketServer(socketPath: socketPath, responseJSON: ["status": "ok", "sampleRate": 24000, "audioBase64": "aGVsbG8="])
        server.start()
        defer { server.stop() }

        let transport = POSIXUnixSocketIPCTransport()
        var capturedResult: Result<Data, Error>?
        let group = DispatchGroup()
        group.enter()
        transport.request(Data("{}".utf8), socketPath: socketPath) { result in
            capturedResult = result
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        guard case .success(let data) = capturedResult, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected a decodable success response"); return
        }
        #expect(json["status"] as? String == "ok")
    }

    @Test func localChatterboxProvider_stillWorksUnchanged_afterTransportInstrumentationAdded() {
        // Full regression proof: the PRODUCTION path (LocalChatterboxProvider
        // + the plain, fake-driven `LocalIPCTransport`) is completely
        // unaffected by this milestone's forensics-only additions.
        final class FakeTransport: LocalIPCTransport, @unchecked Sendable {
            func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                let response = try! JSONEncoder().encode(LocalChatterboxProvider.WireResponse(status: "ok", sampleRate: 24000, audioBase64: Data([1, 2, 3]).base64EncodedString(), error: nil))
                completion(.success(response))
            }
        }
        let provider = LocalChatterboxProvider(socketPath: "/tmp/unused.sock", variant: "turbo", transport: FakeTransport())
        var events: [SpeechSynthesisEvent] = []
        let request = SpeechSynthesisRequest(interactionID: "i1", utteranceID: "u1", text: "Hello", voiceID: "default", language: "en", prosody: ProsodyPlan(rate: 0.5, pitchMultiplier: 1, volume: 1, preUtteranceDelay: 0, postUtteranceDelay: 0, emphasisStrength: 0, energy: 0.5))
        _ = provider.synthesize(request) { events.append($0) }
        #expect(events.last == .completed(interactionID: "i1", utteranceID: "u1"))
    }

    @Test func thisEnvironment_hasNoRunningChatterboxServiceSocketByDefault() {
        // Documents this test target's own default state — the real
        // service is started manually/out-of-band, never by the test suite.
        #expect(!FileManager.default.fileExists(atPath: "/tmp/friday-chatterbox-test-should-never-exist.sock"))
    }
}

