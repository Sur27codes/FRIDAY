import Foundation

/// P2-M5V5 §2 — "what FRIDAY knows," classified from a real
/// `CommandRuntimeOutcome`. A closed, deterministic classification of
/// which real Go `response.go` template family produced this
/// interaction's text — NOT a claim about user intent beyond what the
/// runtime itself already decided. `.other` is the safe default for any
/// outcome/text this file doesn't specifically recognize yet (mirrors
/// `ResponsePresenting`'s own "unknown -> safest default, never crash"
/// discipline).
public enum ResponseFamily: Sendable, Equatable, CaseIterable {
    case systemStatusSuccess
    case createNoteSuccess
    case genericSuccess
    case unsupportedIntent
    case ambiguousIntent
    case invalidRequest
    case irValidationFailed
    case policyDenied
    case policyUnavailable
    case capabilityUnavailable
    case executionFailed
    case verificationFailed
    case verificationNeedsReview
    case cancelled
    case alreadyTerminal
    case duplicateRequest
    case internalError
    case transportFailure
    case other
}

/// P2-M5V5 §19 — an explicitly bounded, honest identity model. FRIDAY
/// has no speaker-identification subsystem at all (§19: "Do NOT identify
/// speakers from voice characteristics"), so `.ownerLocal` — "a single
/// local owner, no personalization by assumed identity" — is the only
/// state this codebase can honestly report today. `.authenticatedOwner`/
/// `.authenticatedKnownUser` are declared now, exactly like
/// `AudioState.processing`/`.speaking` were declared at P2-M3 before
/// P2-M4/P2-M5 gave them real behavior, so a future, separately
/// authorized authentication subsystem doesn't need to change this
/// enum's shape — nothing in this milestone ever produces them.
public enum UserContext: Sendable, Equatable {
    case ownerLocal
    case authenticatedOwner
    case authenticatedKnownUser
    case unknownUser
}

/// P2-M5V5 §2 — "response latency category," when genuinely known. No
/// caller currently measures and supplies real elapsed time into
/// `ConversationContextCompiler`, so this is always `nil` today —
/// declared for the same "architecture-ready, not yet populated" reason
/// as `UserContext`'s unused cases. See §17's processing-acknowledgment
/// design note for the real, disclosed reason this isn't wired up yet
/// (it would require touching the speaking state machine).
public enum LatencyCategory: Sendable, Equatable {
    case fast
    case normal
    case slow
}

/// P2-M5V5 §2 — the compiled "what FRIDAY knows" model, deliberately
/// containing only facts derivable from a real, already-terminal
/// `CommandRuntimeOutcome` (plus the small, explicitly-bounded
/// conversation history `DeterministicResponsePresenter` already tracks
/// for repetition control, §15). Never infers identity/gender/age/
/// relationship/emotion from voice (§2's own explicit prohibition) —
/// there is no field here that could even carry such a claim.
public struct ConversationContext: Sendable, Equatable {
    /// Identifies this one interaction — currently the same value as
    /// `taskID` (the runtime's own real, unique per-interaction
    /// identifier; P2-M5 has no separate interaction-vs-task distinction
    /// yet, so reusing it here is honest, not a placeholder for a
    /// missing concept).
    public let interactionID: String
    public let taskID: String
    /// The real Go `Outcome` string (e.g. `"SUCCESS"`,
    /// `"UNSUPPORTED_INTENT"`), or `"(transport failure)"` for the one
    /// case that never reached a real Go `Response` at all.
    public let outcomeCode: String
    public let responseFamily: ResponseFamily
    public let wasSuccess: Bool
    /// True only for a genuine SUCCESS — per `response.go`'s own doc
    /// comment, "every SUCCESS message is only ever constructed from
    /// state this Runtime has already durably confirmed," so this is
    /// currently always equal to `wasSuccess`; kept as its own field
    /// (rather than reusing `wasSuccess` directly at call sites) so a
    /// future outcome type with graded confidence doesn't require a
    /// breaking change here.
    public let isVerifiedData: Bool
    /// True for `AMBIGUOUS_INTENT` specifically — the one real outcome
    /// where the runtime is explicitly asking for more information
    /// rather than reporting success or failure.
    public let needsClarification: Bool
    /// True only for outcomes where retrying the exact same request
    /// could plausibly succeed later (a transient/availability problem)
    /// — never true for outcomes retrying won't change (unsupported,
    /// denied, already-terminal, a validation failure needing different
    /// input, etc.).
    public let isRetryable: Bool
    /// Whether a spoken follow-up could genuinely move this interaction
    /// forward. Currently always `false` — see `ResponseRealizer`'s own
    /// doc comment for why this project does not yet speak a follow-up
    /// question implying a capability (hearing and acting on the
    /// answer) that does not exist.
    public let isFollowUpMeaningful: Bool
    /// Always `true` today — P2-M5 has no multi-turn conversational
    /// state; every `WakeCoordinator` interaction is independently wake-
    /// triggered and independently submitted (P2-M4R's own correlation-
    /// ID-uniqueness fix guarantees this at the runtime-request level).
    /// Declared as a real field, not hardcoded at every call site, so a
    /// future genuine continuation concept has one place to change.
    public let isFreshInteraction: Bool
    /// A small, bounded window of recently-selected response families
    /// (most-recent last) — populated by `DeterministicResponsePresenter`
    /// for repetition control (§15), never persisted, never longer than
    /// a few entries.
    public let recentResponseFamilies: [ResponseFamily]
    public let outputDeviceContext: String?
    public let latencyCategory: LatencyCategory?
    public let userContext: UserContext
    /// Present only for `.createNoteSuccess` — the exact title already
    /// extracted from Go's own `Created and verified note "<title>".`
    /// text by `ConversationContextCompiler`, so `ResponseRealizer` never
    /// needs to re-parse raw text itself (§1: each stage only sees the
    /// typed facts the previous stage already derived).
    public let noteTitleForRealization: String?
    /// Present only for `.ambiguousIntent` — the exact missing-field name
    /// already extracted from Go's own `(missing: X)` text, if the shape
    /// matched; `nil` means the field couldn't be identified and
    /// `ResponseRealizer` falls back to a generic clarification.
    public let ambiguousMissingField: String?
    /// P2-M5V7 §5 — real, structured evidence about WHY a failure
    /// happened, when a caller genuinely has it. `nil` for every
    /// currently-real outcome in this codebase — no Go template in
    /// `services/runtime/response/response.go` carries structured
    /// failure evidence today (disclosed, not hidden). Exists so a
    /// future runtime field carrying real evidence has a typed place to
    /// arrive, and so `DeterministicConversationReasoner` never has to
    /// invent a cause ("I couldn't reach the service") without one.
    public let failureEvidence: String?
    /// The runtime's own already-audited, already-safe text for this
    /// interaction (Go's `response.go` text for a real outcome, or the
    /// fixed transport-failure placeholder). `ResponseRealizer` uses this
    /// ONLY for `.other` — an outcome/text shape this file does not
    /// specifically recognize — where the one safe, truthful thing to do
    /// is relay the runtime's own text unchanged rather than guess at a
    /// rewording (the same "never silently disappear" safety property
    /// this whole rewording layer has always depended on). Every
    /// recognized family ignores this field entirely and speaks its own
    /// curated phrasing instead.
    public let rawRuntimeText: String

    public init(
        interactionID: String, taskID: String, outcomeCode: String, responseFamily: ResponseFamily,
        wasSuccess: Bool, isVerifiedData: Bool, needsClarification: Bool, isRetryable: Bool,
        isFollowUpMeaningful: Bool, isFreshInteraction: Bool = true, recentResponseFamilies: [ResponseFamily] = [],
        outputDeviceContext: String? = nil, latencyCategory: LatencyCategory? = nil, userContext: UserContext = .ownerLocal,
        noteTitleForRealization: String? = nil, ambiguousMissingField: String? = nil, rawRuntimeText: String = "",
        failureEvidence: String? = nil
    ) {
        self.interactionID = interactionID
        self.taskID = taskID
        self.outcomeCode = outcomeCode
        self.responseFamily = responseFamily
        self.wasSuccess = wasSuccess
        self.isVerifiedData = isVerifiedData
        self.needsClarification = needsClarification
        self.isRetryable = isRetryable
        self.isFollowUpMeaningful = isFollowUpMeaningful
        self.isFreshInteraction = isFreshInteraction
        self.recentResponseFamilies = recentResponseFamilies
        self.outputDeviceContext = outputDeviceContext
        self.latencyCategory = latencyCategory
        self.userContext = userContext
        self.noteTitleForRealization = noteTitleForRealization
        self.ambiguousMissingField = ambiguousMissingField
        self.rawRuntimeText = rawRuntimeText
        self.failureEvidence = failureEvidence
    }

    /// P2-M5V7 — a copy of this context with `failureEvidence` replaced.
    /// Exists so a caller that genuinely HAS real failure evidence (a
    /// future runtime field, or a harness/test fixture demonstrating the
    /// grounded-failure path) can attach it without `ConversationContextCompiler`'s
    /// own required protocol signature needing to change (§0: preserve
    /// the P2-M5V5/V6 `ConversationContextCompiling` contract exactly).
    public func withFailureEvidence(_ evidence: String?) -> ConversationContext {
        ConversationContext(
            interactionID: interactionID, taskID: taskID, outcomeCode: outcomeCode, responseFamily: responseFamily,
            wasSuccess: wasSuccess, isVerifiedData: isVerifiedData, needsClarification: needsClarification,
            isRetryable: isRetryable, isFollowUpMeaningful: isFollowUpMeaningful, isFreshInteraction: isFreshInteraction,
            recentResponseFamilies: recentResponseFamilies, outputDeviceContext: outputDeviceContext,
            latencyCategory: latencyCategory, userContext: userContext, noteTitleForRealization: noteTitleForRealization,
            ambiguousMissingField: ambiguousMissingField, rawRuntimeText: rawRuntimeText, failureEvidence: evidence
        )
    }
}

/// P2-M5V5 §11 — how confidently `ResponseRealizer`'s chosen text can be
/// asserted, for diagnostics/testing — a lightweight companion to
/// `wasSuccess`/`isVerifiedData`, not a replacement for either.
public enum TruthClassification: Sendable, Equatable {
    /// A genuine, durably-confirmed SUCCESS.
    case verifiedSuccess
    /// A genuine, definitive non-success the runtime is certain about
    /// (unsupported, denied, already-terminal, etc.).
    case definitiveFailure
    /// The runtime itself doesn't know the root cause (transport
    /// failure, internal error) — spoken text must not invent one.
    case unknownCause

    /// P2-M5V6 §26/§27 — factored out of `DeterministicResponsePresenter`
    /// so every presenter (`DeterministicResponsePresenter`,
    /// `ConversationalResponsePresenter`) computes this the SAME way —
    /// one rule, never duplicated.
    public static func classify(wasSuccess: Bool, family: ResponseFamily) -> TruthClassification {
        if wasSuccess { return .verifiedSuccess }
        return (family == .transportFailure || family == .internalError) ? .unknownCause : .definitiveFailure
    }
}

/// P2-M5V5 §9/§11 — declared for architecture-completeness (a future
/// multi-turn pass has a typed place to put this), but **never rendered
/// into spoken text by this milestone's `ResponseRealizer`** — see that
/// type's own doc comment for the disclosed reason: this system has no
/// mechanism to hear or act on a spoken answer to a follow-up question
/// yet, and asking one anyway would imply an interactive capability
/// that does not exist.
public enum FollowUpClassification: Sendable, Equatable {
    case none
    case clarificationAvailable(missingField: String?)
    case retryOfferAvailable
}
