import Foundation

/// P2-M5V7 §1 — a real, closed classification of what the user's
/// utterance IS AS A CONVERSATIONAL ACT, independent of whatever runtime
/// outcome happens to accompany it. This is the fix for P2-M5V6's own
/// disclosed gap: "FRIDAY can classify runtime outcomes, but does not
/// yet sufficiently understand what the user's utterance means as a
/// conversational act." A `personalUpdate` ("I finally fixed that bug")
/// is not a `command`, even if some outcome text happens to say
/// `SUCCESS` — `InteractionMode`/`ActionExecutionState` (derived FROM
/// this) are what actually gate whether completion language may ever be
/// spoken.
public enum DialogueAct: Sendable, Equatable {
    case command
    case request
    case question
    case statement
    /// "I finally fixed that bug." — sharing news, not asking for
    /// anything.
    case personalUpdate
    case acknowledgement
    /// "No, call it weekend groceries."
    case correction
    /// The user is answering/resolving a clarifying question FRIDAY (or
    /// the conversation) previously raised.
    case clarification
    /// "Don't change anything yet." — a positive instruction about how
    /// FRIDAY should behave, not a request to perform an action.
    case constraint
    /// A constraint specifically phrased as a negative ("don't," "not
    /// yet") — kept distinct from `constraint` so a realizer CAN phrase
    /// them slightly differently, but both drive the same
    /// `InteractionMode.constraint`/`ActionExecutionState.notRequested`
    /// outcome.
    case prohibition
    /// The user answering a permission/approval prompt ("yes, go
    /// ahead" / "no, don't").
    case permissionResponse
    /// "Can you check it again?" right after a related prior turn.
    case followUp
    /// "Why didn't that work?" / "Why do you need approval?"
    case explanationRequest
    /// "Are you sure?" / "Did that actually work?"
    case confirmationRequest
    /// "That was annoying." — an evaluative remark, not a request.
    case socialRemark
    case jokeOrPlayfulRemark
    case greeting
    case farewell
    /// P2-M5V8.1-S §10 — "I need to email my professor about missing
    /// class." A stated NEED/INTENT for FRIDAY's help, distinct from a
    /// direct command ("Send this email...") or a bare statement. Still
    /// resolves to `InteractionMode.actionRequest` (FRIDAY should help),
    /// but realization must never claim the described action already
    /// completed merely because a generic runtime outcome is attached —
    /// intent ≠ verified execution.
    case needStatement
    /// P2-M5V8.1-S §11 — "Make it a little less formal." / "Make that
    /// sound less stiff." / "Actually, keep this professional." A
    /// refinement of an EXISTING drafting/conversational artifact's tone,
    /// not a fresh external action — realization must acknowledge the
    /// stylistic note without claiming an external action (e.g. sending)
    /// occurred.
    case styleRefinement
    case unknown
}

/// P2-M5V7 §2 — makes command-vs-conversation EXPLICIT, so a
/// conversational utterance can never inherit action-success wording
/// merely because an outcome happens to be attached to it.
public enum InteractionMode: Sendable, Equatable {
    case actionRequest
    case informationRequest
    case conversational
    case correction
    case constraint
    case clarification
}

/// P2-M5V7 §3 — the authoritative, typed fact response realization MUST
/// consult before ever using completion language. `.notRequested` is the
/// hard gate `ResponseValidation` 2.0 enforces (§21): no "Done"/
/// "Completed"/"It's ready" wording is permitted when this is
/// `.notRequested`, REGARDLESS of what any accompanying runtime outcome
/// says — a defense-in-depth rule, not just a classification.
public enum ActionExecutionState: Sendable, Equatable {
    case notRequested
    case requestedNotStarted
    case executedSucceeded
    case executedFailed
    case denied
    case unsupported
    case unknown
}

/// P2-M5V8.1-Q §2 — a LOCAL, deterministic classification of whether
/// answering this turn requires a real capability (a friday-daemon
/// action, or authoritative runtime/account/sensor data) at all, kept
/// deliberately SEPARATE from `InteractionMode`/`ActionExecutionState`:
/// a turn can be an `.informationRequest` (the user IS asking for
/// information) while requiring NO capability whatsoever to answer
/// truthfully ("why is the sky red at sunset" — general knowledge) or
/// while requiring one absolutely ("what's my battery percentage" —
/// only a real sensor capability can answer this truthfully). Computed
/// ONLY from the transcript's own wording — NEVER from the external
/// model (§2: "Do NOT ask the external LLM whether a capability is
/// required" — the whole reason this type exists is to keep that
/// decision authoritative and local, the same discipline every other
/// safety-critical field in this file already follows).
public enum CapabilityRequirement: Sendable, Equatable {
    /// A pure informational/content-generation turn (general knowledge,
    /// explanation, definition, comparison, brainstorming, writing,
    /// advice, summarization of already-supplied text) — friday-daemon
    /// finding no matching capability intent for a turn like this is
    /// EXPECTED and does not mean FRIDAY is unable to help.
    case notRequired
    /// The turn names or implies a real-world action, or asks about
    /// current/private/runtime/sensor/account state that only a real
    /// capability could truthfully supply. The existing capability/
    /// execution-truth machinery governs these completely unchanged.
    case required
    /// Local semantics genuinely cannot tell — fails CLOSED to the
    /// pre-P2-M5V8.1-Q behavior (never silently treated as `.notRequired`,
    /// which could let the model fabricate a runtime/private fact).
    case unknown
}

/// P2-M5V7 §4 — a structured conversational constraint the user
/// explicitly stated. Never inferred from tone/acoustics — only ever
/// derived from literal wording, mirroring `ConversationUnderstanding.explicitUrgency`'s
/// own "explicit language only" discipline.
public enum ExplicitConstraint: Sendable, Equatable {
    case doNotAct
    case doNotModify
    case waitForConfirmation
    case keepExistingState
    case answerOnly
    case explainOnly
}

/// P2-M5V7 §5 — grounded failure reasoning. `.known` may ONLY be
/// constructed from real evidence a caller actually possesses (e.g. a
/// future runtime field carrying structured failure detail) — nothing in
/// this milestone invents `type`/`evidence` strings from thin air.
/// Today, no real Go template in `services/runtime/response/response.go`
/// carries structured failure evidence, so `DeterministicConversationReasoner`
/// always produces `.unknown` for every currently-real outcome — this is
/// disclosed, not hidden (see `ConversationContext.failureEvidence`'s own
/// doc comment).
public enum FailureReason: Sendable, Equatable {
    case known(type: String, evidence: String)
    case unknown
}

/// P2-M5V7 §6 — retryability is a SEPARATE, more conservative signal
/// than `ConversationContext.isRetryable`/`ResponsePurpose.retryableFailure`
/// (kept unchanged for §0 preservation — it still drives register/prosody
/// selection). `Retryability` specifically gates whether spoken text may
/// ever claim retry support ("Want me to try again?") — `.allowed` only
/// when a caller has REAL evidence retrying would be meaningful;
/// `.unknown` is the safe, honest default for a generic execution
/// failure with no such evidence (§6: "do NOT infer retryability from
/// generic execution failure").
public enum Retryability: Sendable, Equatable {
    case allowed
    case notAllowed
    case unknown
}

/// P2-M5V7 §12 — richer than `HumorIntent` (kept, unchanged, for §0
/// preservation): distinguishes "not allowed at all" from "allowed but
/// not called for" from "allowed and would land well" — the REALIZER,
/// not the policy, makes the final call on whether to actually use it
/// (§12: "the natural realizer decides whether to actually use it").
public enum HumorDecision: Sendable, Equatable {
    case prohibited
    case unnecessary
    case optional(strength: Double)
    case appropriate(strength: Double)

    /// Whether a realizer is even PERMITTED to use humor for this
    /// decision — `.prohibited` is the only `false` case.
    public var permitted: Bool {
        if case .prohibited = self { return false }
        return true
    }
}

/// P2-M5V8.1-S2.2 §5/§6 — a bounded, typed representation of a NEGATIVE
/// situational claim the user's OWN CURRENT-TURN words asserted ("the
/// service is down," "the build is failing"). Deliberately NOT verified
/// world truth (§6: "the user report is NOT equivalent to verified world
/// truth") — `source` exists specifically to keep that provenance
/// visible and distinct from `.verifiedRuntime`/`.inferred` (§6's own
/// enumerated list), even though only `.userReported` is ever actually
/// produced by this codebase today (no runtime health-check capability
/// exists to populate `.verifiedRuntime`). Real, live-observed failure
/// this closes: "Production is down now." → a candidate saying
/// "Everything's in order." was accepted — FRIDAY must not directly
/// contradict a user-asserted negative state without CONTRADICTORY
/// VERIFIED evidence, which this codebase never has today, so a
/// same-turn "all clear" claim is always unsupported.
public struct UserReportedState: Sendable, Equatable {
    public enum Polarity: Sendable, Equatable { case negative }
    public enum Source: Sendable, Equatable { case userReported, verifiedRuntime, inferred, unknown }

    public let polarity: Polarity
    public let source: Source

    public init(polarity: Polarity, source: Source) {
        self.polarity = polarity
        self.source = source
    }
}

/// P2-M5V8.1-S3 §10 — a CONVERSATIONAL choice about what KIND of
/// response move to make. Distinct from `DialogueAct` (what the
/// utterance IS) and `InteractionMode` (whether it needs treating as an
/// action) — this is downstream of both, purely about wording/tone
/// selection, and is NEVER authoritative (§20: "these remain non-
/// authoritative — local evidence may override them").
public enum PragmaticResponseAct: Sendable, Equatable {
    case acknowledge
    case celebrate
    case commiserate
    case clarify
    case answer
    case explain
    case offerHelp
    case continueDraft
    case applyStyleRefinement
    case confirmConstraint
    case reportFailure
    case reportSuccess
    case unsupported
    case farewell
    case greeting
}

/// P2-M5V8.1-O.5 §1/§6 — HOW MUCH the realized response should say,
/// distinct from `PragmaticResponseAct` (WHAT KIND of move to make) —
/// orthogonal, since e.g. a style refinement and a permission denial can
/// BOTH call for a short answer, while a needStatement can call for
/// either a short clarifying question OR (rarely) a long-form draft
/// depending on what the user actually asked for. ALWAYS locally/
/// authoritatively determined (never trusted from, or reported back by,
/// a model reasoner — see `ConversationReasoning.responseScope(...)`'s
/// own doc comment) and used ONLY as an outbound, non-authoritative
/// STEERING instruction to the unified realizer (§6: "do not give the
/// model new authority" — nothing here is ever decoded FROM the model,
/// only sent TO it).
///
/// Real live failure this exists to fix: a needStatement or style-
/// refinement turn occasionally produced an entire fabricated placeholder
/// artifact (a full email with "[date]"/"[Your Name]" fields) instead of
/// the short clarifying question or brief acknowledgement the codebase's
/// OWN deterministic realizer already knows is correct — driving real,
/// measured tail latency without any answering user need, since
/// `ArtifactContext` never stores real drafted body text in the first
/// place (see its own doc comment) for a genuine rewrite to work from.
public enum ResponseScope: Sendable, Equatable {
    /// A short conversational reaction/acknowledgement/reaction/greeting/
    /// farewell — the common case for ordinary conversational turns.
    case conversationalShort
    /// The user's need/artifact request lacks enough content to act on —
    /// ask exactly ONE concise clarifying question, never fabricate
    /// placeholder content to fill the gap.
    case clarifyingQuestion
    /// A short, factual status statement (e.g. a constraint
    /// acknowledgement) — brief, not conversationally warm-and-fuzzy, not
    /// an explanation of WHY.
    case briefStatus
    /// A short explanation of a grounded prior outcome (failure cause,
    /// permission denial) — a sentence or two, never an essay, and never
    /// inventing detail beyond what's already grounded.
    case briefExplanation
    /// A genuine artifact draft may be produced — reachable ONLY when
    /// real drafted body text is actually available locally to work
    /// from, which this codebase does not currently store (see
    /// `ArtifactContext`'s own doc comment); kept for forward
    /// compatibility, not currently ever selected by `responseScope(...)`.
    case artifactDraft
    /// A genuine artifact rewrite may be produced — same forward-
    /// compatibility note as `artifactDraft`.
    case artifactRewrite
    /// The user explicitly asked for the full/complete/entire content
    /// ("draft the whole email," "give me the full report") — long-form
    /// generation is legitimate and must not be truncated to chase a
    /// latency target (§9: "do not truncate real user requests").
    case longFormRequested
}

/// P2-M5V8.1-S3 §3/§25/§26 — whether the CURRENT turn continues,
/// corrects, refines, or departs from the prior conversational thread.
/// Locally/authoritatively determined the same way `DialogueAct` is
/// (never trusted from a model reasoner) since it directly drives
/// whether prior context (topic/artifact) is carried forward or reset —
/// carrying forward the WRONG context is itself a relevance failure,
/// but this codebase's own established discipline is that continuity
/// decisions, like truth decisions, stay local.
public enum ConversationTurnRelation: Sendable, Equatable {
    case newTopic
    case continuation
    case correction
    case refinement
    case reaction
    case explanation
    case constraint
}

/// P2-M5V8.1-S3 §4 — a BOUNDED continuity signal, deliberately NOT a
/// domain taxonomy: just enough to tell "same subject as last turn" from
/// "new subject," so "It was one environment variable." can be
/// recognized as continuing "I finally fixed that bug." rather than
/// read as an unrelated, topic-less status update.
public enum ActiveConversationTopic: Sendable, Equatable {
    case bugOrIssue
    case draftOrMessage
    case runtimeStatus
    case noteOrContent
    case unsupportedRequest
    case permissionOrPolicy
    case none
}

/// P2-M5V8.1-S3 §5 — a BOUNDED, conversation-scoped drafting/editing
/// context. Deliberately carries NO actual drafted text (this codebase
/// has no real drafting-capability output to store) — only `kind` (what
/// KIND of artifact) and `requestedStyle` (the user's LATEST explicit
/// tone request, §8: "the user's latest explicit refinement wins")
/// persist, and only for the lifetime of the bounded conversation memory
/// that already exists (`ConversationMemoryStoring`'s own fixed-size window).
public struct ArtifactContext: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case email, note, message, document, unspecified }
    public enum Style: Sendable, Equatable { case formal, professional, friendly, casual, warm, concise, direct }

    public let kind: Kind
    public let requestedStyle: Style?

    public init(kind: Kind, requestedStyle: Style? = nil) {
        self.kind = kind
        self.requestedStyle = requestedStyle
    }
}
