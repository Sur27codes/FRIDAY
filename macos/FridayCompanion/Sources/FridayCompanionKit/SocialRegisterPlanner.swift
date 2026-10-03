import Foundation

/// P2-M5V6 §7 — NOT eight personalities; one `FridayPersona` adapting
/// its social register. Ordered here roughly casual→urgent purely for
/// readability; `DeterministicSocialRegisterPlanner` does not rely on
/// case order.
public enum SocialRegister: Sendable, Equatable, CaseIterable {
    case casualFriendly
    case friendlyNeutral
    case professional
    case focused
    case reassuring
    case serious
    case warning
    case urgent
}

/// P2-M5V6 §7/§8 — chooses `SocialRegister` from CONTEXT, never from one
/// keyword (§8's explicit ban). Reasons only from already-trusted facts:
/// the runtime-driven `ResponseStrategy`/`ConversationContext` (what
/// actually happened) and `ConversationUnderstanding` (what the
/// reasoner — deterministic today — inferred about this turn from
/// structured, safe inputs).
public protocol SocialRegisterPlanning: Sendable {
    func register(context: ConversationContext, understanding: ConversationUnderstanding, strategy: ResponseStrategy) -> SocialRegister
}

public struct DeterministicSocialRegisterPlanner: SocialRegisterPlanning {
    public init() {}

    public func register(context: ConversationContext, understanding: ConversationUnderstanding, strategy: ResponseStrategy) -> SocialRegister {
        // §8: safety/authority-shaped purposes ALWAYS win, regardless of
        // any reasoner opinion or casual conversational style — register
        // can adapt tone, never soften a genuinely safety-relevant
        // moment into something it isn't.
        switch strategy.purpose {
        case .urgentWarning:
            return .urgent
        case .warning:
            return .warning
        case .permissionDenied:
            return .focused
        case .retryableFailure, .failure:
            return .reassuring
        default:
            break
        }

        // Explicit user wording outranks any inferred style (§19): if the
        // user explicitly signaled urgency/importance, that takes
        // priority over a casual-sounding register even for an otherwise
        // ordinary success/information outcome.
        if understanding.explicitUrgency {
            return .focused
        }

        // The reasoner's own recommendation, when it has one and the
        // outcome isn't safety-shaped (handled above).
        if let recommended = understanding.socialRegisterRecommendation {
            return recommended
        }

        // Default: an ordinary successful/informational/clarification
        // interaction reads as friendly-neutral — warm but not
        // presuming casual familiarity absent any signal either way.
        switch strategy.purpose {
        case .success, .information, .acknowledgement, .clarification, .unsupported, .conversationalFollowUp:
            return .friendlyNeutral
        case .urgentWarning, .warning, .permissionDenied, .retryableFailure, .failure:
            return .friendlyNeutral // unreachable — handled above; kept exhaustive and safe
        }
    }
}
