import Foundation

/// P2-M5V6 §5 — a closed, coarse classification of what a turn is FOR.
/// Deliberately small (not open-ended free text) so downstream planners
/// stay bounded and testable.
public enum CommunicativeIntent: Sendable, Equatable {
    /// Asking FRIDAY to do something.
    case command
    /// Asking FRIDAY something, expecting information back.
    case question
    /// Amending/correcting a request just made (e.g. "actually, call it...").
    case correction
    /// A short acknowledgement needing no action ("ok," "thanks," "got it").
    case acknowledgement
    /// Sharing information/an observation, not asking for an action.
    case statement
    case unknown
}

/// P2-M5V6 §5/§14/§15 — "WHAT FRIDAY UNDERSTANDS ABOUT THIS TURN,"
/// compiled from structured inputs (transcript, recent turns, validated
/// runtime facts, safe acoustic features, explicit user statements) —
/// never runtime truth itself. `ConversationReasoning` implementations
/// produce this; `NaturalResponsePlanner`/`SocialRegisterPlanner` consume
/// it. Every field here is either a closed enum/bool, a `Double` bounded
/// to `0...1`, or an explicitly-user-supplied piece of text — nothing
/// here is inferred emotion (§3/§11's boundary, carried forward
/// unchanged).
public struct ConversationUnderstanding: Sendable, Equatable {
    public let communicativeIntent: CommunicativeIntent
    /// A short, safe topic label derived only from what's already in the
    /// transcript/runtime text being reasoned over (e.g. "note," "system
    /// status") — never invented, never containing anything beyond what
    /// the input already said. `nil` when no safe topic label applies.
    public let topic: String?
    /// True when this turn reads as a continuation/correction of the
    /// immediately preceding turn (e.g. "actually call it weekend
    /// groceries" right after a note was created) — a HINT for
    /// `NaturalResponsePlanner`'s acknowledgement wording, never a claim
    /// that the underlying capability actually performed a rename; the
    /// runtime's own outcome for THIS turn remains the only source of
    /// truth for what actually happened.
    public let continuationOfPreviousTurn: Bool
    public let clarificationNeeded: Bool
    /// An instruction the user EXPLICITLY stated (e.g. "keep it short"),
    /// verbatim or near-verbatim — never a guess at unstated preference.
    public let userExplicitPreference: String?
    /// True ONLY when the user's own words explicitly indicated urgency/
    /// importance ("this is important," "right now," "urgently") — NEVER
    /// inferred from acoustic loudness/speed alone (§19: "explicit
    /// language has higher authority than inferred acoustics").
    public let explicitUrgency: Bool
    /// The reasoner's own opinion on social register, if it has one
    /// (`nil` = defer entirely to `SocialRegisterPlanner`'s own
    /// context-driven default). Reuses `SocialRegister` rather than a
    /// parallel taxonomy.
    public let socialRegisterRecommendation: SocialRegister?
    /// Whether the reasoner judges this a low-stakes moment where light
    /// humor would not be disruptive — a RECOMMENDATION `HumorPolicy`
    /// still gates against the actual register/purpose (§10: humor is
    /// disabled outright for certain purposes regardless of this flag).
    public let humorAppropriateness: Bool
    /// Reuses the existing `ResponsePurpose` taxonomy rather than
    /// inventing a parallel one — `nil` when the reasoner defers to
    /// `ResponseStrategyPlanner`'s own runtime-outcome-driven purpose.
    public let responseGoal: ResponsePurpose?
    public let recommendedVerbosity: Verbosity?
    public let followUpNeeded: Bool
    /// 0...1 — how confident the reasoner is in this whole struct. `1.0`
    /// means "confident"; values near `1.0` for a reasoner that has no
    /// real signal (like the current `LLMConversationReasoner` stub) are
    /// how downstream code recognizes "nothing useful here, prefer the
    /// deterministic fallback."
    public let uncertainty: Double

    // MARK: - P2-M5V7 §1/§2/§3/§4/§5/§6 — semantic conversational-act fields (additive; every new field defaults so every pre-P2-M5V7 call site keeps compiling unchanged)

    /// The real classification of what this utterance IS, independent of
    /// whatever runtime outcome happens to accompany it (§1). Defaults to
    /// `.unknown` — a reasoner that has no real transcript signal must
    /// say so honestly, never guess `.command`.
    public let dialogueAct: DialogueAct
    /// Derived from `dialogueAct` (§2) — makes "was this actually a
    /// request to DO something" explicit. Defaults to `.actionRequest`,
    /// matching this codebase's own pre-P2-M5V7 behavior (trust the
    /// runtime outcome) for the common case where no better signal
    /// exists.
    public let interactionMode: InteractionMode
    /// The authoritative fact `ResponseValidation` 2.0 gates completion
    /// language on (§3). Defaults to `.unknown` — never `.executedSucceeded`
    /// by default, since defaulting to success-permitting would defeat
    /// the whole point of this gate.
    public let actionExecutionState: ActionExecutionState
    /// Explicit user-stated constraints (§4) — never inferred, only ever
    /// literal. Empty by default.
    public let explicitConstraints: [ExplicitConstraint]
    /// Grounded failure reasoning (§5) — `.unknown` by default; only ever
    /// `.known` when a caller supplies REAL evidence.
    public let failureReason: FailureReason
    /// Whether retry may be truthfully offered (§6) — `.unknown` by
    /// default, the safe/honest state for a generic failure with no
    /// retry evidence.
    public let retryability: Retryability
    /// A short, safe restatement of what the user is trying to
    /// accomplish, derived only from what they already said — `nil` when
    /// no safe restatement applies. Never fabricated.
    public let userGoal: String?
    /// For `dialogueAct == .correction` — a short, safe label for WHAT is
    /// being corrected (e.g. "note title"), derived only from context
    /// already available (a matching recent turn's family) — `nil` when
    /// no safe target could be identified.
    public let correctionTarget: String?
    /// True when the utterance is asking FRIDAY to explain something
    /// ("why," "what happened") — a more specific signal than
    /// `dialogueAct == .explanationRequest` alone, since a realizer may
    /// want to gate explanation-specific wording on this directly.
    public let explanationRequested: Bool
    /// 0...1 — a richer, continuous sibling of `humorAppropriateness`
    /// (kept, unchanged, for backward compatibility). `HumorPolicy`/`HumorDecision`
    /// (§12) consult this alongside register/purpose gating.
    public let humorSuitability: Double
    /// P2-M5V8.1-S2.2 §5/§6 — a NEGATIVE situational claim the user's OWN
    /// current-turn words asserted ("production is down"), detected
    /// compositionally and ALWAYS locally/authoritatively determined
    /// (never trusted from a model reasoner — see `ConversationalResponsePresenter.authoritative`'s
    /// own handling) — `nil` when the transcript asserts no such state.
    /// Exists so `ResponseValidation` can reject a same-turn "all clear"
    /// candidate without contradictory verified evidence, which this
    /// codebase never has today.
    public let userReportedState: UserReportedState?
    /// P2-M5V8.1-S3 §3/§4 — the CONTINUITY signal for the CURRENT turn:
    /// same subject as the prior turn, a correction of it, a refinement,
    /// a fresh reaction, an explanation request about it, a constraint,
    /// or a genuinely new topic. Always locally/authoritatively determined.
    public let turnRelation: ConversationTurnRelation
    /// P2-M5V8.1-S3 §4 — the bounded continuity subject this turn is
    /// about, `.none` when no continuity signal applies.
    public let activeTopic: ActiveConversationTopic
    /// P2-M5V8.1-S3 §5/§6/§7/§8 — the bounded drafting/editing context
    /// active for this turn (carried forward from a prior turn when this
    /// one refines it, freshly created when this one introduces one),
    /// `nil` when no artifact is in play.
    public let artifactContext: ArtifactContext?
    /// P2-M5V8.1-S3 §10/§20 — the reasoner's CONVERSATIONAL suggestion for
    /// what kind of response move fits — never authoritative, purely a
    /// wording/tone hint a realizer may use or ignore.
    public let pragmaticResponseAct: PragmaticResponseAct?
    /// P2-M5V8.1-O.5 §1/§6 — HOW MUCH the response should say. ALWAYS
    /// local/authoritative (see `ResponseScope`'s own doc comment) —
    /// defaults to `.conversationalShort`, the safe default for any
    /// caller/test predating this field.
    public let responseScope: ResponseScope
    /// P2-M5V8.1-Q §2 — ALWAYS local/authoritative (see `CapabilityRequirement`'s
    /// own doc comment) — defaults to `.unknown`, the safe default for any
    /// caller/test predating this field (fails closed, never silently
    /// `.notRequired`).
    public let capabilityRequirement: CapabilityRequirement

    public init(
        communicativeIntent: CommunicativeIntent, topic: String?, continuationOfPreviousTurn: Bool,
        clarificationNeeded: Bool, userExplicitPreference: String?, explicitUrgency: Bool,
        socialRegisterRecommendation: SocialRegister?, humorAppropriateness: Bool, responseGoal: ResponsePurpose?,
        recommendedVerbosity: Verbosity?, followUpNeeded: Bool, uncertainty: Double,
        dialogueAct: DialogueAct = .unknown, interactionMode: InteractionMode = .actionRequest,
        actionExecutionState: ActionExecutionState = .unknown, explicitConstraints: [ExplicitConstraint] = [],
        failureReason: FailureReason = .unknown, retryability: Retryability = .unknown, userGoal: String? = nil,
        correctionTarget: String? = nil, explanationRequested: Bool = false, humorSuitability: Double? = nil,
        userReportedState: UserReportedState? = nil, turnRelation: ConversationTurnRelation = .newTopic,
        activeTopic: ActiveConversationTopic = .none, artifactContext: ArtifactContext? = nil, pragmaticResponseAct: PragmaticResponseAct? = nil,
        responseScope: ResponseScope = .conversationalShort, capabilityRequirement: CapabilityRequirement = .unknown
    ) {
        self.communicativeIntent = communicativeIntent
        self.topic = topic
        self.continuationOfPreviousTurn = continuationOfPreviousTurn
        self.clarificationNeeded = clarificationNeeded
        self.userExplicitPreference = userExplicitPreference
        self.explicitUrgency = explicitUrgency
        self.socialRegisterRecommendation = socialRegisterRecommendation
        self.humorAppropriateness = humorAppropriateness
        self.responseGoal = responseGoal
        self.recommendedVerbosity = recommendedVerbosity
        self.followUpNeeded = followUpNeeded
        self.uncertainty = uncertainty.isFinite ? min(max(uncertainty, 0), 1) : 1
        self.dialogueAct = dialogueAct
        self.interactionMode = interactionMode
        self.actionExecutionState = actionExecutionState
        self.explicitConstraints = explicitConstraints
        self.failureReason = failureReason
        self.retryability = retryability
        self.userGoal = userGoal
        self.correctionTarget = correctionTarget
        self.explanationRequested = explanationRequested
        let suitability = humorSuitability ?? (humorAppropriateness ? 0.5 : 0)
        self.humorSuitability = suitability.isFinite ? min(max(suitability, 0), 1) : 0
        self.userReportedState = userReportedState
        self.turnRelation = turnRelation
        self.activeTopic = activeTopic
        self.artifactContext = artifactContext
        self.pragmaticResponseAct = pragmaticResponseAct
        self.responseScope = responseScope
        self.capabilityRequirement = capabilityRequirement
    }

    /// The safe default when no reasoning is available at all — every
    /// opinion absent, maximum uncertainty, so callers naturally prefer
    /// deterministic, context-only behavior.
    public static let minimal = ConversationUnderstanding(
        communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
        userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil,
        humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 1.0
    )
}
