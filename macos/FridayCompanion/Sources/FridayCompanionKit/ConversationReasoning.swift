import Foundation

/// P2-M5V6 §5/§6 — "WHAT DOES THIS TURN MEAN IN THIS CONVERSATION."
/// Input is fully structured (never a raw prompt string handed to a
/// model with no gate) and output is a bounded `ConversationUnderstanding` —
/// never runtime truth (§6: "do NOT let this layer decide runtime
/// truth," §27: conversational intelligence may never invent success/
/// permission/capability/health/retry-support/failure-cause/external
/// facts). Intentionally SYNCHRONOUS today: no conforming implementation
/// in this milestone performs real network I/O (the LLM-backed
/// implementation is an interface/contract stub only, per §6's own
/// "implement the interface... then STOP before selecting an external
/// provider") — a future real provider integration is a Stage C concern
/// that would need `ResponsePresenting`'s own call site to become async,
/// not addressed by this pass.
public protocol ConversationReasoning: Sendable {
    func understand(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        acoustics: AcousticConversationFeatures, explicitUserStatements: [String]
    ) -> ConversationUnderstanding
}

/// The guaranteed, deterministic, no-LLM implementation (§0: "do not
/// remove the deterministic realizer — it becomes the guaranteed
/// fallback"; the same principle applies one layer up, to reasoning
/// itself). Every rule below is a literal pattern/phrase match against
/// already-safe, already-known inputs — never a learned model, never
/// real randomness, fully reproducible in tests.
///
/// P2-M5V7 §1/§2/§3 upgrade: this is the fix for P2-M5V6's own disclosed
/// gap ("FRIDAY can classify runtime outcomes, but does not yet
/// sufficiently understand what the user's utterance means as a
/// conversational act"). `classifyDialogueAct` runs FIRST, from the
/// transcript alone — it decides `interactionMode`/`actionExecutionState`
/// BEFORE (and independent of) whatever `context.wasSuccess`/`responseFamily`
/// says, so a `personalUpdate` like "I finally fixed that bug" can never
/// inherit "Done." merely because some outcome happens to be attached to
/// it (§2's own explicit requirement).
/// P2-M5V8.1-S §3/§4/§5 — `DialogueAct` and `InteractionMode` remain
/// SEPARATE concepts: a `.statement` (or `.request`/`.followUp`) is not,
/// by itself, evidence of an action request — it can equally be
/// conversational, situational, or informational. This is the typed,
/// LOCAL (never model-derived) evidence `interactionMode(for:evidence:)`
/// requires before it will resolve one of those three ambiguous
/// dialogue acts to `.actionRequest`. Absence of evidence must NOT become
/// `.actionRequest` merely because the utterance happens to be a bare
/// statement (§5's safety principle: "uncertain whether user asked
/// FRIDAY to perform an action → do not claim action execution").
public struct ActionRequestEvidence: Equatable, Sendable {
    public let explicitActionVerb: Bool
    public let explicitObjectOrTarget: Bool
    public let imperativeStructure: Bool
    public let priorPendingActionReference: Bool
    public let explicitModificationRequest: Bool
    public let explicitExecutionRequest: Bool

    public init(
        explicitActionVerb: Bool = false, explicitObjectOrTarget: Bool = false, imperativeStructure: Bool = false,
        priorPendingActionReference: Bool = false, explicitModificationRequest: Bool = false, explicitExecutionRequest: Bool = false
    ) {
        self.explicitActionVerb = explicitActionVerb
        self.explicitObjectOrTarget = explicitObjectOrTarget
        self.imperativeStructure = imperativeStructure
        self.priorPendingActionReference = priorPendingActionReference
        self.explicitModificationRequest = explicitModificationRequest
        self.explicitExecutionRequest = explicitExecutionRequest
    }

    /// `explicitObjectOrTarget` alone is deliberately NOT sufficient —
    /// a bare noun phrase ("the meeting") is not itself a request to act
    /// on it. Every other dimension is independently sufficient positive
    /// evidence.
    public var hasPositiveEvidence: Bool {
        explicitActionVerb || imperativeStructure || priorPendingActionReference || explicitModificationRequest || explicitExecutionRequest
    }

    public static let none = ActionRequestEvidence()
}

public struct DeterministicConversationReasoner: ConversationReasoning {
    // MARK: - Literal marker tables (priority-ordered in `classifyDialogueAct`)

    private static let prohibitionMarkers = ["don't change", "don't modify", "don't do", "do not change", "do not modify", "do not do", "don't touch", "don't make changes"]
    private static let constraintMarkers = ["wait for my", "wait for confirmation", "just answer", "just explain", "only answer", "only explain", "keep it as", "keep everything as", "don't act", "do not act", "not yet"]
    /// P2-M5V8.1-S §6 — GENERALIZABLE constraint/prohibition recognition,
    /// compositional rather than one more giant exact-phrase table: a
    /// "hold/stop" verb (leave/hold/wait/stop/keep) combined with an
    /// "inaction" complement (alone/off/unchanged/as it is/for now/on
    /// that/there/before doing-changing-you-do) reads as a prohibition
    /// regardless of which exact pairing appears — this generalizes to
    /// unseen combinations the same two small word-families can form
    /// (e.g. "Leave that exactly as it is," "Wait before changing
    /// anything," neither of which appears literally in either list).
    /// Real, proven failures this fixes: "Leave it alone for the
    /// moment." and "Hold off on that." previously matched NOTHING and
    /// fell through to the generic `.statement` default.
    private static let holdVerbs = ["leave", "hold", "wait", "stop", "keep"]
    private static let inactionComplements = ["alone", "off", "unchanged", "as it is", "as-is", "for now", "on that", "there", "before doing", "before changing", "before you do"]
    private static func isCompositionalProhibition(_ text: String) -> Bool {
        guard holdVerbs.contains(where: { text.contains($0) }) else { return false }
        return inactionComplements.contains(where: { text.contains($0) }) || text.contains("don't") || text.contains("do not")
    }
    // P2-M5V8.1-S2.2 §10 — "i meant"/"not this" added: real correction
    // wording ("I meant the first version.") that names no other lead-in
    // word at all previously fell through every marker to `.statement`,
    // silently defeating `correctionTarget`'s computation (and therefore
    // `referentialCorrectionClaimGuard`'s reference-compatibility gate)
    // since a non-`.correction` dialogueAct can never resolve one.
    private static let correctionMarkers = ["actually", "no,", "no.", "instead", "wait,", "sorry,", "i meant", "not this"]
    private static let followUpMarkers = ["again", "one more time"]
    private static let questionMarkers = ["why", "what", "how", "when", "where", "who", "is it", "did it", "can you tell me"]
    private static let acknowledgementMarkers = ["thanks", "thank you", "ok", "okay", "cool", "got it", "alright"]
    private static let commandMarkers = ["can you", "could you", "please", "create", "check", "make", "delete", "i need you to"]

    // MARK: - P2-M5V8.1-Q §2/§5 — CapabilityRequirement (local, deterministic, never asked of the model)

    /// §9 boundary — nouns whose CURRENT value only a real capability
    /// (never general model knowledge) can truthfully supply. Matched as
    /// "my/our <noun>" (possessive — "what's my battery percentage") or
    /// bare where the noun itself is unambiguous private/system state
    /// ("system status," "wifi" on its own reads as networking state, not
    /// a general-knowledge topic in this codebase's actual usage).
    private static let currentStateNouns = [
        "battery", "wifi", "wi-fi", "network", "inbox", "email", "calendar", "meeting", "message",
        "file", "location", "account", "disk space", "storage", "password", "contact", "system status",
        "notification",
    ]
    /// Compositional status-word family (mirrors `isCompositionalProhibition`'s
    /// hold-verb/complement-family pattern): "is <subject> running/connected/…"
    /// reads as asking about REAL current state regardless of which
    /// subject noun appears ("is Docker running," "is the printer
    /// connected") — generalizes without one entry per possible subject.
    private static let currentStateStatusWords = [
        "running", "connected", "online", "offline", "available", "enabled", "disabled",
        "logged in", "signed in", "up to date", "updated",
    ]
    private static let personalCurrentStatePhrases = [
        "do i have", "have i got", "what's on my", "what is on my", "what's my current", "what is my current",
    ]
    /// Verbs/phrases that unambiguously name a real-world action a
    /// capability would have to perform — deliberately EXCLUDES "check"
    /// (too ambiguous on its own — "check Python" could mean "is it
    /// installed" or "tell me about it"; see `capabilityRequirement`'s own
    /// `.unknown` fail-conservative handling) and EXCLUDES "give me"/"make"
    /// (both also used for pure content requests — "give me three ways…").
    private static let capabilityActionVerbs = [
        "send", "delete", "remove", "turn on", "turn off", "download", "upload", "install", "uninstall",
        "schedule", "set a reminder", "set an alarm", "play ", "pause ", "mute", "unmute", "call ",
        "text ", "restart", "shut down", "lock ", "unlock", "enable", "disable", "connect to", "disconnect",
        "fax", "print", "open ", "close ", "create a calendar", "create an event", "create a reminder",
    ]

    /// §4/§9 — checked FIRST, with priority over any informational-sounding
    /// pattern elsewhere in the same utterance: a private/current-state/
    /// action signal must never be shadowed by "explain"/"what is" wording
    /// appearing nearby ("what's my battery" must never be answered from
    /// general knowledge merely because it's grammatically a question).
    /// A small set of phrases that are unambiguously about CURRENT/RUNTIME
    /// state on their own, with no possessive needed ("what's the system
    /// status" is exactly as current-state-dependent as "what's MY system
    /// status") — deliberately NOT a bare noun like "battery" alone, which
    /// appears plenty in genuine general-knowledge questions ("how does a
    /// battery work").
    private static let unambiguousCurrentStatePhrases = ["system status", "battery percentage", "battery level"]

    private static func requiresCapability(_ text: String) -> Bool {
        if currentStateNouns.contains(where: { text.contains("my \($0)") || text.contains("our \($0)") }) { return true }
        if text.contains("my ") && currentStateNouns.contains(where: text.contains) { return true }
        if personalCurrentStatePhrases.contains(where: text.contains) { return true }
        if unambiguousCurrentStatePhrases.contains(where: text.contains) { return true }
        if text.contains(" is ") || text.hasPrefix("is ") {
            if currentStateStatusWords.contains(where: text.contains) { return true }
        }
        if capabilityActionVerbs.contains(where: text.contains) { return true }
        return false
    }

    /// §5 — informational-content requests, recognized by SEMANTIC lead
    /// phrases rather than one fragile fixture-string special case (§17):
    /// general explanations, definitions, comparisons, brainstorming,
    /// writing/advice, or a requested count/list of ideas — regardless of
    /// surface imperative grammar ("give me three ways…" reads as a
    /// content request, not a capability action, once `requiresCapability`
    /// has already ruled out a real private/current-state/action reading).
    /// P2-M5V8.1-R §2 — broadened from `"tell me about"` to bare `"tell
    /// me"` (a real, proven gap: "tell me my battery percentage" never
    /// matched the narrower phrase), and `"break down"`/`"show me"` added
    /// — the mission's own literal list of patterns to generalize.
    /// Broadening is safe for every EXISTING consumer of this table
    /// (`capabilityRequirement`/`responseScope`) because `requiresCapability`
    /// is always checked with priority ahead of it (see both call sites'
    /// own doc comments) — a bare "tell me"/"list "/"describe" match here
    /// never overrides a real private/current-state/action reading.
    private static let informationalLeadPhrases = [
        "explain", "describe", "define", "tell me", "walk me through", "help me understand",
        "break down", "show me", "summarize", "summarise", "brainstorm", "compare ", "what does",
        "what is", "what are", "how does", "how do", "how did", "how can", "give me", "list ",
        "what's the difference", "difference between", "pros and cons", "advice on", "tips for",
        "ways to", "ideas for",
    ]
    private static func isInformationalContentRequest(_ text: String) -> Bool {
        if text.contains(" why ") || text.hasPrefix("why") { return true }
        return informationalLeadPhrases.contains(where: text.contains)
    }

    /// The single entry point `understand(...)` calls. Priority order:
    /// a capability-required signal always wins; failing that, a
    /// recognized informational-content pattern OR an already-conversational
    /// interaction reads as `.notRequired`; anything else is `.unknown` —
    /// fails CLOSED (§2: "do not let unknown silently become general
    /// knowledge").
    private static func capabilityRequirement(dialogueAct: DialogueAct, interactionMode: InteractionMode, lowerTranscript: String?) -> CapabilityRequirement {
        guard let text = lowerTranscript, !text.isEmpty else { return .unknown }
        // Checked FIRST, with priority — see `requiresCapability`'s own doc
        // comment (§4/§9: a private/current-state/action signal must never
        // be shadowed by question-shaped or "explain"-flavored wording
        // appearing anywhere else in the same utterance).
        if requiresCapability(text) { return .required }
        // A `.question`/`.explanationRequest`/`.confirmationRequest`
        // dialogueAct — the EXISTING, already-tested local classifier's
        // own signal that this utterance is asking FOR information — is,
        // once a capability-required reading has already been ruled out
        // above, itself sufficient generalizable evidence of "informational,
        // no capability needed" (§5: prefer the existing classification
        // signal over a fragile new phrase list).
        if dialogueAct == .explanationRequest || dialogueAct == .question || dialogueAct == .confirmationRequest { return .notRequired }
        if interactionMode == .conversational { return .notRequired }
        if isInformationalContentRequest(text) { return .notRequired }
        return .unknown
    }
    /// Final Architectural Invariants §5: NOT a contiguous "i fixed"-style
    /// phrase table — that failed to generalize to "I eventually resolved
    /// that bug" (caught by this pass's own generalization test) because
    /// real speech routinely inserts adverbs/qualifiers between the
    /// subject and the verb ("I finally," "I eventually," "I just," "I
    /// somehow"). Matched instead as: the utterance opens with a
    /// first-person subject AND contains one of these achievement verbs
    /// ANYWHERE in it (checked in `classifyDialogueAct`, after the
    /// command-marker check already ruled out "I need you to fix..."-
    /// style requests) — still a literal table, still bounded, but no
    /// longer brittle to the exact word ordering of one specific example
    /// sentence.
    // P2-M5V8.1-S §27 — "figured it out" (a real, extremely common
    // pronoun-insertion pattern, distinct from the adverb-insertion class
    // already fixed above) was previously missed: "figured out" as a
    // literal substring doesn't match "figured IT out." Added alongside,
    // not replacing, the existing entry.
    private static let personalUpdateVerbs = ["fixed", "solved", "resolved", "finished", "figured out", "figured it out", "got it working", "sorted", "worked out"]
    private static let socialRemarkMarkers = ["that was annoying", "that was frustrating", "that was great", "that was nice", "that was cool", "that was awesome", "that was fun"]
    private static let greetingMarkers = ["hello", "hi ", "hey there", "good morning", "good afternoon", "good evening"]
    private static let farewellMarkers = ["bye", "goodbye", "good night", "see you", "talk later", "talk soon"]
    /// P2-M5V8.1-P.1 §14 — a real, live-confirmed gap the `contains`-based
    /// tables above never covered: a BARE greeting/farewell token with no
    /// filler around it at all ("Morning." "Evening." "Hey." "Hi.") used
    /// to fall all the way through to the generic `.statement` default,
    /// discarding the greeting entirely (`groundedFailureText`'s neighbor
    /// bug — see `NaturalResponseRealizer`'s own §2 fix for the sibling
    /// case). Matched as the WHOLE utterance (after trimming trailing
    /// punctuation only) rather than a substring, so this never
    /// misfires on a longer sentence that merely happens to CONTAIN one
    /// of these words (e.g. "I'll be there by morning").
    private static let bareGreetingTokens: Set<String> = ["hi", "hey", "hello", "morning", "evening", "afternoon"]
    private static let bareFarewellTokens: Set<String> = ["bye", "goodbye", "later", "take care"]
    private static func bareUtterance(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
    }
    /// §19: explicit language, not inferred acoustics, establishes
    /// urgency — literal phrase matching against the user's own words.
    private static let explicitUrgencyPhrases = ["this is important", "this is urgent", "right now", "urgently", "don't change anything"]
    /// P2-M5V8 §26/§13 — explicit user seriousness, separate from
    /// urgency: "I'm serious" doesn't necessarily mean time-pressure, but
    /// it MUST immediately and completely suppress humor (§13: "never...
    /// during... a serious situation," §26's own LOW-STAKES PLAYFUL THEN
    /// SERIOUS scenario). Deliberately its own list rather than folded
    /// into `explicitUrgencyPhrases`, since seriousness and urgency are
    /// different dimensions — this only ever gates humor, never register/
    /// urgency itself.
    /// P2-M5V8.1-P.2 §7/§9 — broadened from the original 6-phrase literal
    /// list, which real live evidence showed missed natural unseen
    /// paraphrases the mission itself named ("This is serious," "No,
    /// seriously," "Enough joking—this matters," "This one's important,"
    /// "Leave the jokes for later"). "serious"/"matters" as bare
    /// substrings are the actual generalization (catch "seriously,"
    /// "seriousness," "actually matters," "this matters" all at once) —
    /// `seriousnessNegationGuards` below exists specifically so a
    /// DISMISSAL using the same root word ("that doesn't matter," "it's
    /// not serious") is never misread as the opposite of what it says.
    private static let explicitSeriousnessPhrases = [
        "serious", "no joke", "not joking", "for real",
        "stop joking", "enough joking", "no more jokes", "leave the jokes",
        "matters", "one's important", "one is important",
    ]
    private static let seriousnessNegationGuards = ["not serious", "isn't serious", "wasn't serious", "doesn't matter", "didn't matter", "not important", "n't important", "n't matter"]
    private static func matchesExplicitSeriousness(_ text: String) -> Bool {
        explicitSeriousnessPhrases.contains { text.contains($0) } && !seriousnessNegationGuards.contains { text.contains($0) }
    }
    /// P2-M5V8.1-P.2 — a REAL regression caught during this pass's own
    /// development: `actionRequestEvidence`'s `isReinforcement` check
    /// below shares this SAME word-list concept for a completely
    /// different purpose (detecting a bare REAFFIRMATION of an existing
    /// PENDING action request, e.g. "I'm serious, delete it now" right
    /// after an action was already asked for — never meant to fire for
    /// an unrelated plain declarative report). Broadening
    /// `explicitSeriousnessPhrases` to the bare word "serious" for humor-
    /// gating purposes ALSO made `isReinforcement` fire on "This is
    /// serious — the staging environment is down." (a fresh REPORT, not
    /// a reinforcement of anything), which flipped `interactionMode` away
    /// from `.conversational` and produced a fabricated "Done." — the
    /// exact original P2-M5V7 bug class this whole codebase exists to
    /// prevent. `isReinforcement` keeps using this SEPARATE, deliberately
    /// narrow, unchanged-since-before-this-pass literal list instead.
    private static let reinforcementPhrases = ["i'm serious", "im serious", "no joke", "not joking", "for real", "seriously though"]
    /// §9's own casual-register cue words — informal address terms that,
    /// when present, suggest a casual register is welcome; deliberately
    /// NOT used to trigger slang in the response itself (§9: "friend-like
    /// does not mean slang every sentence") — only to inform register
    /// selection.
    private static let casualCueWords = ["bro", "dude", "lol", "haha"]
    private static let professionalCueWords = ["professor", "meeting", "presentation", "draft an email", "formal", "colleague", "client"]
    /// P2-M5V8.1-S §4 — a broader, still-bounded table of action verbs
    /// that, in SENTENCE-INITIAL position, constitute a genuine imperative
    /// mood ("Turn off the lights," not "The lights turned off") —
    /// evidence of an action request even when the narrower `commandMarkers`
    /// lead-in table (which requires a phrase like "can you"/"please")
    /// doesn't match. This is a GRAMMATICAL PATTERN, not a lookup of
    /// specific sentences — it generalizes to any unseen object/target
    /// following the verb.
    /// NOTE: deliberately EXCLUDES "make" — "Make it a little less
    /// formal"/"Make it warmer" is a style refinement (see
    /// `isStyleRefinement`), not a fresh action-verb signal; including it
    /// here would make every style-refinement remark ALSO register as
    /// generic action-verb evidence, defeating that distinction. "create"/
    /// "check"/"delete" ARE included even though `commandMarkers` also
    /// lists them — `commandMarkers` only matches when the marker is the
    /// SENTENCE-INITIAL phrase (`hasPrefix`), so a casual lead-in
    /// ("bro can you just delete all my files") still needs this
    /// anywhere-in-sentence check to register as genuine action evidence.
    private static let imperativeActionVerbs: Set<String> = [
        "turn", "set", "send", "schedule", "remind", "play", "open", "close",
        "start", "stop", "add", "remove", "update", "cancel", "move", "copy",
        "email", "text", "call", "message", "draft", "write", "save",
        "mute", "unmute", "pause", "resume", "restart", "enable", "disable",
        "lock", "unlock", "increase", "decrease", "adjust", "create", "check", "delete",
    ]
    private static let modificationVerbs = ["change", "modify", "update", "edit", "adjust", "revise"]
    private static let executionLeadIns = ["go ahead", "do it", "make it happen", "go for it", "just do it"]
    /// P2-M5V8.1-S §10, broadened by P2-M5V8.1-S2 §12/§25 — "I need to
    /// email my professor..." is a stated NEED, not a direct command
    /// ("Send this email..."). COMPOSITIONAL, not one phrase per verb
    /// tense: a first-person lead-in ("i "/"i'") combined with any of
    /// these need/intent VERB PHRASES anywhere in the sentence — so "I
    /// still need to message them" (contains "need to"), "I've got to
    /// write my professor" (contains "got to"), and "I ought to email my
    /// advisor" (contains "ought to") all generalize correctly without a
    /// dedicated entry each, unlike the old exact-lead-in list this
    /// replaces (which missed all three).
    private static let needIntentVerbPhrases = ["need to", "need help with", "want to", "like to", "ought to", "should", "got to", "have to"]
    private static func isNeedIntentStatement(_ text: String) -> Bool {
        guard text.hasPrefix("i ") || text.hasPrefix("i'") else { return false }
        return needIntentVerbPhrases.contains { text.contains($0) }
    }
    /// P2-M5V8.1-S §11, broadened by P2-M5V8.1-S2 §13/§25 — GENERALIZABLE
    /// style/tone-refinement recognition, compositional rather than one
    /// phrase per verb/adjective: "make it/that/this + <anything>"
    /// (anywhere in the sentence, not just sentence-initial, so "Could
    /// you make this friendlier?" is caught too) is the general pattern
    /// for adjusting an EXISTING artifact's wording, EXCLUDING the
    /// distinct "make it happen"-style execution lead-in. A dedicated
    /// style-verb family (`soften`/`tone down`/`dial back`) and a
    /// "keep/leave the tone + <register cue>" pattern cover phrasings
    /// that don't use "make" at all.
    private static let styleVerbPhrases = ["make it", "make that", "make this", "sound less", "sound more", "soften", "tone down", "tone it down", "dial back"]
    private static let styleCueWords = ["professional", "casual", "formal", "informal", "friendly", "friendlier", "warmer", "warm", "stiff", "stiffer", "harsh", "gentler", "softer"]
    private static func isStyleRefinement(_ text: String) -> Bool {
        if executionLeadIns.contains(where: { text.contains($0) }) { return false }
        if styleVerbPhrases.contains(where: { text.contains($0) }) { return true }
        let keepOrLeaveReferents = ["keep it", "keep this", "keep that", "leave the tone", "leave it", "leave that"]
        if keepOrLeaveReferents.contains(where: { text.contains($0) }) && styleCueWords.contains(where: { text.contains($0) }) { return true }
        return text.contains("tone") && styleCueWords.contains(where: { text.contains($0) })
    }

    /// P2-M5V8.1-S3 §7/§8 — GENERALIZABLE style-target extraction: the
    /// SAME style-cue vocabulary `isStyleRefinement` already recognizes,
    /// mapped to the bounded `ArtifactContext.Style` set — never a
    /// per-adjective table beyond this bounded vocabulary. Checked in a
    /// priority order so "less formal"/"informal" (→ casual) is never
    /// shadowed by the bare "formal" (→ formal) substring it contains.
    /// §23's own required generalization example ("Make that sound less
    /// stiff.") uses a `styleCueWords` entry (`stiff`) `isStyleRefinement`
    /// already recognized for DETECTION but this mapping previously had
    /// no target for — completed here rather than left unmapped, the same
    /// way `stiffer`/`harsh`/`gentler`/`softer` (already-detected cue
    /// words) now resolve too, instead of only ever producing the
    /// generic "I'll adjust the tone." fallback.
    private static func styleTarget(_ text: String) -> ArtifactContext.Style? {
        if text.contains("less formal") || text.contains("informal") || text.contains("casual") || text.contains("stiff") { return .casual }
        if text.contains("professional") { return .professional }
        if text.contains("formal") { return .formal }
        if text.contains("friendlier") || text.contains("friendly") || text.contains("harsh") || text.contains("gentler") || text.contains("softer") { return .friendly }
        if text.contains("warmer") || text.contains("warm") { return .warm }
        if text.contains("short") || text.contains("concise") || text.contains("brief") { return .concise }
        if text.contains("direct") { return .direct }
        return nil
    }

    /// P2-M5V8.1-S3 §3/§4/§5/§10 — the bounded conversational-continuity
    /// computation: topic, artifact, turn relation, and the reasoner's
    /// own (non-authoritative) pragmatic-act suggestion, all derived from
    /// the SAME dialogueAct/evidence this function already computed, plus
    /// (only for CONTINUITY carry-forward, never for truth) the single
    /// most recent turn. Always local/authoritative — see
    /// `ConversationalResponsePresenter.authoritative`'s own handling,
    /// which never lets a reasoner's suggestion override these.
    private static func conversationalContinuity(
        dialogueAct: DialogueAct, interactionMode: InteractionMode, lowerTranscript: String?,
        userReportedState: UserReportedState?, actionExecutionState: ActionExecutionState, recentTurns: [ConversationTurn]
    ) -> (topic: ActiveConversationTopic, artifact: ArtifactContext?, relation: ConversationTurnRelation, pragmaticAct: PragmaticResponseAct) {
        let previousTopic = recentTurns.last?.activeTopic ?? .none
        let previousArtifact = recentTurns.last?.artifactContext

        // §4 — active topic: some dialogue acts establish their OWN topic
        // outright; an otherwise-ambiguous plain statement INHERITS the
        // previous turn's topic (this is exactly what makes "It was one
        // environment variable." read as a continuation of "I finally
        // fixed that bug." rather than an unrelated update) — but only
        // when nothing else about THIS turn already explains it (a
        // genuinely new dialogue act, e.g. a fresh question, does not
        // inherit — see the `default` branch's own narrow condition).
        let topic: ActiveConversationTopic
        switch dialogueAct {
        case .personalUpdate: topic = .bugOrIssue
        case .needStatement: topic = .draftOrMessage
        case .styleRefinement: topic = previousTopic != .none ? previousTopic : .draftOrMessage
        default:
            if userReportedState != nil { topic = .runtimeStatus }
            else if actionExecutionState == .unsupported { topic = .unsupportedRequest }
            else if actionExecutionState == .denied { topic = .permissionOrPolicy }
            else if dialogueAct == .statement, interactionMode == .conversational, previousTopic != .none { topic = previousTopic }
            else { topic = .none }
        }

        // §25 — topic SHIFT: a genuinely new topic (computed above) means
        // any PRIOR artifact is no longer active — never silently keep
        // "editing the email" once the conversation has moved on. Only
        // .styleRefinement (refining the CURRENT artifact) and a plain
        // continuation of the SAME topic carry the artifact forward.
        let artifact: ArtifactContext?
        switch dialogueAct {
        case .needStatement:
            let text = lowerTranscript ?? ""
            let explicitKind: ArtifactContext.Kind? = text.contains("email") ? .email
                : text.contains("message") || text.contains("text") ? .message
                : text.contains("note") ? .note
                : nil
            if let explicitKind {
                // A kind named IN THIS TURN always establishes/overrides
                // the artifact (a genuinely new or different draft).
                artifact = ArtifactContext(kind: explicitKind)
            } else if previousTopic == .draftOrMessage, let previousArtifact {
                // §6/§24 — a SECOND (or later) needStatement continuing the
                // SAME ongoing draft (no new kind named this turn) keeps
                // the artifact already established — kind AND any style
                // already refined for it — rather than silently resetting
                // to `.unspecified`/no style. Real gap this closes: "I
                // still need to mention the exam date." right after an
                // email draft was already refined to `.professional`
                // used to drop back to kind=`.unspecified`, style=nil.
                artifact = previousArtifact
            } else {
                artifact = ArtifactContext(kind: .unspecified)
            }
        case .styleRefinement:
            let requested = lowerTranscript.flatMap(Self.styleTarget)
            artifact = ArtifactContext(kind: previousArtifact?.kind ?? .unspecified, requestedStyle: requested ?? previousArtifact?.requestedStyle)
        default:
            artifact = (topic != .none && topic == previousTopic) ? previousArtifact : nil
        }

        // §3/§26 — turn relation.
        let relation: ConversationTurnRelation
        switch dialogueAct {
        case .correction: relation = .correction
        case .styleRefinement: relation = .refinement
        case .constraint, .prohibition: relation = .constraint
        case .explanationRequest: relation = .explanation
        case .personalUpdate, .socialRemark: relation = .reaction
        default:
            relation = (topic != .none && topic == previousTopic) ? .continuation : .newTopic
        }

        // §10/§20 — the reasoner's own, non-authoritative pragmatic-act
        // suggestion.
        let pragmaticAct: PragmaticResponseAct
        switch dialogueAct {
        case .personalUpdate: pragmaticAct = .celebrate
        case .needStatement: pragmaticAct = .continueDraft
        case .styleRefinement: pragmaticAct = .applyStyleRefinement
        case .constraint, .prohibition: pragmaticAct = .confirmConstraint
        case .explanationRequest: pragmaticAct = .explain
        case .greeting: pragmaticAct = .greeting
        case .farewell: pragmaticAct = .farewell
        case .correction: pragmaticAct = .clarify
        default:
            if actionExecutionState == .executedSucceeded { pragmaticAct = .reportSuccess }
            else if actionExecutionState == .executedFailed { pragmaticAct = .reportFailure }
            else if actionExecutionState == .unsupported { pragmaticAct = .unsupported }
            else if userReportedState != nil { pragmaticAct = .commiserate }
            else { pragmaticAct = .acknowledge }
        }

        return (topic, artifact, relation, pragmaticAct)
    }

    /// P2-M5V8.1-O.5 §7/§9 — GENERALIZABLE (compositional phrase roots,
    /// not a lookup of exact sentences — §22: "tests must use unseen
    /// paraphrases") detection that the user explicitly asked for FULL/
    /// COMPLETE content, overriding the otherwise-brief scope a
    /// needStatement/styleRefinement turn would normally get.
    private static let explicitLongFormPhrases = [
        "the whole", "the entire", "in full", "entirely", "full report", "full version",
        "complete draft", "everything", "whole thing", "give me the full", "write the whole",
        // P2-M5V8.1-Q §6 — "explain X in detail" is a real, plain way to
        // explicitly ask for full-length content that none of the above
        // phrases covered.
        "in detail", "in depth", "at length", "thoroughly",
    ]
    private static func isExplicitLongFormRequest(_ text: String) -> Bool {
        explicitLongFormPhrases.contains { text.contains($0) }
    }

    /// P2-M5V8.1-O.5 §1/§6 — HOW MUCH the realized response should say,
    /// derived ENTIRELY from signals that are already local/authoritative
    /// (never from the model — see `ResponseScope`'s own doc comment for
    /// the real live over-generation failure this fixes). `.artifactDraft`/
    /// `.artifactRewrite` are never selected here today: `ArtifactContext`
    /// never carries real drafted body text this codebase could actually
    /// rewrite FROM, so a needStatement/styleRefinement turn always
    /// resolves to asking for more / a short acknowledgement instead of
    /// fabricating placeholder content — UNLESS the user explicitly asked
    /// for the whole/complete thing (§9), which always wins regardless of
    /// dialogueAct.
    private static func responseScope(
        dialogueAct: DialogueAct, actionExecutionState: ActionExecutionState, lowerTranscript: String?,
        capabilityRequirement: CapabilityRequirement = .unknown
    ) -> ResponseScope {
        if let text = lowerTranscript, isExplicitLongFormRequest(text) { return .longFormRequested }
        switch dialogueAct {
        case .needStatement: return .clarifyingQuestion
        case .styleRefinement: return .conversationalShort
        case .constraint, .prohibition: return .briefStatus
        case .explanationRequest: return .briefExplanation
        default: break
        }
        if actionExecutionState == .executedFailed || actionExecutionState == .denied { return .briefExplanation }
        // P2-M5V8.1-Q §5/§6 — the second proven real failure: an
        // informational-content request ("give me three practical ways to
        // stay focused," "compare TCP and UDP") that the dialogueAct
        // classifier didn't happen to recognize as `.explanationRequest`/
        // `.question` (it fell to the generic `.statement` bucket) still
        // needs a SUBSTANTIVE scope — never the casual `conversationalShort`
        // meant for small talk, which is what produced "Good call." instead
        // of the three actually-requested items. Gated on
        // `capabilityRequirement == .notRequired` so this never fires for a
        // turn that actually needs a capability/private/current-state
        // answer (§9 boundary preserved).
        if capabilityRequirement == .notRequired, let text = lowerTranscript, isInformationalContentRequest(text) {
            return .briefExplanation
        }
        return .conversationalShort
    }

    /// P2-M5V8.1-S2.2 §5/§6/§7 — GENERALIZABLE (compositional keyword
    /// roots, not a lookup of full sentences) detection of a NEGATIVE
    /// situational claim in the user's OWN current-turn words: "is down,"
    /// "is offline," "is failing," "keeps crashing," "broke," etc. This
    /// is ALWAYS computed locally/authoritatively (see
    /// `ConversationalResponsePresenter.authoritative`) — never trusted
    /// from a model reasoner — because it directly gates a safety
    /// property (§5: "FRIDAY must not directly contradict a user-
    /// asserted state"), the same discipline already applied to
    /// `actionExecutionState`/local-evidence-vetoed `interactionMode`.
    private static let negativeSituationalStateWords = [
        "down", "offline", "failing", "broke", "broken", "crashing", "crashed",
        "unresponsive", "not working", "isn't working", "stopped working", "acting up", "acting weird",
        // P2-M5V8.1-S3.1 §17 — "The database isn't responding." (one of
        // the mission's own required unseen examples) matched neither
        // root above ("unresponsive" is a different word entirely).
        "not responding", "isn't responding",
        // P2-M5V8.1-P.2 §7/§9 — "the payment service is timing out on
        // everyone" (live-observed real evidence) matched none of the
        // roots above either.
        "timing out", "times out", "timed out",
    ]
    static func detectsNegativeSituationalState(_ lowerTranscript: String?) -> Bool {
        guard let text = lowerTranscript else { return false }
        return negativeSituationalStateWords.contains { text.contains($0) }
    }

    public init() {}

    public func understand(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        acoustics: AcousticConversationFeatures, explicitUserStatements: [String]
    ) -> ConversationUnderstanding {
        let lowerTranscript = transcript?.lowercased()

        let intent = Self.classifyIntent(lowerTranscript)
        let dialogueAct = Self.classifyDialogueAct(lowerTranscript)
        let evidence = Self.actionRequestEvidence(lowerTranscript: lowerTranscript, dialogueAct: dialogueAct, recentTurns: recentTurns)
        let interactionMode = Self.interactionMode(for: dialogueAct, evidence: evidence)
        let capabilityRequirement = Self.capabilityRequirement(dialogueAct: dialogueAct, interactionMode: interactionMode, lowerTranscript: lowerTranscript)

        let isCorrection = intent == .correction
        let continuation = isCorrection && recentTurns.last != nil
            && (context.taskID.isEmpty || recentTurns.last?.taskID != context.taskID)

        let explicitUrgency = lowerTranscript.map { text in Self.explicitUrgencyPhrases.contains { text.contains($0) } } ?? false
            || explicitUserStatements.contains { statement in Self.explicitUrgencyPhrases.contains { statement.lowercased().contains($0) } }
        let explicitSeriousness = lowerTranscript.map { Self.matchesExplicitSeriousness($0) } ?? false

        let registerRecommendation = Self.registerRecommendation(lowerTranscript: lowerTranscript)

        // §10: humor is appropriate only for genuinely low-stakes,
        // already-successful-or-benign outcomes — never for anything the
        // strategy layer will itself classify as failure/denial/warning
        // (that final gate lives in `HumorPolicy`; this is the
        // reasoner's own, narrower, additional judgment that a SUCCESS/
        // UNSUPPORTED moment reads as low-stakes, not e.g. a repeated
        // frustrated retry). Explicit seriousness ("I'm serious") stops
        // humor immediately, same as explicit urgency, even though it
        // doesn't itself imply urgency (§26).
        //
        // P2-M5V8.1-P.2 §7/§8 — root-cause fix for real live evidence:
        // this gate never consulted a NEGATIVE SITUATIONAL REPORT at all
        // ("Great, now the payment service is timing out on everyone."
        // computed `humorAppropriate == true`, since `context.wasSuccess`
        // was true and neither urgency nor seriousness phrase matched) —
        // a plain success/benign OUTCOME CODE says nothing about whether
        // the user's OWN words just described something going wrong.
        // Also suppressed when THIS turn is a plain follow-up continuing
        // a topic a PRIOR turn already established as a negative report
        // (`recentTurns.last?.activeTopic == .runtimeStatus`) — so a
        // consequence-describing follow-up with no explicit trigger word
        // of its own ("People can't check out.") still inherits the
        // seriousness of the incident it's continuing, the same
        // continuity principle `conversationalContinuity` below already
        // applies to topic/artifact carry-forward.
        // Deliberately NOT also gated on `interactionMode == .conversational`:
        // a consequence-describing follow-up can incidentally contain a
        // word `imperativeActionVerbs` recognizes ("People can't check
        // out" contains "check"), which flips interactionMode away from
        // `.conversational` for reasons unrelated to seriousness — dialogueAct
        // alone (`.statement`, the "nothing more specific matched" bucket)
        // is already the narrow signal that matters here.
        let previousTopicWasNegativeReport = recentTurns.last?.activeTopic == .runtimeStatus && dialogueAct == .statement
        let humorAppropriate = (context.wasSuccess || context.responseFamily == .unsupportedIntent)
            && !explicitUrgency && !explicitSeriousness && interactionMode != .constraint
            && !Self.detectsNegativeSituationalState(lowerTranscript) && !previousTopicWasNegativeReport

        let actionExecutionState = Self.actionExecutionState(interactionMode: interactionMode, context: context, dialogueAct: dialogueAct, capabilityRequirement: capabilityRequirement)
        let explicitConstraints = Self.explicitConstraints(dialogueAct: dialogueAct, lowerTranscript: lowerTranscript)
        let failureReason = Self.failureReason(actionExecutionState: actionExecutionState, context: context)
        let retryability = Self.retryability(actionExecutionState: actionExecutionState, context: context, failureReason: failureReason)
        // P2-M5V8.1-S §12, broadened by P2-M5V8.1-S2.2 §1/§4 — referential
        // correction grounding. A bare "no title" hint wasn't enough for
        // the realizer/model to know WHICH prior item is being
        // referenced — now carries an explicit referential direction
        // ("earlier"/"new") parsed from the correction's own wording, so
        // "No, the earlier one" can be told to refer BACK, never invent a
        // NEW item. Previously gated on a prior `.createNoteSuccess` turn
        // existing in `recentTurns` — an artifact of this field's
        // original, narrower note-specific origin that silently defeated
        // `ResponseValidation.referentialCorrectionClaimGuard` for any
        // OTHER kind of correction ("the previous version," "the earlier
        // draft") since `correctionTarget` would stay `nil` regardless of
        // what the transcript said. This is a REFERENCE-COMPATIBILITY
        // fact about the CURRENT utterance's own wording — it generalizes
        // to any artifact, not just notes, and no longer depends on
        // conversation history at all.
        let correctionTarget: String? = dialogueAct == .correction ? Self.referentialDirection(lowerTranscript: lowerTranscript) : nil
        let userReportedState: UserReportedState? = Self.detectsNegativeSituationalState(lowerTranscript)
            ? UserReportedState(polarity: .negative, source: .userReported)
            : nil
        let continuity = Self.conversationalContinuity(
            dialogueAct: dialogueAct, interactionMode: interactionMode, lowerTranscript: lowerTranscript,
            userReportedState: userReportedState, actionExecutionState: actionExecutionState, recentTurns: recentTurns
        )
        let responseScope = Self.responseScope(dialogueAct: dialogueAct, actionExecutionState: actionExecutionState, lowerTranscript: lowerTranscript, capabilityRequirement: capabilityRequirement)

        return ConversationUnderstanding(
            communicativeIntent: intent, topic: nil, continuationOfPreviousTurn: continuation,
            clarificationNeeded: context.needsClarification, userExplicitPreference: nil,
            explicitUrgency: explicitUrgency, socialRegisterRecommendation: registerRecommendation,
            humorAppropriateness: humorAppropriate, responseGoal: nil, recommendedVerbosity: nil,
            followUpNeeded: false, uncertainty: 0.4, // a rule-based reasoner is never fully confident about MEANING, only about literal pattern matches
            dialogueAct: dialogueAct, interactionMode: interactionMode, actionExecutionState: actionExecutionState,
            explicitConstraints: explicitConstraints, failureReason: failureReason, retryability: retryability,
            userGoal: dialogueAct == .greeting ? Self.greetingToken(lowerTranscript: lowerTranscript) : nil,
            correctionTarget: correctionTarget, explanationRequested: dialogueAct == .explanationRequest,
            humorSuitability: humorAppropriate ? 0.5 : 0, userReportedState: userReportedState,
            turnRelation: continuity.relation, activeTopic: continuity.topic, artifactContext: continuity.artifact,
            pragmaticResponseAct: continuity.pragmaticAct, responseScope: responseScope, capabilityRequirement: capabilityRequirement
        )
    }

    private static func classifyIntent(_ lowerTranscript: String?) -> CommunicativeIntent {
        guard let text = lowerTranscript, !text.isEmpty else { return .unknown }
        if correctionMarkers.contains(where: { text.hasPrefix($0) }) { return .correction }
        if questionMarkers.contains(where: { text.hasPrefix($0) || text.contains(" \($0) ") }) { return .question }
        if acknowledgementMarkers.contains(where: { text == $0 || text.hasPrefix($0) }) { return .acknowledgement }
        if commandMarkers.contains(where: { text.hasPrefix($0) }) { return .command }
        return .statement
    }

    /// P2-M5V7 §1 — the real dialogue-act classifier, run in a fixed
    /// priority order so a multi-clause utterance like "This is
    /// important. Don't change anything yet." resolves to the
    /// ACTIONABLE part (a prohibition) rather than whatever clause
    /// happens to come first.
    private static func classifyDialogueAct(_ lowerTranscript: String?) -> DialogueAct {
        guard let text = lowerTranscript, !text.isEmpty else { return .unknown }
        if prohibitionMarkers.contains(where: { text.contains($0) }) { return .prohibition }
        if constraintMarkers.contains(where: { text.contains($0) }) { return .constraint }
        if isCompositionalProhibition(text) { return .prohibition }
        // P2-M5V8.1-S §11 — checked BEFORE `correctionMarkers`/`commandMarkers`
        // so "Actually, keep this professional." resolves to a style
        // refinement (not a correction) and "Make it a little less
        // formal." resolves to a style refinement (not a bare command) —
        // both real, live-observed failures.
        if isStyleRefinement(text) { return .styleRefinement }
        // P2-M5V8.1-S §10 — checked before the generic `.statement`
        // fallback so a stated need/intent is distinguished from both a
        // direct command and a content-free statement.
        if isNeedIntentStatement(text) { return .needStatement }
        if correctionMarkers.contains(where: { text.hasPrefix($0) }) { return .correction }
        if text.hasPrefix("why") { return .explanationRequest }
        if followUpMarkers.contains(where: { text.contains($0) }) { return .followUp }
        if questionMarkers.contains(where: { text.hasPrefix($0) || text.contains(" \($0) ") }) { return .question }
        if acknowledgementMarkers.contains(where: { text == $0 || text.hasPrefix($0) }) { return .acknowledgement }
        if commandMarkers.contains(where: { text.hasPrefix($0) }) { return .command }
        if (text.hasPrefix("i ") || text.hasPrefix("i've") || text.hasPrefix("i'm")) && personalUpdateVerbs.contains(where: { text.contains($0) }) {
            return .personalUpdate
        }
        if socialRemarkMarkers.contains(where: { text.contains($0) }) { return .socialRemark }
        // P2-M5V8.1-HW — proven regression (§13 of that pass): this used to
        // require an EXACT match or the greeting to be the very first
        // words ("Good morning." matched, "Hey, good morning." did not),
        // unlike its own sibling check two lines below (`farewellMarkers`
        // already matches anywhere via `.contains`). A real utterance with
        // a filler lead-in fell through every marker table to the generic
        // `.statement` default and inherited whatever runtime outcome
        // happened to be attached — reproduced live via the harness's own
        // "Hey, good morning." scenario. Fixed to match `farewellMarkers`'
        // already-correct pattern.
        if greetingMarkers.contains(where: { text.contains($0) }) { return .greeting }
        if farewellMarkers.contains(where: { text.contains($0) }) { return .farewell }
        if bareGreetingTokens.contains(bareUtterance(text)) { return .greeting }
        if bareFarewellTokens.contains(bareUtterance(text)) { return .farewell }
        if text.hasSuffix("?") { return .request }
        // P2-M5V8.1-R §1/§2/§3 — the actual, real, forensically-proven
        // production bug this pass fixes: surface grammar (imperative,
        // no question mark, no question word) was being confused with
        // semantic intent. "Explain machine learning in five sentences,"
        // "Describe photosynthesis," "Give me three ways to focus,"
        // "List four differences," "Compare TCP and UDP," "Summarize
        // gradient descent," "Define overfitting" all fell all the way
        // through every check above to the generic `.statement` default
        // — which (see `interactionMode(for:evidence:)`'s `.statement`
        // case) becomes `.conversational` whenever no action-verb
        // evidence is present, and `.conversational` unconditionally
        // resolves to `actionExecutionState: .notRequested` WITHOUT ever
        // consulting `capabilityRequirement` — the exact bypass that let
        // "Tell me my battery percentage"/"List my meetings today"/
        // "Describe my latest email" (genuinely private/current-state,
        // `capabilityRequirement == .required`) silently escape the
        // fail-closed truth boundary too, not just general-knowledge
        // turns. Checked LAST (after every more specific existing
        // pattern) and reuses `isInformationalContentRequest` — the
        // SAME, already-tested signal `capabilityRequirement`/
        // `responseScope` already rely on — so this is a routing fix,
        // not a new decision: `.explanationRequest` maps to
        // `interactionMode: .informationRequest` (line below), which
        // DOES consult `capabilityRequirement` (via `actionExecutionState`'s
        // `.informationRequest` branch), so `requiresCapability`'s own
        // existing, unchanged, priority-one check is what actually
        // decides `.notRequested` (general knowledge, safe to answer)
        // vs. `.unsupported` (private/current-state, fail-closed) —
        // exactly the distinction PART 3 requires, achieved with zero
        // new authority logic.
        if isInformationalContentRequest(text) { return .explanationRequest }
        // P2-M5V8.1-R §3 — the SAME bypass, closed for the other
        // direction too: a real evidence gap found while fixing the
        // above (not merely theorized) — `capabilityActionVerbs` (used
        // by `requiresCapability`, checked with priority inside
        // `capabilityRequirement` below) recognizes several real action
        // verbs — "download," "upload," "install," "uninstall," "shut
        // down," "connect to," "disconnect," "fax," "print" — that
        // `imperativeActionVerbs` (used by `actionRequestEvidence`,
        // above/upstream of this function) does not, so a bare command
        // like "Download this report." (PART 3's own required example)
        // fell to `.statement` -> `.conversational` -> the identical
        // unconditional `.notRequested` bypass this whole pass exists to
        // close. `.command` (not `.explanationRequest`) — this is a real
        // action attempt, not a content request, so it must not inherit
        // `responseScope`'s `.explanationRequest` special case; it falls
        // through that function's existing, unchanged
        // `capabilityRequirement`-gated logic exactly like any other
        // unsupported action already does.
        if requiresCapability(text) { return .command }
        return .statement
    }

    /// P2-M5V8.1-P.1 §14 — "FRIDAY may naturally mirror" the user's own
    /// greeting token: extracts a SHORT, SAFE label for which recognized
    /// token the user actually said (never fabricated — only ever one of
    /// the already-recognized markers/bare tokens above), so realization
    /// can echo it back naturally instead of always reaching for the same
    /// generic line. Reuses `userGoal` (an existing, general-purpose,
    /// safe "short restatement of what the user said" field — see its own
    /// doc comment) rather than introducing any new field/authority.
    private static func greetingToken(lowerTranscript: String?) -> String? {
        guard let text = lowerTranscript else { return nil }
        if text.contains("good morning") || bareUtterance(text) == "morning" { return "morning" }
        if text.contains("good evening") || bareUtterance(text) == "evening" { return "evening" }
        if text.contains("good afternoon") || bareUtterance(text) == "afternoon" { return "afternoon" }
        if text.contains("hey") { return "hey" }
        if text.contains("hi ") || bareUtterance(text) == "hi" { return "hi" }
        return nil // "hello" or anything else recognized only by the broader marker table — the existing generic pool already covers this well
    }

    /// P2-M5V8.1-S §3/§4/§5 — computes the LOCAL, typed evidence a
    /// dialogue act alone cannot express. `.unknown` (no transcript at
    /// all — e.g. a scheduled/programmatic trigger with no accompanying
    /// speech) always reports NO evidence here but is handled as a
    /// special case directly in `interactionMode(for:evidence:)`, since
    /// "nothing was said" is a fundamentally different situation from
    /// "something was said but it doesn't look like a command."
    static func actionRequestEvidence(lowerTranscript: String?, dialogueAct: DialogueAct, recentTurns: [ConversationTurn]) -> ActionRequestEvidence {
        guard let text = lowerTranscript, !text.isEmpty else { return .none }
        let words = text.split(separator: " ").map(String.init)
        let firstWord = words.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?")) } ?? ""
        let imperativeStructure = imperativeActionVerbs.contains(firstWord)
        let explicitActionVerb = imperativeStructure || imperativeActionVerbs.contains(where: { text.contains(" \($0) ") || text.hasPrefix("\($0) ") })
        let explicitObjectOrTarget = words.count > 2
        let explicitModificationRequest = modificationVerbs.contains { text.contains($0) }
        let explicitExecutionRequest = executionLeadIns.contains { text.contains($0) }
        // §4's `priorPendingActionReference`. Two distinct patterns both
        // reference a pending/recent action rather than starting fresh
        // conversation: (1) a follow-up ("again"/"one more time") right
        // after a turn that was itself request-shaped — "do that again";
        // (2) a bare reaffirmation ("I'm serious," "for real," "no
        // joke") immediately after ANY prior turn — the user is
        // emphasizing an existing exchange, not introducing a new,
        // unrelated conversational remark, so the existing thread's mode
        // should persist rather than being reset to `.conversational`.
        let isReinforcement = reinforcementPhrases.contains { text.contains($0) } || explicitUrgencyPhrases.contains { text.contains($0) }
        let priorPendingActionReference =
            (dialogueAct == .followUp && recentTurns.last?.responseFamily != nil && recentTurns.last?.responseFamily != .genericSuccess)
            || (isReinforcement && recentTurns.last != nil)
        return ActionRequestEvidence(
            explicitActionVerb: explicitActionVerb, explicitObjectOrTarget: explicitObjectOrTarget, imperativeStructure: imperativeStructure,
            priorPendingActionReference: priorPendingActionReference, explicitModificationRequest: explicitModificationRequest,
            explicitExecutionRequest: explicitExecutionRequest
        )
    }

    /// P2-M5V8.1-S §12 — parses which prior item a correction refers
    /// back to, from the correction's own wording alone. Never invents a
    /// target when ambiguous (`nil` — the realizer/model must then avoid
    /// claiming a SPECIFIC item, never substitute a guess).
    ///
    /// P2-M5V8.1-P.2-FINAL-CLOSURE §10/§11/§12 — now also returns the
    /// EXPLICIT sentinel `"ambiguous"` for a GENERIC referent that names
    /// no specific target at all ("the other one," "that one") —
    /// distinguished from a bare `nil` (a NAMED correction, "I meant
    /// groceries," which stays resolved/unflagged since the name itself
    /// already grounds it uniquely). This reuses the EXISTING
    /// `correctionTarget` field/precedent rather than adding a new
    /// authority concept — `referentialCorrectionClaimGuard`'s own
    /// existing `correctionTarget == "earlier"` check is unaffected by
    /// this new possible value.
    static func referentialDirection(lowerTranscript: String?) -> String? {
        guard let text = lowerTranscript else { return nil }
        if text.contains("earlier") || text.contains("first") || text.contains("before") || text.contains("previous") { return "earlier" }
        if text.contains("new") || text.contains("latest") || text.contains("just made") || text.contains("last one") { return "new" }
        if genericAmbiguousReferentPhrases.contains(where: { text.contains($0) }) { return "ambiguous" }
        return nil
    }
    private static let genericAmbiguousReferentPhrases = ["the other one", "another one", "the other", "that one"]

    /// P2-M5V7 §2, hardened by P2-M5V8.1-S §3/§4/§5 — `InteractionMode`
    /// is DERIVED from `dialogueAct` FIRST, but for the three dialogue
    /// acts that are inherently ambiguous about whether they constitute
    /// an action request (`.statement`, `.request`, `.followUp`), real
    /// positive `ActionRequestEvidence` is now REQUIRED before resolving
    /// to `.actionRequest` — absence of evidence is NOT itself evidence
    /// of an action (§5's safety principle). `.unknown` (no transcript at
    /// all) is the one case preserved as `.actionRequest` unconditionally
    /// — a programmatic/scheduled trigger with no speech to evaluate is a
    /// fundamentally different situation, not an "ambiguous statement."
    static func interactionMode(for dialogueAct: DialogueAct, evidence: ActionRequestEvidence = .none) -> InteractionMode {
        switch dialogueAct {
        case .personalUpdate, .acknowledgement, .socialRemark, .jokeOrPlayfulRemark, .greeting, .farewell:
            return .conversational
        case .constraint, .prohibition:
            return .constraint
        case .correction:
            return .correction
        case .clarification:
            return .clarification
        case .explanationRequest, .question, .confirmationRequest:
            return .informationRequest
        case .command:
            return .actionRequest // a command marker IS itself strong, direct evidence
        case .needStatement, .styleRefinement:
            return .actionRequest // FRIDAY should help — realization, not classification, is where over-claiming is prevented
        case .unknown:
            return .actionRequest // no transcript at all — a programmatic trigger, not an ambiguous utterance
        case .request:
            // Question-shaped (ends "?") but matched no specific question
            // word — §5: prefer informationRequest over conversational
            // for a question-shaped utterance with no action evidence.
            return evidence.hasPositiveEvidence ? .actionRequest : .informationRequest
        case .followUp, .statement:
            return evidence.hasPositiveEvidence ? .actionRequest : .conversational
        case .permissionResponse:
            return .actionRequest // unreached by the deterministic classifier today; preserved conservatively
        }
    }

    /// P2-M5V7 §3 — the authoritative gate. `.conversational`/`.constraint`
    /// utterances NEVER produced a real action request, so this is
    /// `.notRequested` UNCONDITIONALLY for them — regardless of whatever
    /// `context.wasSuccess`/`responseFamily` a (possibly synthetic, e.g.
    /// harness/test) outcome happens to carry. Every other interaction
    /// mode derives this honestly from the real runtime outcome.
    /// - Parameter dialogueAct: P2-M5V8.1-S2 §11/§12/§13 — the actual fix
    ///   for a real live-model failure: "I need to email my professor..."
    ///   (dialogueAct `.needStatement`) legitimately resolves to
    ///   `interactionMode: .actionRequest` (FRIDAY should engage/help),
    ///   but a stated NEED/INTENTION, or a STYLE REFINEMENT of an
    ///   existing artifact, never itself proves a verified EXTERNAL
    ///   action occurred — so `.executedSucceeded` must not be reachable
    ///   for these two dialogue acts merely because `context.wasSuccess`
    ///   happens to be true. This is the missing half of P2-M5V8.1-S's
    ///   own fix: that pass correctly kept `interactionMode ==
    ///   .actionRequest` for these acts, but this function (which only
    ///   took `interactionMode`, not `dialogueAct`) had no way to apply
    ///   the distinction, so the MODEL realizer — correctly trusting the
    ///   `authoritativeFacts.actionExecutionState` it was handed —
    ///   generated truthful-per-the-facts-it-was-given, but WRONG,
    ///   completion wording ("That's taken care of."). Every other
    ///   dialogue act's behavior is completely unchanged (default `.unknown`
    ///   parameter preserves every existing call site/test).
    /// - Parameter capabilityRequirement: P2-M5V8.1-Q §3 — REAL, forensically-
    ///   proven fix: a pure informational/no-capability-needed turn
    ///   (`.notRequired`) that friday-daemon correctly reports as
    ///   `UNSUPPORTED_INTENT` (no executable capability existed — because
    ///   none was needed) must NOT become `.unsupported` here. Daemon
    ///   `UNSUPPORTED_INTENT` means "no executable capability was
    ///   resolved," never, by itself, "the overall user turn is
    ///   unsupported" (see `docs/PHASE-2-ARCHITECTURE.md`'s corrected
    ///   rule). Defaults to `.unknown`, which preserves EVERY existing
    ///   call site/test byte-for-byte: only an explicit `.notRequired`
    ///   changes this function's output at all, and only for the
    ///   `.informationRequest`/`.correction`/`.clarification` branch below
    ///   (an `.actionRequest` with a genuinely required-but-missing
    ///   capability is completely unaffected — §4/§9: capability/action
    ///   truth is never weakened).
    static func actionExecutionState(
        interactionMode: InteractionMode, context: ConversationContext, dialogueAct: DialogueAct = .unknown,
        capabilityRequirement: CapabilityRequirement = .unknown
    ) -> ActionExecutionState {
        guard dialogueAct != .needStatement, dialogueAct != .styleRefinement else { return .notRequested }
        switch interactionMode {
        case .conversational, .constraint:
            return .notRequested
        case .actionRequest, .informationRequest, .correction, .clarification:
            if context.wasSuccess { return .executedSucceeded }
            switch context.responseFamily {
            case .policyDenied: return .denied
            case .unsupportedIntent, .invalidRequest, .irValidationFailed:
                // §3/§4 — the daemon found no executable capability. If
                // local semantics already establish none was actually
                // needed for this turn, that is NOT an unsupported
                // action — it is simply not an action at all. The raw
                // daemon outcome (`context.responseFamily`) is preserved
                // unchanged elsewhere (§4: never erased) — only the
                // AUTHORITATIVE-ACTION-TRUTH interpretation of it changes.
                return capabilityRequirement == .notRequired ? .notRequested : .unsupported
            case .ambiguousIntent: return .requestedNotStarted
            case .executionFailed, .capabilityUnavailable, .policyUnavailable, .verificationFailed, .internalError, .transportFailure:
                return .executedFailed
            default:
                return .unknown
            }
        }
    }

    /// P2-M5V7 §4 — only ever derived from LITERAL wording, never
    /// inferred. Picks the single best-matching constraint rather than a
    /// set, since the deterministic phrase table only ever matches one
    /// pattern per utterance in practice; declared as an array on
    /// `ConversationUnderstanding` for future richer reasoners that might
    /// genuinely detect more than one.
    static func explicitConstraints(dialogueAct: DialogueAct, lowerTranscript: String?) -> [ExplicitConstraint] {
        guard dialogueAct == .constraint || dialogueAct == .prohibition, let text = lowerTranscript else { return [] }
        if text.contains("wait for") { return [.waitForConfirmation] }
        if text.contains("just answer") || text.contains("only answer") { return [.answerOnly] }
        if text.contains("just explain") || text.contains("only explain") { return [.explainOnly] }
        if text.contains("keep it as") || text.contains("keep everything as") { return [.keepExistingState] }
        if text.contains("change") || text.contains("modify") { return [.doNotModify] }
        return [.doNotAct]
    }

    /// P2-M5V7 §5 — grounded, never invented. `context.failureEvidence`
    /// is `nil` for every currently-real outcome in this codebase (no Go
    /// template carries structured failure evidence today) — this
    /// reasoner honestly reflects that by returning `.unknown` in every
    /// real case; `.known` only appears when a caller (a future runtime
    /// field, or a test/harness fixture demonstrating the path) actually
    /// supplies evidence.
    static func failureReason(actionExecutionState: ActionExecutionState, context: ConversationContext) -> FailureReason {
        guard actionExecutionState == .executedFailed else { return .unknown }
        guard let evidence = context.failureEvidence, !evidence.isEmpty else { return .unknown }
        return .known(type: "runtime-reported", evidence: evidence)
    }

    /// P2-M5V7 §6 — deliberately conservative: a GENERIC execution
    /// failure (`.executionFailed`, no further signal) is `.unknown`,
    /// never `.allowed` — §6's own explicit "do NOT infer retryability
    /// from generic execution failure." A more SPECIFIC "not available
    /// right now" signal (`.capabilityUnavailable`/`.policyUnavailable`)
    /// honestly implies trying again later could plausibly help, so
    /// those may read `.allowed` — still gated on `context.isRetryable`
    /// (the existing, unchanged P2-M5V5 structural retryability fact)
    /// agreeing.
    static func retryability(actionExecutionState: ActionExecutionState, context: ConversationContext, failureReason: FailureReason) -> Retryability {
        guard actionExecutionState == .executedFailed else { return .unknown }
        guard context.isRetryable else { return .notAllowed }
        switch context.responseFamily {
        case .capabilityUnavailable, .policyUnavailable:
            return .allowed
        default:
            return .unknown
        }
    }

    private static func registerRecommendation(lowerTranscript: String?) -> SocialRegister? {
        guard let text = lowerTranscript else { return nil }
        if professionalCueWords.contains(where: { text.contains($0) }) { return .professional }
        if casualCueWords.contains(where: { text.contains($0) }) { return .casualFriendly }
        return nil
    }
}

/// P2-M5V6 §6 / P2-M5V7 §8/§9 STAGE B interface/contract stub — NOT wired
/// to any real network provider this milestone. Exists so
/// `ConversationReasoning`'s contract is proven swappable (any future
/// provider satisfying this protocol slots in with zero changes to
/// `ConversationalResponsePresenter`) without this milestone actually
/// selecting or calling one. A real implementation would request a
/// STRUCTURED result matching `ConversationUnderstanding` (§9: "do NOT
/// ask the model for unrestricted free-form analysis") and validate it
/// before returning — this stub always returns `.minimal` (maximum
/// uncertainty), so every caller in this codebase already treats it as
/// "prefer the deterministic path." No API key, SDK, or network
/// dependency exists anywhere in this codebase for this — per §8's own
/// "if no approved model/provider is currently available, implement the
/// provider interface... and STOP before adding a random vendor."
public struct LLMConversationReasoner: ConversationReasoning {
    public init() {}

    public func understand(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        acoustics: AcousticConversationFeatures, explicitUserStatements: [String]
    ) -> ConversationUnderstanding {
        .minimal
    }
}

/// Final Architectural Invariants §4 — "complete fallback chain: LLM
/// conversation understanding → deterministic conversation understanding."
/// A real, testable composite mirroring `FallbackSpeechSynthesizer`'s
/// already-proven pattern: try `primary`, and whenever its result reads
/// as too uncertain to trust (`uncertainty >= uncertaintyThreshold` —
/// `LLMConversationReasoner`'s stub always reports `1.0`, i.e. "nothing
/// useful here"), use `secondary` instead. `ConversationReasoning.understand`
/// is non-throwing by design (§6 of P2-M5V6: no conforming implementation
/// performs real I/O yet), so "failure" for a reasoner is expressed as
/// high uncertainty, not a thrown error — this composite is how that
/// signal actually produces a fallback rather than silently degrading
/// quality with no recourse.
public struct FallbackConversationReasoning: ConversationReasoning {
    private let primary: ConversationReasoning
    private let secondary: ConversationReasoning
    private let uncertaintyThreshold: Double

    public init(primary: ConversationReasoning, secondary: ConversationReasoning, uncertaintyThreshold: Double = 0.9) {
        self.primary = primary
        self.secondary = secondary
        self.uncertaintyThreshold = uncertaintyThreshold
    }

    public func understand(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        acoustics: AcousticConversationFeatures, explicitUserStatements: [String]
    ) -> ConversationUnderstanding {
        let result = primary.understand(transcript: transcript, recentTurns: recentTurns, context: context, acoustics: acoustics, explicitUserStatements: explicitUserStatements)
        guard result.uncertainty < uncertaintyThreshold else {
            return secondary.understand(transcript: transcript, recentTurns: recentTurns, context: context, acoustics: acoustics, explicitUserStatements: explicitUserStatements)
        }
        return result
    }
}
