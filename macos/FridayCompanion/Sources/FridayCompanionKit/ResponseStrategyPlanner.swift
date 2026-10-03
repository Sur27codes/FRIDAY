import Foundation

/// P2-M5V5 §4/§5 — the second pipeline stage: `ConversationContext` +
/// `FridayPersona` → `ResponseStrategy`. Reasons ONLY from the trusted,
/// already-classified `ResponseFamily`/boolean facts `ConversationContext`
/// carries — never from raw text keywords (§5's explicit ban: "do NOT
/// implement keyword -> emotion -> voice profile").
public protocol ResponseStrategyPlanning: Sendable {
    func strategy(for context: ConversationContext, persona: FridayPersona) -> ResponseStrategy
}

public struct DeterministicResponseStrategyPlanner: ResponseStrategyPlanning {
    public init() {}

    public func strategy(for context: ConversationContext, persona: FridayPersona) -> ResponseStrategy {
        Self.strategy(forPurpose: Self.purpose(for: context), context: context, persona: persona)
    }

    /// Split out from `strategy(for:persona:)` so every `ResponsePurpose`
    /// — including `.acknowledgement`/`.urgentWarning`/`.conversationalFollowUp`,
    /// which no real `ResponseFamily` maps to yet (see those cases' own
    /// doc comments) — has a directly testable entry point, matching this
    /// architecture's own "real, tested, not yet reachable in production"
    /// discipline (§12).
    static func strategy(forPurpose purpose: ResponsePurpose, context: ConversationContext, persona: FridayPersona) -> ResponseStrategy {
        // Start from the persona's own stable baseline (§3: "FRIDAY's
        // personality should remain recognizable across every context")
        // and apply only small, purpose-driven adjustments — never a
        // wholesale swap to a different personality.
        switch purpose {
        case .success:
            return ResponseStrategy(
                purpose: .success, warmth: persona.warmth, formality: persona.formality, energy: persona.energy,
                directness: persona.directness, urgency: 0.1, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .success
            )
        case .information:
            return ResponseStrategy(
                purpose: .information, warmth: persona.warmth, formality: persona.formality, energy: persona.energy,
                directness: persona.directness, urgency: 0.1, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .information
            )
        case .clarification:
            return ResponseStrategy(
                purpose: .clarification, warmth: persona.warmth, formality: persona.formality, energy: persona.energy,
                directness: persona.directness, urgency: 0.2, reassurance: persona.reassurance,
                verbosity: .concise, acknowledgmentNeed: false, followUpNeed: true, prosodyIntent: .friendly
            )
        case .unsupported:
            return ResponseStrategy(
                purpose: .unsupported, warmth: persona.warmth, formality: persona.formality, energy: persona.energy * 0.9,
                directness: persona.directness, urgency: 0.1, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .information
            )
        case .failure:
            return ResponseStrategy(
                purpose: .failure, warmth: persona.warmth, formality: persona.formality, energy: persona.energy * 0.85,
                directness: persona.directness, urgency: 0.3, reassurance: min(1, persona.reassurance + 0.15),
                verbosity: .concise, acknowledgmentNeed: false, followUpNeed: context.isFollowUpMeaningful, prosodyIntent: .failure
            )
        case .retryableFailure:
            return ResponseStrategy(
                purpose: .retryableFailure, warmth: persona.warmth, formality: persona.formality, energy: persona.energy * 0.85,
                directness: persona.directness, urgency: 0.35, reassurance: min(1, persona.reassurance + 0.2),
                verbosity: .concise, acknowledgmentNeed: false, followUpNeed: context.isFollowUpMeaningful, prosodyIntent: .reassuring
            )
        case .permissionDenied:
            return ResponseStrategy(
                purpose: .permissionDenied, warmth: persona.warmth * 0.9, formality: min(1, persona.formality + 0.1), energy: persona.energy * 0.8,
                directness: persona.directness, urgency: 0.2, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .permissionDenied
            )
        case .warning:
            return ResponseStrategy(
                purpose: .warning, warmth: persona.warmth, formality: persona.formality, energy: persona.energy,
                directness: min(1, persona.directness + 0.1), urgency: 0.5, reassurance: persona.reassurance,
                verbosity: .concise, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .warning
            )
        case .urgentWarning:
            return ResponseStrategy(
                purpose: .urgentWarning, warmth: persona.warmth, formality: persona.formality, energy: min(1, persona.energy + 0.1),
                directness: min(1, persona.directness + 0.2), urgency: 0.9, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .urgent
            )
        case .acknowledgement:
            return ResponseStrategy(
                purpose: .acknowledgement, warmth: persona.warmth, formality: persona.formality, energy: persona.energy,
                directness: persona.directness, urgency: 0.15, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: true, followUpNeed: false, prosodyIntent: .focused
            )
        case .conversationalFollowUp:
            // Real, tested — but see this type's own top-level doc
            // comment: `ConversationContextCompiler` never actually
            // produces `.conversationalFollowUp` from a real outcome
            // today, since FRIDAY has no free-form conversational input
            // channel to react to.
            return ResponseStrategy(
                purpose: .conversationalFollowUp, warmth: min(1, persona.warmth + 0.1), formality: max(0, persona.formality - 0.1),
                energy: persona.energy, directness: persona.directness, urgency: 0.1, reassurance: persona.reassurance,
                verbosity: .brief, acknowledgmentNeed: false, followUpNeed: false, prosodyIntent: .casual
            )
        }
    }

    /// Maps a classified `ResponseFamily` to a `ResponsePurpose` — the
    /// one place this mapping lives, so it can never drift between the
    /// strategy planner and anything else that might want to know "is
    /// this a failure."
    static func purpose(for context: ConversationContext) -> ResponsePurpose {
        switch context.responseFamily {
        case .systemStatusSuccess, .createNoteSuccess, .genericSuccess:
            return .success
        case .unsupportedIntent, .invalidRequest, .irValidationFailed:
            return .unsupported
        case .ambiguousIntent:
            return .clarification
        case .policyDenied:
            return .permissionDenied
        case .policyUnavailable, .capabilityUnavailable, .executionFailed:
            return context.isRetryable ? .retryableFailure : .failure
        case .verificationFailed, .internalError, .transportFailure:
            return .failure
        case .verificationNeedsReview:
            return .warning
        case .cancelled, .alreadyTerminal, .duplicateRequest:
            return .information
        case .other:
            return .information
        }
    }
}
