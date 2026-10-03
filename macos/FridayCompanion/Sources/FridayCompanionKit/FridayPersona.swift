import Foundation

/// P2-M5V5 §3 — how much FRIDAY says, independent of tone. A closed,
/// small set (not a free Double) so `ResponseRealizer`'s phrase banks
/// have a bounded number of length targets to satisfy, matching §8's
/// "response length intelligence" without an open-ended budget.
public enum Verbosity: Sendable, Equatable, Comparable {
    case brief
    case concise
    case normal
    case detailed
}

/// P2-M5V5 §3 — the ONE stable FRIDAY personality. Every numeric
/// dimension is a `Double` clamped to `0...1` in `init`, so a
/// hand-edited or future-computed persona can never silently carry an
/// out-of-range value into `ResponseStrategyPlanner`. This is
/// deliberately a single `static let` value, not a per-user/per-context
/// variant — "FRIDAY's personality should remain recognizable across
/// every context" (§3) — situational adaptation happens entirely in
/// `ResponseStrategy`/`ProsodyIntent`, layered ON TOP of this fixed
/// baseline, never by swapping to a different persona.
public struct FridayPersona: Sendable, Equatable {
    public let friendliness: Double
    public let warmth: Double
    public let confidence: Double
    public let clarity: Double
    /// §3: "formality low-medium."
    public let formality: Double
    public let energy: Double
    public let verbosity: Verbosity
    /// §3: "humor subtle/rare" — deliberately low; nothing in this
    /// codebase currently reads this to actually generate a joke (no
    /// humor content exists anywhere in the phrase banks) — it exists so
    /// a future realizer has a documented ceiling, not a license to add
    /// unbounded humor generation.
    public let humor: Double
    /// §3: "enthusiasm restrained."
    public let enthusiasm: Double
    /// §3: "reassurance contextual" — this baseline value is the
    /// resting level; `ResponseStrategyPlanner` raises it situationally
    /// (e.g. for `.reassuring`-intent responses), never lowers the
    /// FLOOR below what feels like the same person.
    public let reassurance: Double
    /// §3: "directness medium-high."
    public let directness: Double

    public init(
        friendliness: Double, warmth: Double, confidence: Double, clarity: Double,
        formality: Double, energy: Double, verbosity: Verbosity, humor: Double,
        enthusiasm: Double, reassurance: Double, directness: Double
    ) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        self.friendliness = clamp(friendliness)
        self.warmth = clamp(warmth)
        self.confidence = clamp(confidence)
        self.clarity = clamp(clarity)
        self.formality = clamp(formality)
        self.energy = clamp(energy)
        self.verbosity = verbosity
        self.humor = clamp(humor)
        self.enthusiasm = clamp(enthusiasm)
        self.reassurance = clamp(reassurance)
        self.directness = clamp(directness)
    }

    /// The one stable FRIDAY personality (§3's exact target dimensions):
    /// friendliness/warmth/confidence/clarity high; formality low-
    /// medium; energy medium; verbosity concise; humor subtle/rare;
    /// enthusiasm restrained; reassurance contextual (this is the
    /// resting baseline); directness medium-high. "A capable person you
    /// enjoy talking to" — not a customer-service agent, cartoon
    /// assistant, overly-enthusiastic friend, emotionless computer, or
    /// formal executive assistant.
    public static let friday = FridayPersona(
        friendliness: 0.8, warmth: 0.8, confidence: 0.85, clarity: 0.85,
        formality: 0.3, energy: 0.5, verbosity: .concise, humor: 0.15,
        enthusiasm: 0.35, reassurance: 0.5, directness: 0.7
    )
}

/// P2-M5V5 §4 — the closed set of reasons FRIDAY is producing a
/// response, one level more specific than `ProsodyIntent` (a single
/// `purpose` can still map to different `ProsodyIntent`s depending on
/// context — e.g. `.failure` today always maps to `.failure` prosody,
/// but the TYPES are kept separate so that need never become true by
/// construction).
public enum ResponsePurpose: Sendable, Equatable {
    case success
    case information
    case acknowledgement
    case clarification
    case unsupported
    case failure
    case retryableFailure
    case permissionDenied
    case warning
    case urgentWarning
    /// Declared for architecture-completeness (§10's own conversational
    /// examples reference this purpose) — see `ResponseRealizer`'s doc
    /// comment: `ConversationContextCompiler` never actually produces
    /// this purpose from a real `CommandRuntimeOutcome` today, because
    /// FRIDAY has no free-form conversational input channel to react
    /// to. Real, tested, and reachable only via direct construction in
    /// tests until a future milestone adds that input channel.
    case conversationalFollowUp
}

/// P2-M5V5 §4 — "do NOT define personality solely with labels; use
/// bounded dimensions." Every continuous field is a `Double` clamped to
/// `0...1` in `init`, mirroring `FridayPersona`'s own discipline.
public struct ResponseStrategy: Sendable, Equatable {
    public let purpose: ResponsePurpose
    public let warmth: Double
    public let formality: Double
    public let energy: Double
    public let directness: Double
    public let urgency: Double
    public let reassurance: Double
    public let verbosity: Verbosity
    public let acknowledgmentNeed: Bool
    /// Whether this response's SUBJECT MATTER could benefit from a
    /// follow-up (metadata only — see `ConversationContext.isFollowUpMeaningful`'s
    /// own doc comment for why this never becomes spoken text yet).
    public let followUpNeed: Bool
    public let prosodyIntent: ProsodyIntent

    public init(
        purpose: ResponsePurpose, warmth: Double, formality: Double, energy: Double, directness: Double,
        urgency: Double, reassurance: Double, verbosity: Verbosity, acknowledgmentNeed: Bool,
        followUpNeed: Bool, prosodyIntent: ProsodyIntent
    ) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        self.purpose = purpose
        self.warmth = clamp(warmth)
        self.formality = clamp(formality)
        self.energy = clamp(energy)
        self.directness = clamp(directness)
        self.urgency = clamp(urgency)
        self.reassurance = clamp(reassurance)
        self.verbosity = verbosity
        self.acknowledgmentNeed = acknowledgmentNeed
        self.followUpNeed = followUpNeed
        self.prosodyIntent = prosodyIntent
    }
}
