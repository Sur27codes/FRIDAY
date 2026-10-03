import Foundation

/// A bounded, already-safe-to-speak piece of text (P2-M5 §4/§26/§27) plus
/// the minimal metadata diagnostics/tests need to tell success from
/// failure without re-parsing the text itself.
public struct SpokenResponse: Equatable, Sendable {
    public let text: String
    public let wasSuccess: Bool
    /// P2-M5V §10 — the bounded prosody intent this response should be
    /// spoken with (`VoiceProfile.adjusted(for:)`). Named `category` for
    /// full source compatibility with every pre-P2-M5V5 call site —
    /// `SpeechResponseCategory` is a type alias for `ProsodyIntent`.
    public let category: SpeechResponseCategory
    /// P2-M5V5 §11 — which real response family produced this text.
    public let responseFamily: ResponseFamily
    public let truthClassification: TruthClassification
    /// P2-M5V5 §11 — metadata only; see `FollowUpClassification`'s own
    /// doc comment for why this is never rendered into `text` itself.
    public let followUp: FollowUpClassification

    public init(
        text: String, wasSuccess: Bool, category: SpeechResponseCategory,
        responseFamily: ResponseFamily = .other, truthClassification: TruthClassification = .definitiveFailure,
        followUp: FollowUpClassification = .none
    ) {
        self.text = text
        self.wasSuccess = wasSuccess
        self.category = category
        self.responseFamily = responseFamily
        self.truthClassification = truthClassification
        self.followUp = followUp
    }
}

/// Maps one finished runtime interaction to safe spoken text (P2-M5 §3:
/// "Runtime result -> ResponsePresentation/ResponseFormatter ->
/// SpeechSynthesizer"). The only input is `CommandRuntimeOutcome` — an
/// already-terminal, `Sendable` result — never a raw payload, capability
/// record, or anything with execution authority. Producing a
/// `SpokenResponse` cannot invoke a capability, mutate policy, or submit
/// anything back through `CommandRuntimeSubmitting` (§3: "voice output
/// has ZERO execution authority") — there is no such method on this
/// protocol to call even if an implementation wanted to.
public protocol ResponsePresenting: Sendable {
    func response(for outcome: CommandRuntimeOutcome) -> SpokenResponse

    /// P2-PROD-BOOTSTRAP-R2 §2.2 — the transcript-aware entry point.
    /// `WakeCoordinator` has the validated command transcript in hand and
    /// now passes it here so a configured conversational brain
    /// (`ConversationalResponsePresenter`) can actually reason about what
    /// the user *said*, not only about the terminal runtime outcome.
    ///
    /// A default implementation forwards to `response(for:)` so every
    /// existing presenter (`DeterministicResponsePresenter`, every test
    /// fake) keeps working byte-for-byte unchanged — the deterministic
    /// path never needed the transcript and still doesn't.
    func response(for outcome: CommandRuntimeOutcome, transcript: String?) -> SpokenResponse
}

public extension ResponsePresenting {
    func response(for outcome: CommandRuntimeOutcome, transcript: String?) -> SpokenResponse {
        response(for: outcome)
    }
}

/// Production response presenter (§8/§9/§10/§11 of P2-M5; wording
/// refined at P2-M5V §6/§7/§8; deterministic response VARIATION added at
/// P2-M5V3 §8; wording tightened at P2-M5V4 §6; **re-architected at
/// P2-M5V5 §1 as the orchestrator of the new conversational pipeline**).
///
/// P2-M5V5 §1's required pipeline — `RuntimeTextResult` → `ConversationContextCompiler`
/// → `ResponseStrategyPlanner` → `FridayPersona` → `ResponseRealizer` →
/// `ResponseValidation` → prosody intent (consumed by `AdaptiveProsodyPlanner`
/// downstream) — is now real, not aspirational: `response(for:)`'s body
/// below calls each stage in order, as separate, independently-testable
/// types (§1: "do not put all behavior inside one giant presenter switch
/// statement"). This type itself is now the ORCHESTRATOR + the one place
/// bounded, deterministic repetition-control state lives (§15) — it is a
/// `final class`, not a `struct`, specifically for that small, lock-
/// protected history.
///
/// **Wording refinement — the reasoning, unchanged since P2-M5V, still
/// load-bearing:** Go's `response` package (`services/runtime/response/response.go`)
/// already produces safe, truthful, deterministic text for a fixed,
/// closed set of outcomes. What P2-M5V added, P2-M5V3 extended, and
/// P2-M5V5's `ResponseRealizer` now organizes into its own type, is a
/// curated set of REWORDINGS — most as single exact-match strings, a
/// growing number as small deterministically-selected VARIANT SETS —
/// that soften machine-sounding phrasing while preserving the exact same
/// truth value. The safety invariants are unchanged:
/// 1. Every match fires only against Go's own current, already-audited
///    templates, or a narrow, tested pattern for dynamic content.
/// 2. **Any text that doesn't match a known template falls back to
///    speaking Go's own original, already-safe text unchanged.**
/// 3. **Variant selection is a pure, deterministic function of
///    `RuntimeTextResult.taskID`** via a fixed FNV-1a hash — never real
///    randomness, never an LLM. P2-M5V5 §15 adds one more deterministic
///    layer on top: a bounded, per-instance "avoid the immediately-
///    previous DIFFERENT interaction's exact phrasing" rule, applied
///    only across genuinely distinct `taskID`s — a REPLAYED identical
///    `taskID` still always produces the exact same text (§8/§17's own
///    "never re-roll on replay" requirement, unbroken).
public final class DeterministicResponsePresenter: ResponsePresenting, @unchecked Sendable {
    /// §26: "keep spoken responses bounded — not a speech reader." Every
    /// real template in `response.go` today is well under 200 characters
    /// (the longest, `DuplicateRequestCompleted`'s failure branch, is
    /// ~90); the original 480 was generous headroom for that closed set
    /// while still refusing to ever read a whole note/file/JSON blob
    /// aloud if one somehow ended up in `text`.
    ///
    /// P2-M5V8.1-R §6 — REAL, forensically-proven root cause found via a
    /// real installed-app/real-provider run: 480 was sized around the
    /// deterministic `response.go` template set above, never around a
    /// genuine free-form explanatory answer — which P2-M5V8.1-Q already
    /// authorized general model knowledge to produce, and this pass's own
    /// classification fix now correctly routes to that path. A real,
    /// correct, substantive 5-sentence factual explanation (the mission's
    /// own acceptance phrase, "explain machine learning in five
    /// sentences") is naturally 500-800+ characters — comfortably over
    /// the old cap, so `ConversationModelSchema.realizedText(from:)`
    /// silently discarded the WHOLE, genuinely correct candidate,
    /// forcing a fallback to a short deterministic acknowledgment. Raised
    /// to 900 — still a real, meaningfully bounded ceiling (roughly
    /// double, not "unbounded" — a whole note/file/JSON blob is still
    /// rejected exactly as before), calibrated to comfortably fit a
    /// genuine multi-sentence explanation rather than only the old
    /// short-template set. `ResponseValidation`'s own truth/authority
    /// guards (`passesSemanticGuards` and everything it calls) are
    /// completely unchanged by this — this is a size ceiling, not a
    /// truth check.
    public static let maxSpokenLength = 900

    private let contextCompiler: ConversationContextCompiling
    private let strategyPlanner: ResponseStrategyPlanning
    private let realizer: ResponseRealizing
    private let persona: FridayPersona

    /// P2-M5V5 §15 repetition-control state — bounded to the single
    /// most recent GENUINELY DISTINCT interaction (never grows
    /// unbounded, never persisted, reset every process launch).
    private let lock = NSLock()
    private var lastTaskID: String?
    private var lastFamily: ResponseFamily?
    private var lastText: String?
    private var recentFamilies: [ResponseFamily] = []

    public init(
        contextCompiler: ConversationContextCompiling = DeterministicConversationContextCompiler(),
        strategyPlanner: ResponseStrategyPlanning = DeterministicResponseStrategyPlanner(),
        realizer: ResponseRealizing = DeterministicResponseRealizer(),
        persona: FridayPersona = .friday
    ) {
        self.contextCompiler = contextCompiler
        self.strategyPlanner = strategyPlanner
        self.realizer = realizer
        self.persona = persona
    }

    public func response(for outcome: CommandRuntimeOutcome) -> SpokenResponse {
        let history = snapshotRecentFamilies()
        let context = contextCompiler.compile(outcome: outcome, recentResponseFamilies: history)
        let strategy = strategyPlanner.strategy(for: context, persona: persona)

        let avoiding = avoidingText(for: context)
        let draft = realizer.realize(context: context, strategy: strategy, avoiding: avoiding)
        let fallback = context.wasSuccess ? "Done." : "I couldn't complete that request."
        let text = ResponseValidation.sanitize(draft, fallback: fallback)

        // §17: "friendliness must never change authority" / §11: "a
        // failed runtime result must NEVER map to success speech" — a
        // hard, defensive re-check AFTER realization, not just a hope
        // that every phrase bank was audited correctly. If this ever
        // somehow fired, it means a phrase-bank bug slipped through
        // every other test — the safe fallback below is truthful
        // either way.
        let safeText = ResponseValidation.neverClaimsSuccessForFailure(text, wasSuccess: context.wasSuccess)
            ? text : fallback

        recordInteraction(context: context, text: safeText)

        let truth = TruthClassification.classify(wasSuccess: context.wasSuccess, family: context.responseFamily)

        return SpokenResponse(
            text: safeText, wasSuccess: context.wasSuccess, category: strategy.prosodyIntent,
            responseFamily: context.responseFamily, truthClassification: truth, followUp: .none
        )
    }

    // MARK: - P2-M5V5 §15: repetition control (bounded, deterministic, never persisted)

    private func snapshotRecentFamilies() -> [ResponseFamily] {
        lock.lock(); defer { lock.unlock() }
        return recentFamilies
    }

    private func avoidingText(for context: ConversationContext) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard context.taskID != lastTaskID, context.responseFamily == lastFamily else { return nil }
        return lastText
    }

    private func recordInteraction(context: ConversationContext, text: String) {
        lock.lock(); defer { lock.unlock() }
        guard context.taskID != lastTaskID else { return } // a replayed identical taskID must not perturb history
        lastTaskID = context.taskID
        lastFamily = context.responseFamily
        lastText = text
        recentFamilies.append(context.responseFamily)
        if recentFamilies.count > 3 { recentFamilies.removeFirst(recentFamilies.count - 3) }
    }

    // MARK: - Backward-compatible static forwarding (pre-P2-M5V5 surface)
    //
    // Every member below existed directly on this type before P2-M5V5's
    // re-architecture moved the real phrase-bank/matching logic into
    // `DeterministicResponseRealizer` and the classification logic into
    // `DeterministicConversationContextCompiler`/`DeterministicResponseStrategyPlanner`
    // (§1: "do not put all behavior inside one giant presenter switch
    // statement"). These forwarders exist SOLELY so every pre-P2-M5V5
    // test/call site keeps compiling and behaving the same — none of
    // them are called by `response(for:)` above, which goes through the
    // real pipeline directly.

    public static var getStatusSuccessVariants: [String] { DeterministicResponseRealizer.getStatusSuccessVariants }
    public static func createNoteSuccessVariants(title: String) -> [String] { DeterministicResponseRealizer.createNoteSuccessVariants(title: title) }
    public static var unsupportedIntentVariants: [String] { DeterministicResponseRealizer.unsupportedIntentVariants }
    public static func stableHash(_ s: String) -> UInt64 { DeterministicResponseRealizer.stableHash(s) }
    public static func sanitize(_ raw: String, fallback: String) -> String { ResponseValidation.sanitize(raw, fallback: fallback) }

    /// Legacy prosody classification, reconstructed as a thin composition
    /// of the new pipeline's own classification stages so this cannot
    /// silently drift from what `response(for:)` actually does. Two
    /// mappings are now intentionally MORE SPECIFIC than before this
    /// milestone (see call-site comments in `ResponsePresentingTests`):
    /// AMBIGUOUS_INTENT now reads `.friendly` (§14: "CLARIFICATION ->
    /// friendly/neutral") rather than the old flat `.information`, and
    /// the three genuinely-retryable failure codes now read
    /// `.reassuring` (§13/§14) rather than the old flat `.failure`.
    public static func category(forOutcomeCode outcomeCode: String, rawText: String) -> SpeechResponseCategory {
        let family = DeterministicConversationContextCompiler.classifyFamily(outcomeCode: outcomeCode, rawText: rawText)
        let context = ConversationContext(
            interactionID: "legacy-classification", taskID: "legacy-classification", outcomeCode: outcomeCode,
            responseFamily: family, wasSuccess: outcomeCode == "SUCCESS", isVerifiedData: outcomeCode == "SUCCESS",
            needsClarification: family == .ambiguousIntent, isRetryable: DeterministicConversationContextCompiler.isRetryable(family),
            isFollowUpMeaningful: false
        )
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        return strategy.prosodyIntent
    }

    /// Legacy text-only (no outcome code) rewording lookup — reconstructed
    /// directly against `DeterministicResponseRealizer`'s own matching
    /// helpers so the same "which known Go shape is this text" logic is
    /// never duplicated. Returns `nil` for anything unrecognized, exactly
    /// as before (§8's own safety property: unknown text always relays
    /// verbatim, never silently disappears).
    public static func warmedText(for text: String, taskID: String) -> String? {
        if text == "System status retrieved successfully." {
            return DeterministicResponseRealizer.pick(DeterministicResponseRealizer.getStatusSuccessVariants, taskID: taskID)
        }
        if let title = DeterministicResponseRealizer.extractCreateNoteTitle(from: text) {
            return DeterministicResponseRealizer.pick(DeterministicResponseRealizer.createNoteSuccessVariants(title: title), taskID: taskID)
        }
        if let field = DeterministicResponseRealizer.extractAmbiguousMissingField(from: text) {
            return "I need a bit more information to do that (missing: \(field))."
        }
        return nil
    }
}

/// P2-M5V5 §11 — the validation stage of the pipeline. Deliberately thin
/// — it reuses the exact same `sanitize` logic this presenter has always
/// used (moved here so the pipeline has a real, separately-named
/// validation step, per §1's required architecture), plus one new,
/// explicit truth-preserving check.
public enum ResponseValidation {
    /// P2-M5V8.1-S2.2 §2 — normalizes ONLY typographic variance (curly
    /// vs. straight apostrophes, every common dash variant vs. a plain
    /// hyphen, non-breaking space, repeated whitespace, case) — NEVER
    /// changes which WORDS are present, so no guard's actual semantic
    /// coverage changes, only its robustness to how a real model happens
    /// to typeset the same words. Applied ONCE, centrally, in
    /// `claimMatches` below — every phrase-matching guard in this file
    /// routes through that one function instead of comparing against raw
    /// `text` directly, so this fix benefits all of them identically.
    /// Real, live-observed failure this closes: "I've corrected the
    /// note." (a genuine U+2019 typographic apostrophe, as any real
    /// model's default output uses) silently failed to match a phrase
    /// table written with a straight ASCII apostrophe (U+0027), so the
    /// referential guard never even saw a reason to reject it.
    private static func normalizedForClaimMatching(_ text: String) -> String {
        var result = text.lowercased()
        for quote in ["\u{2018}", "\u{2019}", "\u{201B}", "\u{FF07}", "\u{02BC}", "`"] {
            result = result.replacingOccurrences(of: quote, with: "'")
        }
        for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}"] {
            result = result.replacingOccurrences(of: dash, with: "-")
        }
        result = result.replacingOccurrences(of: "\u{00A0}", with: " ")
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The one substring-match primitive every phrase-based guard in this
    /// file uses — normalizes BOTH sides identically (a phrase table
    /// written with a straight apostrophe still matches a candidate using
    /// a curly one, and vice versa).
    private static func claimMatches(_ text: String, _ phrase: String) -> Bool {
        normalizedForClaimMatching(text).contains(normalizedForClaimMatching(phrase))
    }

    /// §27: validate spoken strings — Unicode, empty, whitespace, control
    /// characters, oversize. Any control/format/line-or-paragraph-separator
    /// scalar becomes a plain space (so a stray newline or control byte in
    /// some future template can't be read as a pause or crash a
    /// synthesizer that assumes single-line input), runs of whitespace
    /// collapse to one space, then the result is bounded in length, then
    /// a safe fallback is used if nothing usable remains.
    public static func sanitize(_ raw: String, fallback: String) -> String {
        var scrubbed = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                scrubbed.append(" ")
            default:
                scrubbed.append(scalar)
            }
        }
        let collapsed = String(scrubbed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.count > DeterministicResponsePresenter.maxSpokenLength ? String(trimmed.prefix(DeterministicResponsePresenter.maxSpokenLength)) : trimmed
    }

    /// §11/§17: "a failed runtime result must NEVER map to success
    /// speech," "friendly presentation and execution authority remain
    /// separate." Returns `true` if `text` is safe to speak for the
    /// given truth value.
    public static func neverClaimsSuccessForFailure(_ text: String, wasSuccess: Bool) -> Bool {
        guard !wasSuccess else { return true }
        // "Done"/"Completed"/"Success" are allowed to appear as part of
        // a truthful NEGATIVE statement (e.g. "...did not succeed" or
        // the deliberate CANCELLED exception documented in
        // `ResponsePresentingTests`), so this checks for the bare,
        // affirmative-sounding words specifically, matching every
        // existing regression test's own exact list.
        let forbidden = ["Done.", "Completed.", "Success."]
        return !forbidden.contains { claimMatches(text, $0) }
    }

    // MARK: - P2-M5V7 §21: Response Validation 2.0 — semantic guards beyond plain success/failure

    /// §3: "notRequested -> NEVER say 'Done', 'Completed', 'It's ready',
    /// or equivalent action completion" — enforced regardless of what any
    /// accompanying runtime outcome claims, since `ActionExecutionState.notRequested`
    /// means the user's utterance never asked FRIDAY to do anything in
    /// the first place.
    /// - Parameter responseScope: P2-M5V8.1-R §6 — REAL, forensically-
    ///   proven fix, default `.conversationalShort` (preserves every
    ///   pre-existing call site's exact behavior). "Done"/"Completed"/
    ///   bare "is ready" are plain SUBSTRING matches (`claimMatches`, not
    ///   a whole-word check) — real evidence found them false-positive
    ///   rejecting ordinary third-person educational content ("training
    ///   is completed") for the SAME reason `executionSuccessClaimGuard`'s
    ///   own sibling bare checks did (see that function's own doc
    ///   comment for the full explanation, reused verbatim here).
    ///   "It's ready"/every first-person phrase remain unconditionally
    ///   blocked regardless of scope — genuine claims either way.
    public static func neverClaimsActionForNotRequested(_ text: String, actionExecutionState: ActionExecutionState, responseScope: ResponseScope = .conversationalShort) -> Bool {
        guard actionExecutionState == .notRequested else { return true }
        let alwaysForbidden = ["It's ready", "I changed", "I've changed", "I created", "I've created", "I deleted", "I've deleted", "I updated", "I've updated"]
        if alwaysForbidden.contains(where: { claimMatches(text, $0) }) { return false }
        guard responseScope != .briefExplanation, responseScope != .longFormRequested else { return true }
        let scopeGatedForbidden = ["Done", "Completed", "is ready"]
        return !scopeGatedForbidden.contains { claimMatches(text, $0) }
    }

    /// P2-M5V8.1-P.1A §2/§3/§10/§17 — the CLOSED-COVERAGE completion-claim
    /// guard: combines `ExecutionClaimDetector`'s bounded, verb-family-
    /// generalizing local classification (never itself authoritative —
    /// see that type's own doc comment) with the SAME authoritative
    /// `ActionExecutionState` every sibling guard already reads, so a
    /// candidate that phrases a fabricated completion with an uncovered
    /// verb (§1A's own disclosed live gap: "I added a line," which none
    /// of the phrase-list guards above recognized) is caught exactly the
    /// same way "Done"/"I created" already were. ADDITIVE ONLY — every
    /// guard above and below still runs unchanged; this closes a gap,
    /// it replaces nothing (§17: "preserve... exactly as existing fail-
    /// closed behavior works"). Per §10's action-state matrix: a
    /// completion claim may pass ONLY when authority already says the
    /// action genuinely succeeded.
    /// - Parameter responseScope: P2-M5V8.1-R §6 — threaded straight
    ///   through to `ExecutionClaimDetector.claimsExecutionOrMutation`'s
    ///   own `allowAmbiguousResultStateSubject` (see its doc comment);
    ///   default `.conversationalShort` preserves every pre-existing call
    ///   site's exact behavior.
    public static func neverClaimsExecutionBeyondAuthority(_ text: String, actionExecutionState: ActionExecutionState, responseScope: ResponseScope = .conversationalShort) -> Bool {
        guard actionExecutionState != .executedSucceeded else { return true }
        // P2-M5V8.1-R §6 — REAL regression caught by this pass's own full
        // suite run: `.briefExplanation` is ALSO reached for a genuinely
        // FAILED/DENIED action's explanation (`responseScope(...)`'s own
        // `actionExecutionState == .executedFailed || .denied` case), not
        // only for a `.notRequested` general-knowledge turn — a bare
        // "ordered"/"written"-shaped ambiguous-subject claim remains
        // entirely plausible and dangerous there too ("Update my
        // calendar" → a hallucinated fabricated completion after a real
        // `EXECUTION_FAILED`). Gated on `actionExecutionState ==
        // .notRequested` specifically, mirroring `executionSuccessClaimGuard`'s
        // own identical fix.
        let allowAmbiguousResultStateSubject = actionExecutionState == .notRequested && (responseScope == .briefExplanation || responseScope == .longFormRequested)
        return !ExecutionClaimDetector.claimsExecutionOrMutation(text, allowAmbiguousResultStateSubject: allowAmbiguousResultStateSubject)
    }

    /// §6: "Only say 'Want me to try again?' if Retryability == allowed."
    /// - Parameters actionExecutionState/responseScope: P2-M5V8.1-R §6 —
    ///   REAL, forensically-proven fix, defaulting to `.unknown`/
    ///   `.conversationalShort` so every pre-existing call site keeps
    ///   compiling and behaving unchanged. When `actionExecutionState ==
    ///   .notRequested` (no action was EVER attempted, so there is
    ///   nothing FRIDAY could plausibly be offering to retry) AND
    ///   `responseScope` is `.briefExplanation`/`.longFormRequested`
    ///   (genuine informational content), ordinary "try again" advice
    ///   about the TOPIC itself ("HTTP 503... it may work if you try
    ///   again later" — real evidence) is no longer confused with FRIDAY
    ///   offering to retry an action. Every OTHER `actionExecutionState`
    ///   (where a genuine retry OFFER remains entirely plausible) keeps
    ///   this guard exactly as before, unconditionally.
    public static func neverOffersRetryUnlessAllowed(_ text: String, retryability: Retryability, actionExecutionState: ActionExecutionState = .unknown, responseScope: ResponseScope = .conversationalShort) -> Bool {
        guard retryability != .allowed else { return true }
        if actionExecutionState == .notRequested, responseScope == .briefExplanation || responseScope == .longFormRequested { return true }
        return !claimMatches(text, "try again") && !claimMatches(text, "retry")
    }

    /// §5, broadened by P2-M5V8.1-S §15/§19 — never claim a specific
    /// failure cause unless `FailureReason` actually grounds it. Fixes
    /// TWO real bugs: the original ("I couldn't reach it that time"
    /// invented connectivity for a generic `EXECUTION_FAILED`), and a
    /// LIVE model failure this pass found ("...something went wrong
    /// internally" — "internally" is an ungrounded causal/location claim
    /// the original narrow phrase list never covered). §19's second half
    /// ("if FailureReason == known(type,evidence), candidate cause must
    /// be COMPATIBLE with that type/evidence — not just any cause is fine
    /// merely because SOME cause is known") is enforced via `evidenceSupports`.
    /// - Parameter actionExecutionState: defaults to `.executedFailed` so
    ///   every pre-existing 2-argument call site (including this file's
    ///   own tests) keeps testing exactly what it always tested — "this
    ///   IS a genuine execution failure needing cause-grounding." The
    ///   guard only APPLIES for `.executedFailed`: `.unsupported`/`.denied`
    ///   also carry `FailureReason.unknown` under this codebase's own
    ///   derivation (`DeterministicConversationReasoner.failureReason`
    ///   only ever produces `.known`/non-`.unknown` for `.executedFailed`),
    ///   but "that capability isn't available" / "you don't have
    ///   permission" are TRUTHFUL, appropriate wording for those states,
    ///   not an invented failure cause — a real scoping gap this pass
    ///   found and fixed while broadening the phrase list (§15/§19).
    public static func neverInventsFailureCause(_ text: String, failureReason: FailureReason, actionExecutionState: ActionExecutionState = .executedFailed) -> Bool {
        guard actionExecutionState == .executedFailed else { return true }
        // Keyword ROOTS, not fixed multi-word phrases — generalizes to
        // paraphrases a real model can produce ("the network failed,"
        // "network's down," "a network problem") without needing one
        // exact string per phrasing (§15: "vary wording").
        let ungroundedCausePhrases = [
            "couldn't reach", "could not reach", "connection", "network",
            "internally", "internal",
            "server", "permission issue", "configuration problem", "configuration issue",
            "capability unavailable", "capability isn't available", "capability is not available",
            "timed out", "timeout", "authentication", "credentials",
            // P2-M5V8.1-S2 §20 — a real live failure: "refused the
            // connection" was accepted when the actual evidence only said
            // "service unreachable." "refused"/"rejected" is its OWN,
            // separately-checked entry (see `evidenceSupports`) because it
            // claims something MORE SPECIFIC than plain connectivity
            // failure — an ACTIVE rejection (e.g. the far end was reached
            // and refused), which is incompatible with, not just a
            // detail of, a generic "unreachable" cause. "Do not infer a
            // subtype from a broader failure reason."
            "refused", "rejected the connection",
        ]
        switch failureReason {
        case .unknown:
            return !ungroundedCausePhrases.contains { claimMatches(text, $0) }
        case .known(_, let evidence):
            let lowerEvidence = normalizedForClaimMatching(evidence)
            for phrase in ungroundedCausePhrases where claimMatches(text, phrase) {
                guard Self.evidenceSupports(phrase: phrase, evidence: lowerEvidence) else { return false }
            }
            return true
        }
    }

    private static let connectivityCausePhrases: Set<String> = [
        "couldn't reach", "could not reach", "connection", "network",
    ]

    /// A candidate may only use one of `neverInventsFailureCause`'s
    /// ungrounded-cause phrases if the underlying evidence text ITSELF
    /// supports that specific category — never inferred, never "close
    /// enough."
    private static func evidenceSupports(phrase: String, evidence: String) -> Bool {
        // §20 — "refused"/"rejected the connection" claims an ACTIVE
        // rejection, a materially different (not merely more detailed)
        // failure mode than plain "unreachable"/"couldn't connect" —
        // requires the evidence to say so explicitly; a broader
        // connectivity phrase never licenses this specific one.
        if phrase == "refused" || phrase == "rejected the connection" {
            return evidence.contains("refused") || evidence.contains("rejected")
        }
        if connectivityCausePhrases.contains(phrase) {
            return evidence.contains("connect") || evidence.contains("network") || evidence.contains("reach") || evidence.contains("service") || evidence.contains("unavailable")
        }
        return evidence.contains(phrase)
    }

    /// P2-M5V8.1-S §18 — broader than `neverClaimsActionForNotRequested`
    /// (which only guards `.notRequested`): applies whenever
    /// `actionExecutionState` is ANYTHING other than `.executedSucceeded`
    /// (denied/unsupported/executedFailed/requestedNotStarted/unknown/notRequested),
    /// against a wider, still-bounded family of completion-claiming
    /// phrases a real model can phrase many ways ("all set," "taken care
    /// of," "went through," "I sent it," "I deleted it").
    /// - Parameter responseScope: P2-M5V8.1-R §6 — REAL, forensically-
    ///   proven fix. Default `.conversationalShort` preserves every
    ///   pre-existing call site's exact behavior (including every test
    ///   above that constructs this guard directly). Real evidence (a
    ///   genuine, correct, real-provider 5-sentence machine-learning
    ///   explanation) found the bare, CONTEXT-FREE "is ready"/"done"/
    ///   "completed" checks below — unlike every phrase directly above
    ///   them, none of which require a first-person/pronoun subject —
    ///   false-positive rejecting ordinary third-person educational
    ///   content ("Once training is completed, the model can make
    ///   predictions") that never claims FRIDAY itself did anything.
    ///   `.briefExplanation`/`.longFormRequested` are ALSO reached for a
    ///   genuinely FAILED/DENIED action's explanation (`responseScope(...)`'s
    ///   own `actionExecutionState == .executedFailed || .denied` case) —
    ///   real evidence (a pre-existing test this pass's own first attempt
    ///   at this fix broke) proved a bare completion claim remains
    ///   entirely plausible AND dangerous there ("Update my calendar" →
    ///   a hallucinated "Done — that's fixed now." after a genuine
    ///   `EXECUTION_FAILED`). So the carve-out below is gated on BOTH
    ///   `responseScope` AND `actionExecutionState == .notRequested`
    ///   specifically — the ONLY combination where `responseScope(...)`
    ///   can reach `.briefExplanation`/`.longFormRequested` with no
    ///   action ever having been requested at all (see
    ///   `responseScope(...)`'s own `.explanationRequest`/
    ///   `capabilityRequirement == .notRequired` gating), so the system
    ///   prompt never asks the model to report on FRIDAY completing
    ///   anything and a plausible genuine bare completion claim cannot
    ///   occur there in the first place — every OTHER combination (where
    ///   one remains entirely plausible) keeps both checks exactly as
    ///   before, unchanged. The unambiguous, subject-anchored phrases
    ///   right below (first-person "I completed"/"I'm done," or pronoun-
    ///   anchored "it's ready"/"that's ready") stay blocked regardless of
    ///   scope OR actionExecutionState — genuine claims, never
    ///   legitimately produced by third-person informational content
    ///   either way.
    public static func executionSuccessClaimGuard(_ text: String, actionExecutionState: ActionExecutionState, responseScope: ResponseScope = .conversationalShort) -> Bool {
        guard actionExecutionState != .executedSucceeded else { return true }
        // Multi-word phrases are safe with plain substring matching
        // (negligible accidental-collision risk); single bare words
        // ("done," "completed") are checked as WHOLE WORDS instead, so a
        // word that merely CONTAINS one as a substring ("abandoned"
        // contains "done") can never false-positive.
        let completionClaimPhrases = [
            "all set", "taken care of", "went through", "it's ready", "that's ready",
            "i created", "i've created", "i sent", "i've sent", "i deleted", "i've deleted", "i updated", "i've updated",
            // §3 — the SAME family for a correction/transformation claim
            // (distinct from the referential guard below, which is
            // scoped to dialogueAct==.correction specifically; this one
            // applies whenever actionExecutionState itself isn't
            // executedSucceeded, regardless of dialogueAct).
            "i corrected", "i've corrected", "i fixed", "i've fixed", "i changed", "i've changed",
            // P2-M5V8.1-R §6 — a real, PRE-EXISTING gap this pass's own
            // investigation found (unrelated to the scope-gating below):
            // "completed"/"done" as a first-person VERB was previously
            // caught ONLY by the scope-blind bare whole-word check —
            // meaning narrowing that check below for `.briefExplanation`
            // would otherwise have silently unprotected this exact claim
            // shape too. Closed explicitly, unconditionally, regardless
            // of scope, exactly like every sibling phrase above.
            "i completed", "i've completed", "i'm done", "i am done",
        ]
        if completionClaimPhrases.contains(where: { claimMatches(text, $0) }) { return false }
        let scopeCarveOutApplies = actionExecutionState == .notRequested && (responseScope == .briefExplanation || responseScope == .longFormRequested)
        guard !scopeCarveOutApplies else { return true }
        if claimMatches(text, "is ready") { return false }
        let wholeWordTriggers: Set<String> = ["done", "completed"]
        let words = normalizedForClaimMatching(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return !words.contains { wholeWordTriggers.contains($0) }
    }

    /// P2-M5V8.1-S §20 — widens `neverOffersRetryUnlessAllowed`'s phrase
    /// coverage; same semantics (`Retryability == allowed` required),
    /// more of the ways a real model phrases a retry offer.
    /// - Parameters actionExecutionState/responseScope: P2-M5V8.1-R §6 —
    ///   same carve-out as `neverOffersRetryUnlessAllowed` (see its own
    ///   doc comment); defaults preserve every pre-existing call site.
    public static func neverOffersRetryClaimUnlessAllowed(_ text: String, retryability: Retryability, actionExecutionState: ActionExecutionState = .unknown, responseScope: ResponseScope = .conversationalShort) -> Bool {
        guard retryability != .allowed else { return true }
        if actionExecutionState == .notRequested, responseScope == .briefExplanation || responseScope == .longFormRequested { return true }
        let retryPhrases = ["try again", "retry", "rerun", "run it again", "repeat", "want me to try", "should i try"]
        return !retryPhrases.contains { claimMatches(text, $0) }
    }

    /// P2-M5V8.1-S §21 — "do not confuse policy denial, missing approval,
    /// capability unsupported, provider failure, execution failure."
    /// Generated wording must stay compatible with the ACTUAL local
    /// reason: a policy denial must never be phrased as "I don't know
    /// how to do that" (implies unsupported), and an unsupported
    /// capability must never be phrased as a permission/approval denial.
    public static func permissionClaimGuard(_ text: String, actionExecutionState: ActionExecutionState) -> Bool {
        let unsupportedPhrases = ["not something i can do", "not something i'm able to do", "don't know how to do that", "can't do that yet", "not in my skill set", "not able to help with that"]
        let deniedPhrases = ["don't have permission", "not authorized", "need approval", "authorization was denied", "permission was denied"]
        switch actionExecutionState {
        case .denied:
            return !unsupportedPhrases.contains { claimMatches(text, $0) }
        case .unsupported:
            return !deniedPhrases.contains { claimMatches(text, $0) }
        default:
            return true
        }
    }

    /// P2-M5V8.1-S §22 — FRIDAY has no verified visual-presence sensor in
    /// this voice-only pipeline; generated text must never imply one
    /// ("Hey, good to see you." — a real live-model output this pass
    /// found). Deliberately narrow and idiom-aware: ordinary farewell
    /// idioms ("see you soon," "see you later," "talk to you later") are
    /// NOT flagged (§22: "do not over-literalize ordinary idioms
    /// unnecessarily") — only phrasings that assert or compliment a
    /// CURRENT visual observation are rejected.
    public static func neverImpliesUnverifiedSensing(_ text: String) -> Bool {
        let sensorClaimPhrases = ["good to see you", "nice to see you", "great to see you", "i can see you", "i can see that", "i saw you", "you look", "looking good today"]
        return !sensorClaimPhrases.contains { claimMatches(text, $0) }
    }

    /// P2-M5V8.1-S2 §15/§16 — the previously-disclosed missing hard guard:
    /// a correction utterance does not itself prove any transformation
    /// occurred, and when the user explicitly points BACKWARD
    /// ("the earlier one," "the one before that" — `correctionTarget ==
    /// "earlier"`), a candidate claiming a NEW/current/just-corrected
    /// target directly CONTRADICTS what the user said. Real live-model
    /// failure this fixes: "No, the earlier one." → "I've corrected the
    /// note."/"Your new note is ready." — both wrong regardless of
    /// `actionExecutionState`, since `.correction` interactionMode
    /// legitimately allows `.executedSucceeded` for genuine renames, so
    /// `executionSuccessClaimGuard` alone can't catch this — this guard
    /// is scoped specifically to dialogueAct==.correction with a resolved
    /// "earlier" direction, independent of actionExecutionState.
    /// P2-M5V8.1-S2.2 §1/§3/§4 hardening — the real live-model regression
    /// this pass fixes: "No, the earlier one." → "I've corrected the
    /// note." was ACCEPTED. Root-caused to TWO independent bugs, both
    /// fixed at the source (not here): (1) `correctionTarget`'s
    /// computation was gated on a prior `.createNoteSuccess` turn
    /// existing, so it stayed `nil` — and therefore never matched this
    /// guard's `== "earlier"` check — for any correction NOT about a
    /// note (`DeterministicConversationReasoner.understand`'s own fix);
    /// (2) `ConversationalResponsePresenter.authoritative` used to prefer
    /// the REASONER's (possibly model-supplied) `correctionTarget` over
    /// the LOCAL one, so even a correctly-resolved local "earlier" could
    /// be silently overwritten by an unrelated model-supplied string.
    /// This function itself was never the bug, but §4 still requires the
    /// two dimensions it checks be genuinely SEPARATE, documented
    /// concerns, not one conflated rule:
    ///
    /// A. REFERENCE COMPATIBILITY — is this even a correction pointing
    ///    BACKWARD (`correctionTarget == "earlier"`)? If not, this guard
    ///    has nothing to say (a forward/new claim might be entirely
    ///    legitimate elsewhere).
    /// B. EXECUTION/COMPLETION COMPATIBILITY — GIVEN backward reference,
    ///    does the candidate ALSO claim a transformation occurred
    ///    ("I've corrected"/"new note"/etc.)? A correction utterance does
    ///    NOT by itself prove any transformation happened (§3), so this
    ///    is rejected regardless of `actionExecutionState` (a genuine
    ///    rename can legitimately reach `.executedSucceeded`, which is
    ///    exactly why `executionSuccessClaimGuard` alone can't catch this).
    public static func referentialCorrectionClaimGuard(_ text: String, dialogueAct: DialogueAct, correctionTarget: String?) -> Bool {
        // A. Reference compatibility.
        guard dialogueAct == .correction, correctionTarget == "earlier" else { return true }
        // B. Execution/completion compatibility. Covers both active
        // first-person phrasing ("I've updated it") and passive phrasing
        // ("That version has been changed.") — a real model uses either
        // construction for the identical claim, and both are equally
        // unsupported absent a verified transformation.
        let fabricatedForwardClaims = [
            "i corrected", "i've corrected", "i updated", "i've updated", "i fixed", "i've fixed",
            "i changed", "i've changed", "i rewrote", "i've rewrote", "i saved", "i've saved",
            "i replaced", "i've replaced", "i modified", "i've modified",
            "has been corrected", "has been updated", "has been fixed", "has been changed",
            "has been rewritten", "has been saved", "has been replaced", "has been modified",
            "new note", "new one", "current note", "current one",
        ]
        return !fabricatedForwardClaims.contains { claimMatches(text, $0) }
    }

    /// P2-M5V8.1-P.2-FINAL-CLOSURE §10/§11/§12 — ADDITIVE sibling of
    /// `referentialCorrectionClaimGuard` above (that guard's own scope is
    /// deliberately narrow — `correctionTarget == "earlier"` only; this
    /// closes the SEPARATE gap it never covered: `correctionTarget ==
    /// "ambiguous"`, a GENERIC referent — "the other one," "that one" —
    /// that names no specific target at all). A confident-sounding
    /// acknowledgement ("Right—the other one." / "Got it." / "Done.")
    /// pretends resolution the wording never actually supports; only a
    /// genuine CLARIFYING QUESTION may be spoken instead. Never verifies
    /// the referent actually exists in memory (this codebase has no
    /// deeper artifact-history lookup to check against) — only that the
    /// candidate's OWN text asks rather than guesses, the same "local
    /// evidence, never trust the model to self-police" discipline every
    /// other guard in this file already follows.
    public static func referentialAmbiguityRequiresClarification(_ text: String, dialogueAct: DialogueAct, correctionTarget: String?) -> Bool {
        guard dialogueAct == .correction, correctionTarget == "ambiguous" else { return true }
        return text.contains("?")
    }

    /// P2-M5V8.1-S2.2 §5/§6/§7 — the user's OWN current-turn words
    /// asserted a NEGATIVE situational state ("production is down"); a
    /// candidate directly asserting the OPPOSITE (an "all clear" claim)
    /// is REJECTED, since this codebase has no verified-runtime source
    /// that could ever supersede it (§6: "the user report is NOT
    /// equivalent to verified world truth, but FRIDAY must not directly
    /// contradict it without contradictory verified evidence" — no such
    /// evidence exists here, so the contradiction is never permitted).
    /// Deliberately narrow: only a same-turn "everything is FINE"-style
    /// claim is rejected — a neutral acknowledgement ("Got it.") or an
    /// investigation offer ("Want me to check it?") are NOT all-clear
    /// claims and pass freely.
    public static func userReportedStateContradictionGuard(_ text: String, userReportedState: UserReportedState?) -> Bool {
        guard let userReportedState, userReportedState.polarity == .negative else { return true }
        let allClearClaimPhrases = [
            "all good", "everything's fine", "everything is fine", "everything's in order", "everything is in order",
            "working normally", "nothing is wrong", "nothing wrong", "all clear", "back up", "back online",
            "up and running", "resolved", "fixed now", "no issues",
        ]
        return !allClearClaimPhrases.contains { claimMatches(text, $0) }
    }

    /// P2-M5V8.1-S3.1 §4 — a property of the GENERATED CANDIDATE TEXT
    /// itself: does its WORDING positively evaluate a just-reported
    /// situation, negatively evaluate it, or neither? Deliberately NOT an
    /// emotion detector (§19) — it never infers anything about the
    /// user's private state, only classifies what FRIDAY's OWN wording
    /// says about the event.
    public enum CandidateReactionValence: Sendable, Equatable {
        case positiveAboutSituation
        case negativeAboutSituation
        case neutral
    }

    /// P2-M5V8.1-S3.1 §6/§7 — bounded, compositional classification: a
    /// small set of REUSABLE FRAGMENTS (never a full-sentence lookup, so
    /// "That's great to hear!"/"Oh, great to hear." both match the same
    /// "great to hear" fragment) grouped into the three families §7 asks
    /// for (event-target structures, resolution semantics, and the §6
    /// disclosure-appreciation exception, checked FIRST so it can never
    /// be shadowed by the broader positive-reaction fragments below).
    /// Real live failure this exists to catch: "Production is down now."
    /// → "That's good to hear." — a POSITIVE EVALUATION of a NEGATIVE
    /// event, a claim class `userReportedStateContradictionGuard`'s own
    /// "all clear"-style STATE-ASSERTION phrase table was never scoped to
    /// cover (§12: "related but not identical claim classes").
    static func candidateReactionValence(_ text: String) -> CandidateReactionValence {
        // §6 — appreciating the DISCLOSURE ("thanks for telling me") is
        // never a positive evaluation of the situation itself.
        let disclosureAppreciationPhrases = [
            "glad you told me", "glad you let me know", "thanks for telling me", "thank you for telling me",
            "good that you told me", "appreciate you telling me", "thanks for letting me know", "thank you for letting me know",
        ]
        if disclosureAppreciationPhrases.contains(where: { claimMatches(text, $0) }) { return .neutral }
        // §7 event-target structures — a positive adjective attached to
        // the EVENT/NEWS itself ("that's <positive>," "<positive> to
        // hear," "<positive> news," "sounds/looks <positive>") rather
        // than to the act of reporting it.
        let eventTargetPhrases = [
            "that's good", "that is good", "that's great", "that is great", "that's nice", "that is nice",
            "that's excellent", "that is excellent", "that's wonderful", "that is wonderful", "that's awesome", "that is awesome",
            "good to hear", "glad to hear", "great to hear", "nice to hear",
            "good news", "great news", "sounds good", "looks good", "that sounds good", "that looks good",
        ]
        // §7 resolution semantics — a claim the reported situation is
        // ALREADY resolved/back to normal (positive by implication, even
        // without an explicit "good"/"great").
        let resolutionPhrases = [
            "sorted", "fixed", "resolved", "back up", "back online", "back to normal",
            "working normally", "working now", "in order", "all clear", "up and running",
        ]
        if eventTargetPhrases.contains(where: { claimMatches(text, $0) }) { return .positiveAboutSituation }
        if resolutionPhrases.contains(where: { claimMatches(text, $0) }) { return .positiveAboutSituation }
        return .neutral
    }

    /// P2-M5V8.1-S3.1 §5/§11 — a NARROWLY SCOPED, SEPARATE guard from
    /// `userReportedStateContradictionGuard` above (§12: "extend the
    /// semantic coverage, do not replace that guard" — the two remain
    /// independently documented, both required in `passesSemanticGuards`'s
    /// AND-chain, exactly like `neverOffersRetryUnlessAllowed`/
    /// `neverOffersRetryClaimUnlessAllowed` already coexist for retry).
    /// That guard catches a candidate ASSERTING a positive STATE
    /// ("everything's fine"); this one catches a candidate POSITIVELY
    /// EVALUATING the negative situation itself ("that's good to hear")
    /// — related, not identical, claim classes. Fires ONLY when local,
    /// authoritative `UserReportedState` is `.negative` (§16: no negative
    /// UserReportedState means this guard has nothing to say, and
    /// positive language is never globally forbidden — §15).
    public static func userReportedStateReactionGuard(_ text: String, userReportedState: UserReportedState?) -> Bool {
        guard let userReportedState, userReportedState.polarity == .negative else { return true }
        return candidateReactionValence(text) != .positiveAboutSituation
    }

    /// The combined P2-M5V7/§21, hardened by P2-M5V8.1-S §17-§22 and
    /// P2-M5V8.1-S2 §15/§16, gate `ConversationalResponsePresenter` runs
    /// every natural-realizer draft through — any single failure here
    /// means "discard the generated response, use the deterministic
    /// fallback" (§21's own explicit rule), never a partial/softened use
    /// of the offending text. The validating logic itself never becomes
    /// an authority on TRUTH (§17: "the validating LLM itself must NOT
    /// become authority") — every guard here is a bounded, deterministic,
    /// local phrase/fact comparison, never a second model call.
    /// - Parameters dialogueAct/correctionTarget/userReportedState: default
    ///   to `.unknown`/`nil`/`nil` so every pre-existing call site (which
    ///   has no reason to exercise the referential/user-state guards)
    ///   keeps compiling and behaving unchanged.
    /// - Parameter responseScope: P2-M5V8.1-R §6 — threaded through to
    ///   `neverClaimsActionForNotRequested`/`neverClaimsExecutionBeyondAuthority`/
    ///   `executionSuccessClaimGuard`/`neverOffersRetryUnlessAllowed`/
    ///   `neverOffersRetryClaimUnlessAllowed` (see each one's own doc
    ///   comment); defaults to `.conversationalShort`, preserving every
    ///   existing call site's exact behavior.
    public static func passesSemanticGuards(
        _ text: String, wasSuccess: Bool, actionExecutionState: ActionExecutionState, retryability: Retryability, failureReason: FailureReason,
        dialogueAct: DialogueAct = .unknown, correctionTarget: String? = nil, userReportedState: UserReportedState? = nil,
        responseScope: ResponseScope = .conversationalShort
    ) -> Bool {
        neverClaimsSuccessForFailure(text, wasSuccess: wasSuccess)
            && neverClaimsActionForNotRequested(text, actionExecutionState: actionExecutionState, responseScope: responseScope)
            && neverClaimsExecutionBeyondAuthority(text, actionExecutionState: actionExecutionState, responseScope: responseScope)
            && neverOffersRetryUnlessAllowed(text, retryability: retryability, actionExecutionState: actionExecutionState, responseScope: responseScope)
            && neverInventsFailureCause(text, failureReason: failureReason, actionExecutionState: actionExecutionState)
            && executionSuccessClaimGuard(text, actionExecutionState: actionExecutionState, responseScope: responseScope)
            && neverOffersRetryClaimUnlessAllowed(text, retryability: retryability, actionExecutionState: actionExecutionState, responseScope: responseScope)
            && permissionClaimGuard(text, actionExecutionState: actionExecutionState)
            && neverImpliesUnverifiedSensing(text)
            && referentialCorrectionClaimGuard(text, dialogueAct: dialogueAct, correctionTarget: correctionTarget)
            && referentialAmbiguityRequiresClarification(text, dialogueAct: dialogueAct, correctionTarget: correctionTarget)
            && userReportedStateContradictionGuard(text, userReportedState: userReportedState)
            && userReportedStateReactionGuard(text, userReportedState: userReportedState)
    }
}
