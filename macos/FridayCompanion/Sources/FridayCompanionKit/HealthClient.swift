import Foundation

/// A daemon's health as reported by its own real `Health` RPC — never
/// inferred from "the process exists" or "the socket file exists."
/// Matches Go's `map[string]bool{"alive": ..., "ready": ...}` shape
/// exactly (see `handleHealth` in both `policy-engine` and
/// `capability-bus`'s `internal/rpc/server.go`).
public struct DaemonHealth: Equatable, Sendable {
    public let alive: Bool
    public let ready: Bool
}

public protocol HealthChecking: Sendable {
    /// Returns the daemon's real, current health, or throws if the
    /// daemon is unreachable (socket doesn't exist, connection refused,
    /// timeout, malformed response). A thrown error and a returned
    /// `DaemonHealth(alive: false, ready: false)` are deliberately NOT
    /// conflated — the caller (`Supervisor`) treats both as "not ready,"
    /// but a thrown error additionally signals "no process is even
    /// listening," which matters for restart-vs-still-starting decisions.
    func checkHealth(socketPath: String) throws -> DaemonHealth
}

/// The real implementation, backed by `RPCFrameClient` — calls the
/// daemon's actual `Health` method over its actual Unix socket. This is
/// the ONLY code in `FridayCompanionKit` that talks to a live daemon; it
/// carries no key material, no capability/authorization concept, and no
/// path to `EvaluateAuthorization`/`Dispatch` — only `Health`.
public struct RealHealthClient: HealthChecking {
    public init() {}

    public func checkHealth(socketPath: String) throws -> DaemonHealth {
        let client = RPCFrameClient(socketPath: socketPath)
        let payload = try client.call(method: "Health")
        guard let alive = payload?["alive"]?.boolValue,
              let ready = payload?["ready"]?.boolValue else {
            throw RPCFrameError.malformedResponse("Health response missing alive/ready booleans")
        }
        return DaemonHealth(alive: alive, ready: ready)
    }
}
