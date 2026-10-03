import Foundation

/// The result of a text request submitted through `friday-daemon` — a
/// direct mirror of Go's `rpcapi.SubmitTextRequestResponseWire`, which is
/// itself a direct, unmodified pass-through of the existing, already
/// verification-gated `response.Response` (P2-M2 instruction §10: this
/// type never independently manufactures a success — it only decodes
/// what the real Response Validation Gate already decided).
public struct RuntimeTextResult: Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let correlationID: String
    public let taskID: String
    public let outcome: String
    public let text: String

    /// P2-M5V6 — an explicit `public init` (the implicit memberwise one
    /// is `internal`, since every existing production call site
    /// constructing this type lives inside `FridayCompanionKit` itself)
    /// so `VoiceAuditionTool`'s conversation harness (§25/§26, a
    /// different module, no `@testable import`) can construct scenario
    /// fixtures directly, without needing a real daemon round-trip.
    public init(protocolVersion: Int, requestID: String, correlationID: String, taskID: String, outcome: String, text: String) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.correlationID = correlationID
        self.taskID = taskID
        self.outcome = outcome
        self.text = text
    }
}

public enum RuntimeClientError: Error, Equatable {
    case transport(String)
    case rpc(code: String, message: String)
}

/// The Companion's ONLY path to the Phase-1 runtime. `RuntimeClient`
/// talks exclusively to `friday-daemon`'s socket — it has no method
/// resembling `executeCapability()`, `signAuthorization()`,
/// `callCapabilityBus()`, `writeWorkspaceFile()`, or `setAAL()` (P2-M2
/// instruction §19), and its two methods (`health`, `submitText`) are
/// the entire client-side surface this milestone introduces.
public struct RuntimeClient: Sendable {
    public let socketPath: String
    private let frameClient: RPCFrameClient

    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.frameClient = RPCFrameClient(socketPath: socketPath, timeout: timeout)
    }

    /// Calls the daemon's real `Health` RPC — the exact same method
    /// `HealthClient` already calls against `policyengined`/
    /// `capabilitybusd`, now against `friday-daemon` too, since all
    /// three daemons share the identical `{"alive":bool,"ready":bool}`
    /// shape.
    public func health() throws -> DaemonHealth {
        let payload: JSONValue?
        do {
            payload = try frameClient.call(method: "Health")
        } catch let e as RPCFrameError {
            throw RuntimeClientError.transport(String(describing: e))
        }
        guard let alive = payload?["alive"]?.boolValue, let ready = payload?["ready"]?.boolValue else {
            throw RuntimeClientError.transport("Health response missing alive/ready booleans")
        }
        return DaemonHealth(alive: alive, ready: ready)
    }

    /// Submits untrusted natural-language text through the real Phase-1
    /// pipeline. The request carries ONLY protocol_version/request_id/
    /// correlation_id/text — no field here can express an authorization
    /// decision, an AAL/assurance claim, a capability selection, or a
    /// risk override (P2-M2 instruction §7); the wire type
    /// (`SubmitTextRequestWireOut`) has no such field to set even if a
    /// caller wanted to.
    ///
    /// P2-M4R: `correlationID` deliberately has NO default value anymore.
    /// A real production bug traced every voice command's silently-empty
    /// default `correlationID` all the way to a permanently-orphaned
    /// server-side idempotency record (`docs/E-traceability-matrix.md`'s
    /// P2-M4R section has the full mechanism) — the orchestrator's own
    /// `IdempotencyKey` is `correlation_id + capability + arguments`, so
    /// an empty, constant `correlation_id` collapses every call to a
    /// zero-argument capability into the SAME key forever. Every caller
    /// must now supply a real, request-unique value.
    public func submitText(_ text: String, requestID: String, correlationID: String) throws -> RuntimeTextResult {
        let reqPayload = SubmitTextRequestWireOut(
            protocol_version: 1, request_id: requestID, correlation_id: correlationID, text: text
        )
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(reqPayload)
        } catch {
            throw RuntimeClientError.transport("failed to encode request: \(error)")
        }

        let responsePayload: JSONValue?
        do {
            responsePayload = try frameClient.call(method: "SubmitTextRequest", rawPayload: payloadData)
        } catch let e as RPCFrameError {
            if case .malformedResponse(let detail) = e {
                // rpcframe surfaces a server-reported RPCError (a
                // transport/request-level rejection — e.g. an
                // authority-shaped extra field, an oversized request, an
                // unsupported protocol version) through this same error
                // case, distinct from an ordinary non-SUCCESS Outcome,
                // which arrives as a normal, well-formed response below.
                let parts = detail.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                throw RuntimeClientError.rpc(code: parts.first ?? "UNKNOWN", message: parts.count > 1 ? parts[1] : detail)
            }
            throw RuntimeClientError.transport(String(describing: e))
        }

        guard let payload = responsePayload,
              let protocolVersion = payload["protocol_version"]?.numberValue,
              let outcome = payload["outcome"]?.stringValue,
              let text = payload["text"]?.stringValue else {
            throw RuntimeClientError.transport("SubmitTextRequest response missing required fields")
        }
        let taskID = payload["task_id"]?.stringValue ?? ""
        let respRequestID = payload["request_id"]?.stringValue ?? ""
        let respCorrelationID = payload["correlation_id"]?.stringValue ?? ""
        return RuntimeTextResult(
            protocolVersion: Int(protocolVersion), requestID: respRequestID, correlationID: respCorrelationID,
            taskID: taskID, outcome: outcome, text: text
        )
    }
}

/// Wire shape for an OUTGOING SubmitTextRequest — mirrors
/// `rpcapi.SubmitTextRequestWire` in Go field-for-field, duplicated
/// rather than shared, per the same precedent `wireclient` already
/// established in the Go codebase for crossing a module/language
/// boundary without importing internal types.
private struct SubmitTextRequestWireOut: Codable {
    let protocol_version: Int
    let request_id: String
    let correlation_id: String
    let text: String
}
