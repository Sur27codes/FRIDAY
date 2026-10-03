import Foundation

/// P2-M5V6 §13 — a richer sibling of `ResponseRealizing`, carrying the
/// extra context (`ConversationUnderstanding`, `NaturalResponsePlan`,
/// recent turns) a register/humor-aware realizer needs. Kept as its OWN
/// protocol rather than widening `ResponseRealizing`'s existing
/// signature (§0: preserve the P2-M5V5 realizer/protocol unchanged).
///
/// **Returning `nil` is a first-class, expected outcome** — it means
/// "this realizer has nothing safer/better to offer for this input,"
/// and signals `ConversationalResponsePresenter` to fall back to the
/// unchanged, guaranteed `DeterministicResponseRealizer` (§28's required
/// fallback hierarchy). A realizer must never return an empty string or
/// throw to signal this — `nil` is the one, explicit, testable signal.
///
/// **P2-M5V7 exception:** for `understanding.interactionMode ==
/// .conversational` or `.constraint`, a conforming realizer must NEVER
/// return `nil` — the deterministic fallback (`DeterministicResponseRealizer`)
/// has no transcript/dialogue-act awareness at all and would produce
/// action-completion wording ("Done.") for an utterance that never
/// requested an action in the first place (§2/§3). `ConversationalResponsePresenter`
/// enforces this as a hard safety net regardless (§21), but a well-
/// behaved realizer should handle it directly for better wording.
public protocol NaturalConversationRealizing: Sendable {
    func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String?
}

/// The guaranteed, deterministic, no-LLM implementation — genuinely more
/// register/humor-aware than the flat P2-M5V5 `DeterministicResponseRealizer`
/// for a small, deliberately narrow set of families where doing so is
/// SAFELY truthful, and `nil` (defer to the flat fallback) everywhere
/// else. This is the realizer `ConversationalResponsePresenter` actually
/// uses by default this milestone (no LLM exists yet) — it is real
/// evidence the whole pipeline works end-to-end, not a placeholder.
public struct DeterministicNaturalResponseRealizer: NaturalConversationRealizing {
    public init() {}

    public func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
        // P2-M5V7 §2/§3: conversational-act classification ALWAYS wins
        // over whatever runtime family/text happens to be attached —
        // this is the actual fix for "I finally fixed that bug" → "Done.".
        switch understanding.interactionMode {
        case .conversational:
            let recentResponseTexts = recentTurns.suffix(3).map(\.responseText)
            // P2-M5V8.1-P.1 §2 — audit fix: a WEAK dialogueAct signal
            // (`.statement`/`.acknowledgement` — the classification a
            // plain follow-up remark falls to when nothing more specific
            // matched) must not go straight to a generic reaction pool
            // that only ever looked at dialogueAct/turnRelation. It must
            // first consult activeTopic/activeArtifact/the runtime family
            // truth still in play — the SAME signals a stronger
            // dialogueAct would already use — so a provider-fallback turn
            // realizes the LOCAL conversational plan instead of pattern-
            // matching isolated transcript words. A strong dialogueAct
            // (personalUpdate/greeting/farewell/socialRemark/acknowledgement)
            // always wins on its own terms below, unaffected.
            if let contextAware = Self.contextAwareConversationalContinuation(
                dialogueAct: understanding.dialogueAct, turnRelation: understanding.turnRelation, activeTopic: understanding.activeTopic,
                artifact: understanding.artifactContext, context: context, plan: plan, taskID: context.taskID, avoiding: avoiding,
                recentResponseTexts: recentResponseTexts
            ) {
                return contextAware
            }
            return Self.conversationalAcknowledgment(
                dialogueAct: understanding.dialogueAct, turnRelation: understanding.turnRelation, activeTopic: understanding.activeTopic,
                userReportedState: understanding.userReportedState, greetingToken: understanding.userGoal,
                taskID: context.taskID, avoiding: avoiding, recentResponseTexts: recentResponseTexts
            )
        case .constraint:
            return Self.constraintAcknowledgment(constraints: understanding.explicitConstraints)
        case .actionRequest, .informationRequest, .correction, .clarification:
            // P2-M5V8.1-S2 §11/§13 — checked HERE, before the family-based
            // switch below, and UNCONDITIONALLY (not gated on
            // actionExecutionState, which `ConversationalResponsePresenter.authoritative`
            // now always forces to `.notRequested` for these two dialogue
            // acts regardless of interactionMode — see that function's
            // own doc comment). A stated NEED/INTENTION or a STYLE
            // REFINEMENT of an existing artifact never itself proves a
            // verified EXTERNAL action occurred; `genericSuccess` (a
            // coarse, non-specific family) never proves the SPECIFIC
            // described action (e.g. an email being sent) actually
            // completed. Fixes two real live-model failures: "I need to
            // email my professor..." → "That's taken care of." and "Make
            // it a little less formal." → "It's all set."
            //
            // P2-M5V8.1-S3 §6/§7/§8 — now CONTEXTUALLY AWARE via
            // `artifactContext` rather than one flat line each: the
            // needStatement/styleRefinement wording differs by WHAT kind
            // of artifact is in play and WHAT style was actually
            // requested, closing the exact live failure class this pass
            // exists to fix ("I'm here whenever you need me."/"Anytime.
            // You know where to find me." — both lost the drafting
            // context completely).
            if understanding.dialogueAct == .needStatement {
                return Self.needStatementContinuation(artifact: understanding.artifactContext)
            }
            if understanding.dialogueAct == .styleRefinement {
                return Self.styleRefinementContinuation(artifact: understanding.artifactContext)
            }
            // P2-M5V8.1-P §13 — a correction should sound natural without
            // ever implying another execution occurred: acknowledge WHICH
            // item is meant, using only `correctionTarget` (already
            // locally/authoritatively determined — see `ConversationalResponsePresenter.authoritative`'s
            // own doc comment), never a claim that anything was
            // re-created/re-run. `nil`/anything else defers further down
            // the fallback chain rather than guessing.
            if understanding.dialogueAct == .correction {
                switch understanding.correctionTarget {
                case "earlier": return "Got it—the earlier one."
                case "new": return "Got it—the new one."
                // P2-M5V8.1-P.2-FINAL-CLOSURE §10/§11/§12 — a GENERIC
                // referent ("the other one," "that one") is NOT uniquely
                // resolvable from wording alone — ask, never pretend
                // acknowledgement equals resolution. `nil` (a NAMED
                // correction, e.g. "I meant groceries") still defers
                // further down the chain unchanged — the name itself
                // already grounds it, nothing to ask about.
                case "ambiguous": return "Which one do you mean?"
                default: break
                }
            }
            break // fall through to the family-based realization below
        }

        switch context.responseFamily {
        case .createNoteSuccess:
            // Defense-in-depth (§21): even though `.createNoteSuccess`
            // can only exist when the runtime genuinely confirmed a
            // created note, never speak completion wording if the
            // reasoner somehow concluded no action was requested.
            guard understanding.actionExecutionState != .notRequested else { return nil }
            // Truthfulness note: the title spoken here always comes from
            // `context.noteTitleForRealization`, extracted from Go's own
            // already-audited `Created and verified note "<title>".`
            // text — so regardless of whether this turn was a correction
            // of a previous one, the title spoken is the runtime's own
            // CONFIRMED title, never a guess at what the user meant to
            // rename it to (§15/§27: never claim a capability the
            // runtime didn't confirm).
            let title = context.noteTitleForRealization ?? "note"
            if understanding.continuationOfPreviousTurn {
                return "Got it. Your \(title) note's ready."
            }
            if plan.socialRegister == .professional {
                return "It's ready. Would you like me to review the wording?"
            }
            return nil
        case .unsupportedIntent:
            guard plan.humorAllowance else { return nil }
            // P2-M5V8.1-P §6 — humor here is safe BY CONSTRUCTION: this
            // branch only ever runs for a genuinely unsupported, low-
            // stakes request (never a real permission denial — §12/§7
            // keep those on the `groundedFailureText`/policy path, which
            // never routes through here), and only when `plan.humorAllowance`
            // (a purely local, register-driven decision) already permits it.
            return DeterministicResponseRealizer.pick(
                ["Not quite in my skill set yet.", "Not yet. Give me a little more time.", "I can't do that one yet.", "Afraid not. My launch credentials are conspicuously absent."],
                taskID: context.taskID, avoiding: avoiding
            )
        case .executionFailed, .capabilityUnavailable, .policyUnavailable:
            // P2-M5V7 §5/§6 — THE fix for the mission's own disclosed bug:
            // never invent a cause ("I couldn't reach it") without
            // grounded evidence, and never offer a retry unless
            // `Retryability.allowed`.
            return Self.groundedFailureText(understanding: understanding)
        case .genericSuccess:
            // needStatement/styleRefinement are now handled ABOVE, before
            // this family-based switch — actionExecutionState for them is
            // always `.notRequested` (see `ConversationalResponsePresenter.authoritative`),
            // so this guard's remaining job is exactly its original one:
            // no completion wording for any OTHER genuinely-not-requested turn.
            guard understanding.actionExecutionState != .notRequested else { return nil }
            guard plan.socialRegister == .professional else { return nil }
            return "It's done. Let me know if you'd like anything adjusted."
        default:
            return nil
        }
    }

    /// P2-M5V8.1-P.1 §2 — the fix for two real live-fallback failures:
    /// "Mention we still want to keep working with them." (a plain
    /// follow-up continuing an ACTIVE DRAFT — `activeTopic == .draftOrMessage`,
    /// `artifactContext != nil`) used to fall through to the bugOrIssue-
    /// flavored reaction pool below and answer "Classic.", losing the
    /// drafting context entirely; "No really, this one actually matters
    /// to me." (a plain follow-up continuing an UNSUPPORTED-CAPABILITY
    /// topic, with humor now suppressed by explicit seriousness) used to
    /// get the SAME generic reaction pool instead of restating the
    /// still-true "not supported" fact. Only fires for a WEAK dialogueAct
    /// signal continuing/refining a topic that carries real, still-
    /// relevant meaning — `nil` defers to `conversationalAcknowledgment`
    /// exactly as before for every other case (a genuinely new topic, a
    /// bugOrIssue reaction, or any stronger dialogueAct).
    private static func contextAwareConversationalContinuation(
        dialogueAct: DialogueAct, turnRelation: ConversationTurnRelation, activeTopic: ActiveConversationTopic,
        artifact: ArtifactContext?, context: ConversationContext, plan: NaturalResponsePlan, taskID: String, avoiding: String?,
        recentResponseTexts: [String]
    ) -> String? {
        guard dialogueAct == .statement || dialogueAct == .acknowledgement else { return nil }
        guard turnRelation == .continuation || turnRelation == .refinement else { return nil }
        switch activeTopic {
        case .draftOrMessage where artifact != nil:
            // §7 — one short, natural acknowledgement that the new detail
            // will be incorporated; never claims it was ALREADY added
            // (that would be the exact action-claim-safety violation §9
            // exists to prevent — no artifact body text is ever actually
            // available to have mutated, see `ArtifactContext`'s own doc
            // comment).
            return DeterministicResponseRealizer.pick(
                ["Got it — I'll work that in.", "Sure, I'll add that.", "Noted — I'll include that."],
                taskID: taskID, avoidingAny: recentResponseTexts
            )
        case .unsupportedRequest:
            // §4/§12 — restates the still-true "not supported" fact
            // instead of a generic reaction; humor stays gated by the
            // SAME local `plan.humorAllowance` every other humor branch
            // already uses (never a new signal).
            if plan.humorAllowance {
                return DeterministicResponseRealizer.pick(
                    ["Still not something I can do, unfortunately.", "That one's still outside what I can do."],
                    taskID: taskID, avoidingAny: recentResponseTexts
                )
            }
            return "Understood — still not something I can do here."
        case .permissionOrPolicy:
            return "That's still not something I'm able to do."
        default:
            return nil
        }
    }

    /// P2-M5V7 §1, hardened by P2-M5V8.1-S3 §1/§9/§11 — real, non-nil
    /// acknowledgements for utterances that were never action requests at
    /// all. Deterministic (taskID-hashed where more than one truthful
    /// option exists), never claiming any capability was invoked. The
    /// `default` branch — reached by a bare `.statement` with no other
    /// signal — is where the real live failure lived: "It was one
    /// environment variable." (a `.continuation` of a `.bugOrIssue`
    /// topic, per `turnRelation`/`activeTopic`) used to get the SAME flat
    /// "Got it." as any unrelated statement, losing the conversational
    /// relationship between the two turns entirely (§1: "loses the
    /// conversational relationship between the turns"). Now a genuine
    /// REACTION set (§9: "Nice." "Of course it was." "Classic." "That
    /// tracks." — never one hardcoded string) is used specifically when
    /// `turnRelation == .continuation` of a `.bugOrIssue` topic.
    /// P2-M5V8.1-P.1 §2 — `activeTopic` is now an EXPLICIT parameter and
    /// the continuation-reaction pool is gated on `.bugOrIssue` again,
    /// matching what this doc comment always claimed: this pool was
    /// reachable for ANY continuation topic before this fix (the real,
    /// live-confirmed bug this pass exists to close — see
    /// `contextAwareConversationalContinuation`, which now owns every
    /// OTHER continuation topic and is consulted first).
    private static func conversationalAcknowledgment(
        dialogueAct: DialogueAct, turnRelation: ConversationTurnRelation, activeTopic: ActiveConversationTopic,
        userReportedState: UserReportedState?, greetingToken: String?, taskID: String, avoiding: String?,
        recentResponseTexts: [String] = []
    ) -> String {
        switch dialogueAct {
        case .personalUpdate:
            return DeterministicResponseRealizer.pick(
                ["Nice. What ended up causing it?", "Nice, glad you got it sorted.", "Finally. Good riddance to that one."],
                taskID: taskID, avoidingAny: recentResponseTexts
            )
        case .socialRemark:
            // P2-M5V8.1-P §5 — a bounded, pragmatically-chosen repertoire
            // rather than one flat string, so this doesn't sit alongside
            // every OTHER "Got it." in the conversation.
            return DeterministicResponseRealizer.pick(["Got it.", "Fair enough.", "Noted."], taskID: taskID, avoidingAny: recentResponseTexts)
        case .greeting:
            // P2-M5V8.1-P.1 §14 — mirror the user's OWN greeting token
            // when one was actually recognized (`greetingToken`, derived
            // ONLY from what they already said — never fabricated time-
            // of-day awareness this codebase doesn't have; see
            // `DeterministicConversationReasoner.greetingToken(lowerTranscript:)`'s
            // own doc comment). Falls back to the original time-neutral
            // pool when the greeting was something else recognized (e.g.
            // "hello") that isn't naturally mirrored the same way.
            switch greetingToken {
            case "morning": return DeterministicResponseRealizer.pick(["Morning.", "Morning. What's up?"], taskID: taskID, avoidingAny: recentResponseTexts)
            case "evening": return DeterministicResponseRealizer.pick(["Evening.", "Evening. What's up?"], taskID: taskID, avoidingAny: recentResponseTexts)
            case "afternoon": return "Afternoon."
            case "hey": return DeterministicResponseRealizer.pick(["Hey. What's up?", "Hey, good to hear from you."], taskID: taskID, avoidingAny: recentResponseTexts)
            case "hi": return DeterministicResponseRealizer.pick(["Hi. What's up?", "Hey, good to hear from you."], taskID: taskID, avoidingAny: recentResponseTexts)
            default:
                return DeterministicResponseRealizer.pick(
                    ["Hey, good to hear from you.", "Hey. What's up?", "Good to hear from you."], taskID: taskID, avoidingAny: recentResponseTexts
                )
            }
        case .farewell:
            return DeterministicResponseRealizer.pick(["Talk soon.", "Talk later.", "See you."], taskID: taskID, avoidingAny: recentResponseTexts)
        case .acknowledgement:
            return DeterministicResponseRealizer.pick(["Sure thing.", "Alright.", "Okay.", "Yeah."], taskID: taskID, avoidingAny: recentResponseTexts)
        default:
            // §13 — a user-reported problem gets an acknowledgement that
            // actually reads as one (not a generic "Got it."), without
            // asserting resolution or launching any action. §16 — a real
            // DECISION, not "always ask a follow-up": half these variants
            // are a plain reaction with no question at all.
            if userReportedState?.polarity == .negative {
                // P2-M5V8.1-P §7 — every variant here stays FOCUSED, never
                // celebrates/jokes/dramatizes: a plain reaction, at most a
                // low-intensity "that's serious," never more.
                return DeterministicResponseRealizer.pick(
                    ["That's not good.", "Ugh, that's frustrating.", "Got it. Want me to check what I can?", "That's rough. When did that start?", "Damn. That's serious."],
                    taskID: taskID, avoidingAny: recentResponseTexts
                )
            }
            // §9/§16 — a plain reaction continuing the same topic (e.g.
            // explaining the CAUSE of something already reported fixed)
            // doesn't need a follow-up question by default; a short,
            // natural reaction beat is enough. §11/§28 — avoided against
            // the last few turns' texts (not just the immediately
            // previous one), so this pool doesn't settle into repeating
            // "Of course it was." three turns running.
            if turnRelation == .continuation && activeTopic == .bugOrIssue {
                return DeterministicResponseRealizer.pick(
                    ["Of course it was.", "Classic.", "That tracks.", "Figures.", "There it is."], taskID: taskID, avoidingAny: recentResponseTexts
                )
            }
            // P2-M5V8.1-P.1 §25/§26 — the LAST bare hardcoded catchphrase
            // in this function; a real 20-turn endurance fixture caught
            // it looping ("Got it." 5 times across 20 mixed turns) once
            // every other branch here had already been diversified.
            // Pooled exactly like every sibling branch above.
            return DeterministicResponseRealizer.pick(["Got it.", "Alright.", "Okay."], taskID: taskID, avoidingAny: recentResponseTexts)
        }
    }

    /// P2-M5V7 §4 — real, non-nil acknowledgements for explicit
    /// constraints. NEVER executes anything, NEVER says "Done."
    private static func constraintAcknowledgment(constraints: [ExplicitConstraint]) -> String {
        if constraints.contains(.waitForConfirmation) { return "Got it. I'll wait for your go-ahead." }
        if constraints.contains(.answerOnly) { return "Got it. I'll just answer, nothing else." }
        if constraints.contains(.explainOnly) { return "Got it. I'll just explain, nothing else." }
        if constraints.contains(.keepExistingState) { return "Got it. I'll leave everything as is." }
        // `.doNotAct`/`.doNotModify` (and the empty-array safe default,
        // if a caller somehow reaches this with no specific constraint
        // identified) all read the same, most literal way (§4's own
        // example): "Got it. I won't change anything."
        return "Got it. I won't change anything."
    }

    /// P2-M5V8.1-S3 §6 — real live failures this fixes: "I'm here
    /// whenever you need me." / "What do you need?" both ignored the
    /// already-explicit need. Varies by `artifact.kind` so the question
    /// itself demonstrates the domain was actually understood, without
    /// claiming anything was sent.
    private static func needStatementContinuation(artifact: ArtifactContext?) -> String {
        switch artifact?.kind {
        case .email: return "What do you want to tell them?"
        case .message, .none: return "What do you want it to say?"
        case .note: return "What should it say?"
        case .document, .unspecified: return "What do you want to include?"
        }
    }

    /// P2-M5V8.1-S3 §7/§8 — real live failures this fixes: "Anytime. You
    /// know where to find me." lost the drafting context completely.
    /// Varies by the ACTUAL requested style (§8: "the user's latest
    /// explicit refinement wins" — `artifact.requestedStyle` already IS
    /// that latest value, carried forward turn to turn) rather than one
    /// flat "I'll adjust the tone." regardless of what was asked for.
    private static func styleRefinementContinuation(artifact: ArtifactContext?) -> String {
        switch artifact?.requestedStyle {
        case .casual: return "Sure — I'll make it more casual."
        case .professional: return "Got it — I'll keep it professional."
        case .formal: return "Got it — I'll keep it formal."
        case .friendly: return "Sure — I'll warm it up a bit."
        case .warm: return "Sure — I'll make it warmer."
        case .concise: return "Got it — I'll shorten it."
        case .direct: return "Got it — I'll make it more direct."
        case .none: return "Got it — I'll adjust the tone."
        }
    }

    /// P2-M5V7 §5/§6 — the grounded-failure/retryability text builder.
    /// `.known` failure reasons only ever mention a specific cause when
    /// the evidence text itself actually names one (connectivity/
    /// service-reachability wording); a `.known` reason whose evidence
    /// names nothing this builder recognizes gets the SAME neutral
    /// "That didn't go through." as before (P2-M5V8.1-P §11's honesty
    /// upgrade below is reserved for genuine `.unknown` — claiming "I
    /// don't know why" for a reason that IS actually known, just not
    /// recognized by `mentionsConnectivity`, would itself be dishonest in
    /// the other direction). A retry offer is appended ONLY when
    /// `retryability == .allowed`.
    static func groundedFailureText(understanding: ConversationUnderstanding) -> String {
        let base: String
        switch understanding.failureReason {
        case .known(_, let evidence) where Self.mentionsConnectivity(evidence):
            // Deliberately still generic ("that time," not "refused"/
            // "timed out"/any specific sub-cause) — the evidence text only
            // tells us the failure was CONNECTIVITY-flavored, not exactly
            // which connectivity failure occurred; naming a more specific
            // cause than the evidence actually supports would itself be
            // the fabrication P2-M5V7 §5/§6 exists to prevent.
            base = "I couldn't reach the service that time."
        case .known:
            base = "That didn't go through."
        case .unknown:
            // P2-M5V8.1-P §11 — more directly honest than a bare "That
            // didn't go through.": says plainly that the CAUSE isn't
            // known, rather than just declining to mention one. Reserved
            // for TRUE `.unknown` — see the `.known` case above.
            base = "I couldn't complete that, and I don't know why yet."
        }
        guard understanding.retryability == .allowed else { return base }
        return base + " Want me to try again?"
    }

    private static func mentionsConnectivity(_ evidence: String) -> Bool {
        let lower = evidence.lowercased()
        return lower.contains("connect") || lower.contains("service") || lower.contains("reach") || lower.contains("network") || lower.contains("unavailable")
    }
}

/// P2-M5V6 §6 / P2-M5V7 §8/§9 STAGE B interface/contract stub — NOT wired
/// to any real network provider this milestone, matching
/// `LLMConversationReasoner`'s own disclosed status. Always returns
/// `nil` — `ConversationalResponsePresenter`'s own safety net (§21)
/// handles `.conversational`/`.constraint` interaction modes correctly
/// regardless of what a configured `NaturalConversationRealizing`
/// returns, so this stub never needs to forward to deterministic logic
/// itself. A real future provider would replace this with actual
/// generated wording, still gated by the exact same `ResponseValidation`
/// this whole pipeline already applies.
public struct LLMNaturalResponseRealizer: NaturalConversationRealizing {
    public init() {}
    public func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
        nil
    }
}

/// Final Architectural Invariants §4 — "complete fallback chain: LLM
/// natural realizer → deterministic natural realizer." Mirrors
/// `FallbackConversationReasoning`/`FallbackSpeechSynthesizer`'s same
/// proven pattern: try `primary`, and if it returns `nil` ("nothing
/// safer/better to offer" — `NaturalConversationRealizing`'s own
/// documented `nil` contract), use `secondary`. `ConversationalResponsePresenter`
/// still applies its OWN further fallback beyond this (to the flat,
/// completely deterministic `DeterministicResponsePresenter`) whenever
/// BOTH of these return `nil` or the result fails validation — this
/// composite is the middle tier of that 3-tier chain, not the whole of
/// it.
public struct FallbackNaturalResponseRealizing: NaturalConversationRealizing {
    private let primary: NaturalConversationRealizing
    private let secondary: NaturalConversationRealizing

    public init(primary: NaturalConversationRealizing, secondary: NaturalConversationRealizing) {
        self.primary = primary
        self.secondary = secondary
    }

    public func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
        primary.realize(context: context, understanding: understanding, plan: plan, recentTurns: recentTurns, avoiding: avoiding)
            ?? secondary.realize(context: context, understanding: understanding, plan: plan, recentTurns: recentTurns, avoiding: avoiding)
    }
}
