import Foundation

/// P2-M5V6 §10 — the bounded, testable output of `HumorPolicy`: whether
/// humor is allowed at all, and how strong it may be (a fixed, small
/// value today — there is no escalating "humor level" system, matching
/// §11's "expressiveness without fake sentience" restraint).
public struct HumorIntent: Sendable, Equatable {
    public let allowed: Bool
    public let strength: Double

    public init(allowed: Bool, strength: Double) {
        self.allowed = allowed
        self.strength = allowed && strength.isFinite ? min(max(strength, 0), 1) : 0
    }

    public static let disabled = HumorIntent(allowed: false, strength: 0)
}

/// P2-M5V6 §10 — a pure, deterministic gate. Humor is allowed only for a
/// small allow-list of low-stakes purposes/registers, AND only when the
/// reasoner itself judged this a low-stakes moment
/// (`understanding.humorAppropriateness`). Every disable rule below is
/// a DIRECT transcription of §10's own explicit "humor should be
/// disabled for" list — nothing here infers "is this funny," it only
/// ever gates based on already-known purpose/register.
public enum HumorPolicy {
    private static let disabledPurposes: Set<ResponsePurpose> = [
        .permissionDenied, .warning, .urgentWarning, .failure, .retryableFailure,
    ]
    private static let disabledRegisters: Set<SocialRegister> = [
        .professional, .focused, .serious, .warning, .urgent,
    ]

    public static func intent(register: SocialRegister, purpose: ResponsePurpose, understanding: ConversationUnderstanding) -> HumorIntent {
        guard understanding.humorAppropriateness else { return .disabled }
        guard !disabledPurposes.contains(purpose) else { return .disabled }
        guard !disabledRegisters.contains(register) else { return .disabled }
        // §10: "rare" — a fixed, modest strength, never scaling up with
        // repeated casual interactions (that would risk §9's own
        // "friend-like does not mean slang every sentence" concern).
        return HumorIntent(allowed: true, strength: 0.3)
    }

    /// P2-M5V7 §12 — "Humor 2.0": richer than `intent(...)` (kept
    /// unchanged above for §0 preservation). Distinguishes WHY humor
    /// isn't happening (`.prohibited` — the gate is closed, matching
    /// every `intent(...)` disable rule exactly) from "the gate is open
    /// but nothing here calls for it" (`.unnecessary` — §12's own
    /// "default: no joke") from two flavors of "the gate is open and it
    /// COULD land" (`.optional`/`.appropriate`) — leaving the actual
    /// use-it-or-not judgment to the realizer (§12: "the natural realizer
    /// decides whether to actually use it"), never mechanically forcing
    /// a joke just because it's technically allowed.
    public static func decision(register: SocialRegister, purpose: ResponsePurpose, understanding: ConversationUnderstanding) -> HumorDecision {
        guard !disabledPurposes.contains(purpose), !disabledRegisters.contains(register) else { return .prohibited }
        guard understanding.humorSuitability > 0 else { return .unnecessary }
        // §12: humor is more clearly CALLED FOR when the conversation is
        // already casual (an explicit casual-register recommendation
        // from the reasoner) or the dialogue act itself invites levity
        // (a personal update, a playful remark) — otherwise it remains
        // merely `.optional`, matching §12's "default: no joke" bias.
        let callsForHumor = understanding.socialRegisterRecommendation == .casualFriendly
            || understanding.dialogueAct == .personalUpdate || understanding.dialogueAct == .jokeOrPlayfulRemark
        let strength = min(max(understanding.humorSuitability, 0), 1)
        return callsForHumor ? .appropriate(strength: strength) : .optional(strength: strength)
    }
}
