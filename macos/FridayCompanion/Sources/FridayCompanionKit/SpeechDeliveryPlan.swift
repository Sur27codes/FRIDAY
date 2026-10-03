import Foundation

/// P2-M5V9-B §5 — a bounded, named delivery mode for the SPEECH layer
/// only. Deliberately NOT a new conversational concept: every case here
/// is a display label over the conversational brain's own, already-
/// frozen `SocialRegister`/`explanationRequested`/`humorAllowance`
/// signals (§0: the brain is permanently frozen; this milestone changes
/// speech presentation only). Exists so a premium provider capable of
/// named "speaking styles" (`PremiumSpeechCapabilities.speakingStyles`)
/// has a small, safe, closed vocabulary to select from, in addition to
/// (never instead of) the existing numeric `ProsodyPlan` knobs every
/// engine already receives.
public enum SpeechDeliveryMode: Sendable, Equatable, CaseIterable {
    case neutral
    case friendly
    case professional
    case focused
    case serious
    case lightPlayful
    case explanatory
}

/// P2-M5V9-B §4 — the local, non-authoritative speech-delivery layer.
/// Input comes ONLY from already-accepted/local conversational facts
/// (`NaturalResponsePlan`, `ConversationUnderstanding`) — this type never
/// rewrites semantic content, never introduces words, never infers a
/// private emotional state, and never touches permission/execution truth
/// (§4/§7). `prosody` is the existing, unchanged, already-audited
/// `ProsodyPlan` computation (`AdaptiveProsodyPlanning.prosodyPlan`) —
/// `mode` is purely an ADDITIVE label alongside it, never a second,
/// competing source of numeric adjustment.
public struct SpeechDeliveryPlan: Sendable, Equatable {
    public let mode: SpeechDeliveryMode
    public let prosody: ProsodyPlan

    public init(mode: SpeechDeliveryMode, prosody: ProsodyPlan) {
        self.mode = mode
        self.prosody = prosody
    }
}

public protocol SpeechDeliveryPlanning: Sendable {
    func deliveryPlan(plan: NaturalResponsePlan, understanding: ConversationUnderstanding, persona: FridayPersona, acoustics: AcousticConversationFeatures, base: VoiceProfile) -> SpeechDeliveryPlan
}

/// P2-M5V9-B §5/§6 — deterministic mapping from existing, frozen
/// conversation-plan state to a `SpeechDeliveryMode`. Same speaker
/// identity/voice underneath in every mode (§6: "only delivery changes,
/// identity remains stable") — this planner never selects a different
/// voice, only a delivery label plus the existing bounded prosody deltas.
public struct DeterministicSpeechDeliveryPlanner: SpeechDeliveryPlanning, AdaptiveProsodyPlanning {
    public init() {}

    public func prosody(for intent: ProsodyIntent, base: VoiceProfile) -> VoiceProfile {
        base.adjusted(for: intent)
    }

    /// §5's own worked examples, reproduced exactly via existing fields:
    /// "long explanation -> explanatory" (`explanationRequested`, already
    /// computed by `ConversationReasoning`, wins outright — a request to
    /// explain something calls for slower, more separated delivery
    /// regardless of the underlying register); "professional draft ->
    /// professional" (`plan.socialRegister == .professional`); "casual
    /// success -> friendly/lightPlayful" (`.casualFriendly`, split by
    /// whether this turn's plan actually allowed humor — never guessed
    /// independently); "permission/security -> serious/focused" and
    /// "operational outage -> serious" (`.focused`/`.serious`/`.warning`);
    /// "greeting -> friendly" (`.friendlyNeutral`/`.reassuring` fold to
    /// `.friendly`, the everyday warm default).
    public func mode(forSocialRegister register: SocialRegister, explanationRequested: Bool, humorAllowed: Bool) -> SpeechDeliveryMode {
        if explanationRequested { return .explanatory }
        switch register {
        case .professional: return .professional
        case .focused, .urgent: return .focused
        case .serious, .warning: return .serious
        case .casualFriendly: return humorAllowed ? .lightPlayful : .friendly
        case .friendlyNeutral, .reassuring: return .friendly
        }
    }

    public func deliveryPlan(plan: NaturalResponsePlan, understanding: ConversationUnderstanding, persona: FridayPersona, acoustics: AcousticConversationFeatures, base: VoiceProfile) -> SpeechDeliveryPlan {
        let mode = mode(forSocialRegister: plan.socialRegister, explanationRequested: understanding.explanationRequested, humorAllowed: plan.humorAllowance)
        let prosody = prosodyPlan(persona: persona, plan: plan, acoustics: acoustics, base: base)
        return SpeechDeliveryPlan(mode: mode, prosody: prosody)
    }
}
