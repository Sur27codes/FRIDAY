import Foundation

/// P2-PROD-BOOTSTRAP §B10 — one canonical health source, consumable by
/// a future M6 UI, so M6 never has to infer process/provider state
/// itself. Never carries a secret value, raw transcript, or other
/// private content — every field here is either a lifecycle state, a
/// sanitized message, a timestamp, or a count.
public struct ComponentHealth: Sendable, Equatable {
    public let state: ServiceLifecycleState
    public let sanitizedMessage: String
    public let lastHealthy: Date?
    public let restartCount: Int?

    public init(state: ServiceLifecycleState, sanitizedMessage: String, lastHealthy: Date?, restartCount: Int?) {
        self.state = state
        self.sanitizedMessage = sanitizedMessage
        self.lastHealthy = lastHealthy
        self.restartCount = restartCount
    }
}

public struct ProductionHealthSnapshot: Sendable, Equatable {
    public let companion: ComponentHealth
    public let policyEngine: ComponentHealth
    public let capabilityBus: ComponentHealth
    public let fridayDaemon: ComponentHealth
    public let wake: ComponentHealth
    public let stt: ComponentHealth
    public let conversationProvider: ComponentHealth
    public let voiceProvider: ComponentHealth
    public let localVoice: ComponentHealth
    public let capturedAt: Date

    public init(
        companion: ComponentHealth, policyEngine: ComponentHealth, capabilityBus: ComponentHealth, fridayDaemon: ComponentHealth,
        wake: ComponentHealth, stt: ComponentHealth, conversationProvider: ComponentHealth, voiceProvider: ComponentHealth,
        localVoice: ComponentHealth, capturedAt: Date
    ) {
        self.companion = companion
        self.policyEngine = policyEngine
        self.capabilityBus = capabilityBus
        self.fridayDaemon = fridayDaemon
        self.wake = wake
        self.stt = stt
        self.conversationProvider = conversationProvider
        self.voiceProvider = voiceProvider
        self.localVoice = localVoice
        self.capturedAt = capturedAt
    }
}

/// Everything this snapshot needs from the outside world, kept as small
/// closures/values rather than concrete types — so building a snapshot
/// never requires constructing a real `Supervisor`/real network client
/// in a test, and so this file has no dependency on AppKit/networking.
public struct ProductionHealthInputs: Sendable {
    public var supervisorSnapshot: [String: ServiceLifecycleState]
    public var supervisorRestartCounts: [String: Int]
    public var wakeState: AudioState
    public var wakeUnavailableReason: String?
    public var sttPermission: SpeechRecognitionPermissionStatus
    public var conversationConfigured: Bool
    public var voiceProviderConfigured: Bool
    public var voiceProviderName: String
    public var localVoiceSocketExists: Bool
    public var now: Date

    public init(
        supervisorSnapshot: [String: ServiceLifecycleState], supervisorRestartCounts: [String: Int] = [:],
        wakeState: AudioState, wakeUnavailableReason: String?, sttPermission: SpeechRecognitionPermissionStatus,
        conversationConfigured: Bool, voiceProviderConfigured: Bool, voiceProviderName: String,
        localVoiceSocketExists: Bool, now: Date = Date()
    ) {
        self.supervisorSnapshot = supervisorSnapshot
        self.supervisorRestartCounts = supervisorRestartCounts
        self.wakeState = wakeState
        self.wakeUnavailableReason = wakeUnavailableReason
        self.sttPermission = sttPermission
        self.conversationConfigured = conversationConfigured
        self.voiceProviderConfigured = voiceProviderConfigured
        self.voiceProviderName = voiceProviderName
        self.localVoiceSocketExists = localVoiceSocketExists
        self.now = now
    }
}

/// Pure function: given the raw facts, produces the one canonical
/// snapshot. No I/O of its own — the caller (AppDelegate, or a test)
/// gathers `ProductionHealthInputs` from the real Supervisor/
/// WakeCoordinator/config, then calls this.
public func buildProductionHealthSnapshot(_ inputs: ProductionHealthInputs) -> ProductionHealthSnapshot {
    func componentFrom(serviceName: String) -> ComponentHealth {
        let state = inputs.supervisorSnapshot[serviceName] ?? .stopped
        let restartCount = inputs.supervisorRestartCounts[serviceName]
        return ComponentHealth(state: state, sanitizedMessage: sanitizedMessage(for: state, serviceName: serviceName), lastHealthy: state == .ready ? inputs.now : nil, restartCount: restartCount)
    }

    let mandatoryStates = ["policyengined", "capabilitybusd", "friday-daemon"].map { inputs.supervisorSnapshot[$0] ?? .stopped }
    let companionState = overallState(mandatoryStates: mandatoryStates)

    let wakeHealthState: ServiceLifecycleState
    let wakeMessage: String
    switch inputs.wakeState {
    case .wakeOnly, .listening, .processing, .speaking, .awaitingFollowUp:
        wakeHealthState = .ready
        wakeMessage = "listening for \"Hey Friday\""
    case .microphoneOff:
        wakeHealthState = .stopped
        wakeMessage = "wake listening is off"
    case .unavailable:
        wakeHealthState = .failed
        wakeMessage = inputs.wakeUnavailableReason ?? "wake engine unavailable"
    }

    let sttState: ServiceLifecycleState
    let sttMessage: String
    switch inputs.sttPermission {
    case .authorized: sttState = .ready; sttMessage = "speech recognition authorized"
    case .denied: sttState = .failed; sttMessage = "speech recognition permission denied — enable in System Settings"
    case .restricted: sttState = .failed; sttMessage = "speech recognition restricted by system policy"
    case .notDetermined: sttState = .starting; sttMessage = "speech recognition permission not yet requested"
    }

    let conversationState: ServiceLifecycleState = inputs.conversationConfigured ? .ready : .stopped
    let conversationMessage = inputs.conversationConfigured ? "conversation provider configured" : "conversation provider not configured — setup required"

    let voiceState: ServiceLifecycleState = inputs.voiceProviderConfigured ? .ready : .degraded
    let voiceMessage = inputs.voiceProviderConfigured
        ? "\(inputs.voiceProviderName) configured"
        : "premium voice not configured — falling back to on-device speech"

    // P2-M5-FINAL-CLOSURE-R1 §1/§6 — Chatterbox Turbo is the production
    // SECOND speech tier (Cartesia Skylar -> Chatterbox Turbo -> Samantha),
    // started lazily only when cloud speech fails (no ~1GB model load at
    // login). "Not running" is therefore the normal, healthy idle state —
    // report it as available-on-demand, NEVER as a failure.
    let localVoiceState: ServiceLifecycleState = inputs.localVoiceSocketExists ? .ready : .stopped
    let localVoiceMessage = inputs.localVoiceSocketExists
        ? "local Chatterbox Turbo voice service reachable"
        : "local Chatterbox Turbo voice idle — available on demand (starts only if cloud speech fails)"

    return ProductionHealthSnapshot(
        companion: ComponentHealth(state: companionState, sanitizedMessage: "overall companion state", lastHealthy: companionState == .ready ? inputs.now : nil, restartCount: nil),
        policyEngine: componentFrom(serviceName: "policyengined"),
        capabilityBus: componentFrom(serviceName: "capabilitybusd"),
        fridayDaemon: componentFrom(serviceName: "friday-daemon"),
        wake: ComponentHealth(state: wakeHealthState, sanitizedMessage: wakeMessage, lastHealthy: wakeHealthState == .ready ? inputs.now : nil, restartCount: nil),
        stt: ComponentHealth(state: sttState, sanitizedMessage: sttMessage, lastHealthy: sttState == .ready ? inputs.now : nil, restartCount: nil),
        conversationProvider: ComponentHealth(state: conversationState, sanitizedMessage: conversationMessage, lastHealthy: conversationState == .ready ? inputs.now : nil, restartCount: nil),
        voiceProvider: ComponentHealth(state: voiceState, sanitizedMessage: voiceMessage, lastHealthy: voiceState == .ready ? inputs.now : nil, restartCount: nil),
        localVoice: ComponentHealth(state: localVoiceState, sanitizedMessage: localVoiceMessage, lastHealthy: localVoiceState == .ready ? inputs.now : nil, restartCount: nil),
        capturedAt: inputs.now
    )
}

private func sanitizedMessage(for state: ServiceLifecycleState, serviceName: String) -> String {
    switch state {
    case .ready: return "\(serviceName) healthy"
    case .starting: return "\(serviceName) starting"
    case .degraded: return "\(serviceName) degraded"
    case .restarting: return "\(serviceName) restarting"
    case .failed: return "\(serviceName) failed"
    case .stopping: return "\(serviceName) stopping"
    case .stopped: return "\(serviceName) stopped"
    }
}
