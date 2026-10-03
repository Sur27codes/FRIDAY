import Foundation

/// P2-PROD-BOOTSTRAP §B6 — one requirement the first-run/setup flow may
/// need the owner to address. `isBlocking` distinguishes "FRIDAY cannot
/// do anything useful without this" (conversation provider/credential,
/// permissions) from "FRIDAY degrades gracefully without this"
/// (voice provider/credential — the existing, frozen
/// `FallbackSpeechSynthesizer` already falls back to on-device Samantha
/// speech, so a missing premium voice credential is real but never
/// fatal).
public enum SetupRequirement: Sendable, Equatable, CaseIterable {
    case conversationProvider
    case conversationCredential
    case voiceProvider
    case voiceCredential
    case microphonePermission
    case speechRecognitionPermission

    public var isBlocking: Bool {
        switch self {
        case .conversationProvider, .conversationCredential, .microphonePermission, .speechRecognitionPermission: return true
        case .voiceProvider, .voiceCredential: return false
        }
    }

    public var displayName: String {
        switch self {
        case .conversationProvider: return "Conversation provider"
        case .conversationCredential: return "Conversation credential"
        case .voiceProvider: return "Voice provider"
        case .voiceCredential: return "Voice credential"
        case .microphonePermission: return "Microphone permission"
        case .speechRecognitionPermission: return "Speech Recognition permission"
        }
    }
}

public enum SetupState: Sendable, Equatable {
    /// Everything blocking is satisfied — FRIDAY can run normally. Any
    /// remaining non-blocking items (e.g. voice credential) are still
    /// reported so a settings surface can show them, but they never
    /// force the setup window to reappear on every launch.
    case ready(nonBlockingGaps: [SetupRequirement])
    /// At least one blocking requirement is missing — the setup window
    /// must be shown before normal operation begins.
    case setupRequired(missing: [SetupRequirement])
}

/// Pure function: given the real facts (already read from
/// `ProductionSettingsStore`/`CredentialStoring`/`PermissionCoordinator`
/// by the caller), decides what the setup flow should show. No I/O.
public func determineSetupState(
    settings: ProductionSettings,
    conversationCredentialExists: Bool,
    voiceCredentialExists: Bool,
    permissions: PermissionSnapshot
) -> SetupState {
    var missing: [SetupRequirement] = []
    if settings.conversationProvider == "unspecified" || settings.conversationProvider.isEmpty { missing.append(.conversationProvider) }
    if !conversationCredentialExists { missing.append(.conversationCredential) }
    if settings.voiceProvider == "unspecified" || settings.voiceProvider.isEmpty { missing.append(.voiceProvider) }
    if !voiceCredentialExists { missing.append(.voiceCredential) }
    if permissions.microphone != .granted { missing.append(.microphonePermission) }
    if permissions.speechRecognition != .granted { missing.append(.speechRecognitionPermission) }

    let blocking = missing.filter(\.isBlocking)
    if blocking.isEmpty {
        return .ready(nonBlockingGaps: missing.filter { !$0.isBlocking })
    }
    return .setupRequired(missing: blocking)
}

/// P2-PROD-BOOTSTRAP §B6 — the sanitized result of a "Test Connection"
/// action. Never proof that every feature works (§B6: "Do not call a
/// successful connectivity test proof that every feature works") — only
/// that the named check itself passed or failed, with a sanitized
/// reason on failure (never a raw error/credential value).
public struct ConnectivityCheckResult: Sendable, Equatable {
    public let checkName: String
    public let succeeded: Bool
    public let sanitizedDetail: String

    public init(checkName: String, succeeded: Bool, sanitizedDetail: String) {
        self.checkName = checkName
        self.succeeded = succeeded
        self.sanitizedDetail = sanitizedDetail
    }
}
