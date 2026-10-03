import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// P2-M5V9-B.2 §10 — the local IPC transport seam, mirroring every other
/// provider's "protocol + real implementation + fakeable in tests" shape.
/// One request, one response — this is a SYNCHRONOUS local round trip
/// (§10: "local IPC," never a network stream), so it never claims
/// streaming (see `LocalChatterboxProvider.capabilities` below).
public protocol LocalIPCTransport: Sendable {
    func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void)
    /// P2-M5V9-B.3B — promoted to the protocol (was previously a
    /// `POSIXUnixSocketIPCTransport`-only concrete method) so
    /// `LocalChatterboxSpeechSynthesizer` can depend on the PROTOCOL,
    /// not a concrete type, and stay fakeable in tests. A default
    /// implementation is provided below for any conformer that doesn't
    /// need per-phase timing.
    func requestWithTiming(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>, IPCTimingSnapshot) -> Void)
}

public extension LocalIPCTransport {
    /// Default: only `requestStart`/`fullResponseReceived` are known —
    /// sufficient for conformers (e.g. test fakes) that don't model
    /// per-phase timing. `POSIXUnixSocketIPCTransport` overrides this
    /// with real, per-phase instrumentation (§4 of P2-M5V9-B.3A).
    func requestWithTiming(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>, IPCTimingSnapshot) -> Void) {
        let start = Date()
        request(payload, socketPath: socketPath) { result in
            completion(result, IPCTimingSnapshot(requestStart: start, fullResponseReceived: Date()))
        }
    }
}

/// P2-M5V9-B.3A §4 — client-side timing checkpoints for one IPC round
/// trip, forensics-only (never used by the production `LocalChatterboxProvider`
/// path, which keeps calling the plain `request(...)` above, byte-
/// identical to before this milestone). All `Date`s are wall-clock on
/// THIS machine, directly comparable to the paired Python service's own
/// `time.time()` timestamps (same host, no NTP-drift concern at the
/// multi-millisecond granularities this benchmark cares about).
public struct IPCTimingSnapshot: Sendable, Equatable {
    public var requestStart: Date
    public var socketConnected: Date?
    /// The first byte of the RESPONSE actually arriving off the wire —
    /// distinct from `fullResponseReceived`, so IPC transmission time for
    /// a large (multi-MB base64 audio) payload is separately visible.
    public var firstResponseByte: Date?
    public var fullResponseReceived: Date?

    public init(requestStart: Date, socketConnected: Date? = nil, firstResponseByte: Date? = nil, fullResponseReceived: Date? = nil) {
        self.requestStart = requestStart
        self.socketConnected = socketConnected
        self.firstResponseByte = firstResponseByte
        self.fullResponseReceived = fullResponseReceived
    }
}

public enum LocalIPCError: Error, Sendable, Equatable {
    case socketCreationFailed
    case connectFailed(String)
    case ioFailed(String)
    case malformedFraming
}

/// The real, working implementation — plain POSIX `AF_UNIX` `SOCK_STREAM`
/// sockets (no third-party dependency, no `Network.framework` needed;
/// §10: "prefer Unix-domain socket... never expose the local TTS service
/// publicly" — an `AF_UNIX` path-based socket is unreachable from any
/// other host by construction). Wire framing is a simple 4-byte
/// big-endian length prefix followed by that many bytes of UTF-8 JSON,
/// symmetric on both request and response — a small, explicit, easy-to-
/// implement-on-the-Python-side contract (see this milestone's own STOP
/// report for the corresponding minimal Python service this pairs with).
public struct POSIXUnixSocketIPCTransport: LocalIPCTransport {
    public init() {}

    public func request(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        requestWithTiming(payload, socketPath: socketPath) { result, _ in completion(result) }
    }

    /// P2-M5V9-B.3A §4 — forensics-only sibling of `request(...)` above:
    /// the EXACT SAME real POSIX round trip (byte-for-byte identical
    /// connect/write/read sequence — `request` now just calls this and
    /// discards the timing), additionally reporting client-side timing
    /// checkpoints for `chatterbox-warm-benchmark`'s own use. No
    /// production call site uses this — `LocalChatterboxProvider` still
    /// calls the plain `request(...)`, unchanged.
    public func requestWithTiming(_ payload: Data, socketPath: String, completion: @escaping @Sendable (Result<Data, Error>, IPCTimingSnapshot) -> Void) {
        let requestStart = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let (result, timing) = Self.performBlocking(payload, socketPath: socketPath, requestStart: requestStart)
            completion(result, timing)
        }
    }

    private static func performBlocking(_ payload: Data, socketPath: String, requestStart: Date) -> (Result<Data, Error>, IPCTimingSnapshot) {
        var timing = IPCTimingSnapshot(requestStart: requestStart)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (.failure(LocalIPCError.socketCreationFailed), timing) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return (.failure(LocalIPCError.connectFailed("socket path too long")), timing)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
            buffer[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            return (.failure(LocalIPCError.connectFailed(String(cString: strerror(errno)))), timing)
        }
        timing.socketConnected = Date()

        var lengthPrefix = UInt32(payload.count).bigEndian
        let headerData = Data(bytes: &lengthPrefix, count: 4)
        guard writeAll(fd: fd, data: headerData), writeAll(fd: fd, data: payload) else {
            return (.failure(LocalIPCError.ioFailed("write failed: \(String(cString: strerror(errno)))")), timing)
        }

        var firstByteMarked = false
        let markFirstByte = { if !firstByteMarked { timing.firstResponseByte = Date(); firstByteMarked = true } }
        guard let responseLengthData = readExactly(fd: fd, count: 4, onFirstByte: markFirstByte) else {
            return (.failure(LocalIPCError.ioFailed("failed to read response length")), timing)
        }
        let responseLength = responseLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard responseLength > 0, responseLength < 200_000_000 else { // sanity bound, mirrors AudioChunkValidator's own spirit
            return (.failure(LocalIPCError.malformedFraming), timing)
        }
        guard let responseData = readExactly(fd: fd, count: Int(responseLength), onFirstByte: markFirstByte) else {
            return (.failure(LocalIPCError.ioFailed("failed to read response body")), timing)
        }
        timing.fullResponseReceived = Date()
        return (.success(responseData), timing)
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            var remaining = rawBuffer.count
            var offset = 0
            let base = rawBuffer.baseAddress!
            while remaining > 0 {
                let written = Darwin_write_compat(fd, base + offset, remaining)
                if written <= 0 { return false }
                remaining -= written
                offset += written
            }
            return true
        }
    }

    private static func readExactly(fd: Int32, count: Int, onFirstByte: (() -> Void)? = nil) -> Data? {
        var buffer = Data(count: count)
        var totalRead = 0
        let success = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            let base = rawBuffer.baseAddress!
            while totalRead < count {
                let n = Darwin_read_compat(fd, base + totalRead, count - totalRead)
                if n <= 0 { return false }
                if totalRead == 0 { onFirstByte?() }
                totalRead += n
            }
            return true
        }
        return success ? buffer : nil
    }
}

// Thin, explicitly-named wrappers around the raw POSIX calls — kept
// separate so the intent (blocking, byte-oriented socket I/O) reads
// clearly at each call site above, with no ambiguity against
// `FileHandle`/higher-level Foundation I/O.
private func Darwin_write_compat(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #else
    return Glibc.write(fd, buffer, count)
    #endif
}
private func Darwin_read_compat(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buffer, count)
    #else
    return Glibc.read(fd, buffer, count)
    #endif
}

/// P2-M5V9-B.2 §10/§11 — the Swift-side adapter behind the EXISTING,
/// unchanged `PremiumSpeechStreamProviding` abstraction, talking to a
/// local Python Chatterbox process over `LocalIPCTransport`. A full
/// audio clip is generated per request and delivered as ONE `.audioChunk`
/// event — never chunked to simulate streaming (§19 of this milestone
/// generalizes Cartesia's own "never fake streaming" rule: `capabilities.streaming`
/// is honestly `false`).
public struct LocalChatterboxProvider: PremiumSpeechStreamProviding {
    /// The minimal wire response contract the paired local Python service
    /// (see this milestone's STOP report) is expected to return.
    public struct WireResponse: Codable, Sendable {
        public let status: String // "ok" | "error"
        public let sampleRate: Int?
        public let audioBase64: String?
        public let error: String?
        public init(status: String, sampleRate: Int?, audioBase64: String?, error: String?) {
            self.status = status
            self.sampleRate = sampleRate
            self.audioBase64 = audioBase64
            self.error = error
        }
    }
    private struct WireRequest: Encodable {
        let text: String
        let language: String
        let variant: String // "turbo" | "base" (Nano-equivalent) | "multilingual"
    }

    private let socketPath: String
    private let variant: String
    private let transport: LocalIPCTransport

    /// Never claims `streaming`/`ssml`/`nativeProsody` — a local
    /// synchronous inference call genuinely has none of those (§19).
    public let capabilities = PremiumSpeechCapabilities(
        streaming: false, cancellation: false, nativeProsody: false, speakingStyles: false, pronunciationControl: false,
        ssml: false, wordTimestamps: false, sentenceTimestamps: false, sampleRates: [24000], audioFormats: ["pcm_f32le"],
        voiceSelection: false, customVoice: true, localeSupport: []
    )

    public init(socketPath: String, variant: String, transport: LocalIPCTransport = POSIXUnixSocketIPCTransport()) {
        self.socketPath = socketPath
        self.variant = variant
        self.transport = transport
    }

    public func synthesize(_ request: SpeechSynthesisRequest, onEvent: @escaping @Sendable (SpeechSynthesisEvent) -> Void) -> SpeechProviderCancelToken {
        let wireRequest = WireRequest(text: request.text, language: request.language, variant: variant)
        guard let body = try? JSONEncoder().encode(wireRequest) else {
            onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .invalidResponse))
            return SpeechProviderCancelToken(cancelAction: {})
        }
        onEvent(.started(interactionID: request.interactionID, utteranceID: request.utteranceID))
        transport.request(body, socketPath: socketPath) { result in
            switch result {
            case .success(let data):
                guard let response = try? JSONDecoder().decode(WireResponse.self, from: data) else {
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .invalidResponse))
                    return
                }
                guard response.status == "ok", let base64 = response.audioBase64, let audio = Data(base64Encoded: base64) else {
                    // §11: "do not invent support for unsupported
                    // languages" — an honest local rejection (e.g. the
                    // requested language isn't in the installed
                    // Chatterbox model's registry) surfaces as a real,
                    // sanitized failure category, never a silent no-op.
                    onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .unsupportedVoice))
                    return
                }
                onEvent(.audioChunk(interactionID: request.interactionID, utteranceID: request.utteranceID, samples: audio, sequence: 0))
                onEvent(.completed(interactionID: request.interactionID, utteranceID: request.utteranceID))
            case .failure:
                onEvent(.failed(interactionID: request.interactionID, utteranceID: request.utteranceID, category: .network))
            }
        }
        // A synchronous local round trip has no meaningful mid-flight
        // cancellation point (§10 capabilities.cancellation == false,
        // matching the honest streaming==false above) — `cancel()` is a
        // structural no-op; the caller's own `UtteranceIdentityGuard`
        // still discards the eventual result if a newer turn has begun.
        return SpeechProviderCancelToken(cancelAction: {})
    }
}
