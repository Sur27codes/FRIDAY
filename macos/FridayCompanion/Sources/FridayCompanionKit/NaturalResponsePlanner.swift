import Foundation

/// P2-M5V6 §12 — "HOW FRIDAY SHOULD RESPOND," richer than `ResponseStrategy`:
/// adds `socialRegister`/humor to the same bounded, clamped-dimension
/// discipline `ResponseStrategy` already established. Built FROM a
/// `ResponseStrategy` (never replacing it — `ResponseStrategyPlanner`
/// remains the runtime-truth-driven authority for warmth/formality/
/// energy/directness/urgency/reassurance), not a parallel, independently-
/// computed personality model.
public struct NaturalResponsePlan: Sendable, Equatable {
    public let responseGoal: ResponsePurpose
    public let socialRegister: SocialRegister
    public let warmth: Double
    public let directness: Double
    public let humorAllowance: Bool
    public let humorStrength: Double
    public let formality: Double
    public let verbosity: Verbosity
    public let reassurance: Double
    public let urgency: Double
    public let followUpMode: FollowUpClassification
    public let prosodyIntent: ProsodyIntent

    public init(
        responseGoal: ResponsePurpose, socialRegister: SocialRegister, warmth: Double, directness: Double,
        humorAllowance: Bool, humorStrength: Double, formality: Double, verbosity: Verbosity, reassurance: Double,
        urgency: Double, followUpMode: FollowUpClassification, prosodyIntent: ProsodyIntent
    ) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        self.responseGoal = responseGoal
        self.socialRegister = socialRegister
        self.warmth = clamp(warmth)
        self.directness = clamp(directness)
        self.humorAllowance = humorAllowance
        self.humorStrength = humorAllowance ? clamp(humorStrength) : 0
        self.formality = clamp(formality)
        self.verbosity = verbosity
        self.reassurance = clamp(reassurance)
        self.urgency = clamp(urgency)
        self.followUpMode = followUpMode
        self.prosodyIntent = prosodyIntent
    }
}

public protocol NaturalResponsePlanning: Sendable {
    func plan(context: ConversationContext, understanding: ConversationUnderstanding, strategy: ResponseStrategy, persona: FridayPersona) -> NaturalResponsePlan
}

public struct DeterministicNaturalResponsePlanner: NaturalResponsePlanning {
    private let registerPlanner: SocialRegisterPlanning

    public init(registerPlanner: SocialRegisterPlanning = DeterministicSocialRegisterPlanner()) {
        self.registerPlanner = registerPlanner
    }

    public func plan(context: ConversationContext, understanding: ConversationUnderstanding, strategy: ResponseStrategy, persona: FridayPersona) -> NaturalResponsePlan {
        let register = registerPlanner.register(context: context, understanding: understanding, strategy: strategy)
        let humor = HumorPolicy.intent(register: register, purpose: strategy.purpose, understanding: understanding)
        return NaturalResponsePlan(
            responseGoal: strategy.purpose, socialRegister: register, warmth: strategy.warmth, directness: strategy.directness,
            humorAllowance: humor.allowed, humorStrength: humor.strength, formality: Self.formality(for: register, base: strategy.formality),
            verbosity: understanding.recommendedVerbosity ?? strategy.verbosity, reassurance: strategy.reassurance,
            urgency: understanding.explicitUrgency ? max(strategy.urgency, 0.6) : strategy.urgency,
            followUpMode: understanding.followUpNeeded ? .clarificationAvailable(missingField: nil) : .none,
            prosodyIntent: Self.prosodyIntent(for: register, fallback: strategy.prosodyIntent)
        )
    }

    /// §7/§14 — social register informs prosody selection, but a
    /// safety-shaped `strategy.prosodyIntent` (already computed by the
    /// unchanged `ResponseStrategyPlanner`) is never weakened by a
    /// casual-sounding register; this mapping only ever refines register-
    /// specific nuance for the non-safety-shaped registers.
    static func prosodyIntent(for register: SocialRegister, fallback: ProsodyIntent) -> ProsodyIntent {
        switch register {
        case .casualFriendly: return .casual
        case .friendlyNeutral: return .friendly
        case .professional: return .focused
        case .focused: return .focused
        case .reassuring: return .reassuring
        case .serious: return .serious
        case .warning: return .warning
        case .urgent: return .urgent
        }
    }

    static func formality(for register: SocialRegister, base: Double) -> Double {
        switch register {
        case .professional: return max(base, 0.7)
        case .casualFriendly: return min(base, 0.2)
        default: return base
        }
    }
}
