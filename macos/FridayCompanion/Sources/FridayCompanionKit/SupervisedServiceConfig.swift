import Foundation

/// Everything the Supervisor needs to manage one child process. P2-M1
/// manages exactly two of these — `policyengined` and `capabilitybusd`
/// — never a third; `friday-daemon` is P2-M2 scope and is not
/// constructed anywhere in this milestone (`docs/PHASE-2-...` P2-M1 §3:
/// "NO ... new FRIDAY capabilities").
public struct SupervisedServiceConfig: Sendable, Equatable {
    public let name: String
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    /// The Unix socket path this service's real `Health` RPC is
    /// reachable on — used for readiness polling, never for anything
    /// resembling an authorization call.
    public let healthSocketPath: String
    /// Every P2-M1 service is mandatory: overall system readiness
    /// requires both `policyengined` and `capabilitybusd` to be ready
    /// (`docs/PHASE-2-...` P2-M1 §7: "Do not mark FRIDAY READY until
    /// mandatory dependencies are actually ready"). The field exists so
    /// a later milestone (e.g. an optional service) doesn't need a
    /// structural change here.
    public let isMandatory: Bool
    /// How long to wait for the first successful `ready: true` health
    /// check after spawn before declaring this service `.failed`.
    public let startupTimeout: TimeInterval
    /// How often to poll health while starting/ready.
    public let healthPollInterval: TimeInterval

    public init(
        name: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        healthSocketPath: String,
        isMandatory: Bool = true,
        startupTimeout: TimeInterval = 10,
        healthPollInterval: TimeInterval = 0.25
    ) {
        self.name = name
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.healthSocketPath = healthSocketPath
        self.isMandatory = isMandatory
        self.startupTimeout = startupTimeout
        self.healthPollInterval = healthPollInterval
    }
}

/// Bounded restart behavior (`docs/PHASE-2-...` P2-M1 §9): exponential
/// backoff up to a cap, and a hard attempt ceiling within a rolling
/// window so a permanently-broken binary enters `.failed` and STAYS
/// there — "no tight crash loop" is a correctness requirement, not a
/// nice-to-have, since a crash-looping child process would otherwise
/// make the menu bar's `.restarting` state meaningless (always about to
/// restart again) and would burn real CPU/battery on an ambient,
/// always-running background app.
public struct RestartPolicy: Sendable, Equatable {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let maxAttempts: Int
    public let attemptWindow: TimeInterval

    public init(baseDelay: TimeInterval, maxDelay: TimeInterval, maxAttempts: Int, attemptWindow: TimeInterval) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.attemptWindow = attemptWindow
    }

    public static let standard = RestartPolicy(baseDelay: 1, maxDelay: 30, maxAttempts: 5, attemptWindow: 60)

    /// Delay before restart attempt number `attempt` (1-indexed).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2.0, Double(max(0, attempt - 1))))
    }
}
