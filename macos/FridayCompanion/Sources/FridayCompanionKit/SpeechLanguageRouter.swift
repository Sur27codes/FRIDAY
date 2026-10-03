import Foundation

/// P2-M5V9-B.2 §9/§12 — provider-neutral locale representation and
/// routing. Deliberately separate from `ConversationUnderstanding`/
/// `ConversationReasoning` (frozen, untouched this pass) — locale
/// selection here is driven ONLY by explicit language metadata a caller
/// supplies, never inferred from private user data or conversation
/// content (§9: "do not infer nationality or preferred language from
/// private user data").
public enum PreferredSpeechProvider: Sendable, Equatable {
    case cartesia
    case chatterbox
}

/// The routing OUTCOME — `.unsupported` is a first-class, expected
/// result (§12: "never silently switch language... fail truthfully or
/// use explicitly approved emergency system voice"). A caller receiving
/// `.unsupported` is responsible for falling to the existing, unchanged
/// Samantha emergency path — this router never does that substitution
/// itself, so it never blurs "a real provider handled this" with "the
/// emergency voice did."
public enum SpeechRoutingDecision: Sendable, Equatable {
    case cartesia
    case chatterbox
    case unsupported
}

public protocol SpeechLanguageRouting: Sendable {
    func route(locale: String, explicitProvider: PreferredSpeechProvider?, cartesiaSupports: Bool, chatterboxSupports: Bool, privacyModeOnly: Bool, isOnline: Bool) -> SpeechRoutingDecision
}

/// §12's own conceptual logic, reproduced exactly:
/// 1. an explicit, SUPPORTED provider selection always wins;
/// 2. otherwise, privacy/local-only mode always prefers Chatterbox;
/// 3. otherwise, online + Cartesia support wins (the normal path);
/// 4. otherwise, Chatterbox if it supports the locale;
/// 5. otherwise, truthfully unsupported.
///
/// Callers supply `cartesiaSupports`/`chatterboxSupports` — this type
/// never itself knows which locales a specific provider handles (that
/// lives in each provider's own `PremiumSpeechCapabilities.localeSupport`/
/// the real Chatterbox `SUPPORTED_LANGUAGES` registry), keeping this
/// router a pure, trivially-testable decision function.
public struct DeterministicSpeechLanguageRouter: SpeechLanguageRouting {
    public init() {}

    public func route(locale: String, explicitProvider: PreferredSpeechProvider?, cartesiaSupports: Bool, chatterboxSupports: Bool, privacyModeOnly: Bool, isOnline: Bool) -> SpeechRoutingDecision {
        if let explicitProvider {
            if explicitProvider == .cartesia, cartesiaSupports, isOnline { return .cartesia }
            if explicitProvider == .chatterbox, chatterboxSupports { return .chatterbox }
            // An unsupported explicit choice falls through to the
            // general policy below rather than failing immediately —
            // e.g. explicitly asking for Cartesia while offline should
            // still let Chatterbox cover the request if it can.
        }
        if privacyModeOnly {
            return chatterboxSupports ? .chatterbox : .unsupported
        }
        if isOnline, cartesiaSupports { return .cartesia }
        if chatterboxSupports { return .chatterbox }
        return .unsupported
    }
}
