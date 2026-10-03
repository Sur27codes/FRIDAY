import Foundation

/// A minimal, dependency-free Swift client for the exact same wire
/// protocol `friday/rpcframe` implements in Go (see
/// `services/rpcframe/frame.go`): a 4-byte big-endian `uint32` length
/// prefix followed by exactly that many bytes of JSON, one
/// request-then-response-then-close per call, over a Unix domain socket.
///
/// This is deliberately NOT security logic — same discipline as the Go
/// package it mirrors. It has no concept of authorization, capabilities,
/// signatures, or tokens; it only moves bytes reliably. As of P2-M2 it
/// calls two methods — `Health` (all three daemons) and
/// `SubmitTextRequest` (friday-daemon only, via `RuntimeClient`) — and
/// nothing resembling a capability-bus or policy-engine method name. It
/// reimplements nothing from `friday/policytoken` or the Policy Engine's
/// decision logic — those stay exclusively in Go, per the Phase-2
/// architecture's explicit "Swift should consume runtime/service status
/// and lifecycle contracts; authorization stays in Go Policy Engine"
/// rule (`docs/PHASE-2-ARCHITECTURE.md` §16).
public enum RPCFrameError: Error, Equatable {
    case connectFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case frameTooLarge
    case malformedResponse(String)
}

/// Mirrors Go's `rpc.Envelope` (see
/// `services/policy-engine/internal/rpc/protocol.go` /
/// `services/capability-bus/internal/rpc/protocol.go`) — both daemons use
/// the identical shape, confirmed by direct inspection of both server
/// implementations before this client was written (not assumed).
struct RPCEnvelope: Codable {
    var method: String
    var payload: JSONValue?
    var error: RPCEnvelopeError?
}

struct RPCEnvelopeError: Codable {
    var code: String
    var message: String
}

/// A tiny untyped-JSON box, since this client only ever needs to read
/// `{"alive": bool, "ready": bool}` out of `payload` — a full JSON model
/// layer is unneeded machinery for one health-check call.
public enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case bool(Bool)
    case string(String)
    case number(Double)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}

/// One request/response call over a Unix domain socket, framed exactly
/// like `friday/rpcframe`. Every failure path returns a non-nil error —
/// there is no partial-success value a caller could mistake for a real
/// response, matching the Go package's own stated invariant.
public struct RPCFrameClient: Sendable {
    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 3.0) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// Calls `method` with no payload — matches the Health RPC's actual
    /// usage on all three daemons (`{"method":"Health"}` in, `{"method":
    /// "Health","payload":{"alive":true,"ready":true}}` out) — confirmed
    /// against the real server handlers before this was written.
    public func call(method: String) throws -> JSONValue? {
        try call(method: method, rawPayload: nil)
    }

    /// Calls `method`, sending `rawPayload` (already-encoded JSON bytes,
    /// e.g. from `JSONEncoder().encode(someCodableStruct)`) as the
    /// envelope's `payload` field verbatim — used by `RuntimeClient` to
    /// submit a `SubmitTextRequest` without round-tripping the request
    /// through the untyped `JSONValue` box first.
    public func call(method: String, rawPayload: Data?) throws -> JSONValue? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RPCFrameError.connectFailed("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw RPCFrameError.connectFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { buf in
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
            }
        }

        // Apply a socket-level receive/send timeout so a hung/hostile
        // peer cannot block the caller indefinitely — the Go server
        // itself already bounds each connection to 10s (see
        // `handleConn`'s `conn.SetDeadline`), this is the client-side
        // mirror of that same discipline.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw RPCFrameError.connectFailed("connect() failed: errno \(errno)")
        }

        let reqData: Data
        if let rawPayload {
            // Embed the already-valid JSON payload verbatim rather than
            // decoding it into a `JSONValue` tree only to re-encode it —
            // `method` is always a fixed, simple identifier this package
            // itself chooses (never derived from untrusted input), so no
            // JSON string-escaping beyond this is needed.
            var bytes = Data("{\"method\":\"\(method)\",\"payload\":".utf8)
            bytes.append(rawPayload)
            bytes.append(Data("}".utf8))
            reqData = bytes
        } else {
            let req = RPCEnvelope(method: method, payload: nil, error: nil)
            reqData = try JSONEncoder().encode(req)
        }
        try writeFrame(fd: fd, payload: reqData)

        let respData = try readFrame(fd: fd)
        let resp = try JSONDecoder().decode(RPCEnvelope.self, from: respData)
        if let e = resp.error {
            throw RPCFrameError.malformedResponse("\(e.code): \(e.message)")
        }
        return resp.payload
    }

    private func writeFrame(fd: Int32, payload: Data) throws {
        guard payload.count <= 4 << 20 else { throw RPCFrameError.frameTooLarge }
        var lenBE = UInt32(payload.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        let full = lenData + payload
        try full.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw RPCFrameError.writeFailed("write() failed: errno \(errno)") }
                offset += n
            }
        }
    }

    private func readFrame(fd: Int32) throws -> Data {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExactly(fd: fd, into: &lenBuf, count: 4)
        let n = lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard n <= 4 << 20 else { throw RPCFrameError.frameTooLarge }
        var payloadBuf = [UInt8](repeating: 0, count: Int(n))
        if n > 0 { try readExactly(fd: fd, into: &payloadBuf, count: Int(n)) }
        return Data(payloadBuf)
    }

    private func readExactly(fd: Int32, into buf: inout [UInt8], count: Int) throws {
        var offset = 0
        try buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let n = read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if n <= 0 { throw RPCFrameError.readFailed("read() failed or EOF: errno \(errno)") }
                offset += n
            }
        }
    }
}
