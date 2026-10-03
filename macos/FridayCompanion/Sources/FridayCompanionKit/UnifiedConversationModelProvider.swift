import Foundation

/// P2-M5V8.1-O §1/§2 — the ONE-CALL protocol: a single provider round
/// trip that returns BOTH a non-authoritative reasoning proposal (a
/// `ConversationUnderstanding` — same type the two-stage `ConversationReasoning`
/// protocol already produces, so every downstream consumer, especially
/// `ConversationalResponsePresenter.authoritative(_:context:...)`, needs
/// zero new code to consume it) and candidate response text, or `nil` on
/// ANY failure (§24: full fallback, never a partial result — see
/// `ConversationModelSchema.unified(from:)`'s own doc comment).
///
/// Deliberately NOT built by widening `ConversationReasoning`/
/// `NaturalConversationRealizing` (§0-style preservation: those two
/// protocols and every existing implementation — including
/// `DeterministicConversationReasoner`/`DeterministicNaturalResponseRealizer`,
/// which the one-call path still reuses for its own LOCAL preliminary
/// pass and its fallback wording — stay byte-identical). This is an
/// entirely separate, additive abstraction that `ConversationalResponsePresenter`
/// opts into explicitly via `withUnifiedModelProvider(config:...)`,
/// mirroring the existing `withModelProvider(config:...)` factory exactly.
public protocol UnifiedConversationProviding: Sendable {
    /// - Parameters:
    ///   - localUnderstanding: the ALREADY-COMPUTED, purely local
    ///     (`DeterministicConversationReasoner`) understanding for this
    ///     turn — sent as read-only context (turn relation/active topic/
    ///     active artifact/pragmatic-act suggestion/correction target),
    ///     the SAME bounded continuity signals the old two-stage realizer
    ///     already received, never as something the model can redefine.
    ///   - localPlan: the ALREADY-COMPUTED, purely local tone/register
    ///     plan derived from `localUnderstanding` — a safe, already-
    ///     proven-correct BASELINE the candidate wording should be
    ///     consistent with (§17: "reasoning schema reliability matters,
    ///     while candidate wording still needs enough natural variation" —
    ///     this baseline is what makes that trade-off safe even before
    ///     the model's own reasoning proposal is known).
    /// - Returns: `nil` on ANY failure (not configured, transport,
    ///   timeout, cancelled, decode, schema, or oversized request) — the
    ///   caller falls back to fully local computation for the WHOLE turn,
    ///   never a second provider call to "repair" a rejected attempt
    ///   (§7: "do NOT immediately make a second model call").
    func propose(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        localUnderstanding: ConversationUnderstanding, localPlan: NaturalResponsePlan, avoiding: String?
    ) -> (understanding: ConversationUnderstanding, candidateText: String)?

    /// Externally callable cancellation (§25) — mirrors `ModelConversationReasoner.cancelOutstanding()`/
    /// `ModelNaturalResponseRealizer.cancelOutstanding()` exactly, so
    /// barge-in/interruption handling needs no new concept: a cancelled
    /// request's late callback can never smuggle a stale result into a
    /// caller that already gave up (see `ConversationModelRequestExecutor.executeDetailed`'s
    /// own doc comment — the SAME executor this type is built on).
    func cancelOutstanding()
}

/// P2-M5V8.1-O §12 — the ONE combined system prompt, clearly sectioned
/// per §12's own explicit requirement. Reuses `ConversationModelPersona.sharedAuthorityRules`
/// UNCHANGED (never a second, potentially-drifting copy of the truth-
/// boundary/injection-resistance rules) and reuses the SAME closed
/// vocabulary `reasoningSystemPolicy` already teaches, and the SAME
/// persona/wording guidance `realizationSystemPolicy` already teaches —
/// this is a genuine MERGE, not a parallel prompt design, so the one-call
/// path can never drift from what the two-stage path already teaches the
/// model about FRIDAY's voice or its closed enum vocabularies.
extension ConversationModelPersona {
    static let unifiedSystemPolicy = """
    You are FRIDAY, performing BOTH steps of understanding a user's turn and \
    responding to it, in ONE response. Produce a single JSON object with exactly \
    two top-level keys, "reasoning" and "response".

    SECTION A — STRUCTURED ANALYSIS ("reasoning", non-authoritative — your own \
    classification, which the system may adjust before anything is spoken): \
    "reasoning.interactionMode" is EXACTLY ONE of these 6 strings, spelled and \
    cased exactly as shown: "actionRequest", "informationRequest", "conversational", \
    "correction", "constraint", "clarification". "reasoning.dialogueAct" is EXACTLY \
    ONE of these 20 strings, spelled and cased exactly as shown: "command", \
    "request", "question", "statement", "personalUpdate", "acknowledgement", \
    "correction", "clarification", "constraint", "prohibition", "permissionResponse", \
    "followUp", "explanationRequest", "confirmationRequest", "socialRemark", \
    "jokeOrPlayfulRemark", "greeting", "farewell", "needStatement", "styleRefinement". \
    Never invent a different string for either field — an unrecognized value \
    discards your entire response. Sharing news or an observation ("I finally fixed \
    that bug," "production is down") is dialogueAct "personalUpdate"/"statement" \
    with interactionMode "conversational," never a request to perform an action, \
    even if a runtime result happens to be attached to this turn. An instruction \
    about how you should behave ("don't touch anything yet") is dialogueAct \
    "constraint"/"prohibition" with interactionMode "constraint," never a claim an \
    action occurred. A follow-up like "no, the other one" is dialogueAct \
    "correction" with interactionMode "correction." "Why?" right after a result is \
    dialogueAct "explanationRequest" with interactionMode "informationRequest." A \
    stated NEED or INTENTION ("I need to email my professor") is dialogueAct \
    "needStatement" — a wish for help, never a completed action. A request to \
    adjust TONE/STYLE of something already discussed ("make it less formal") is \
    dialogueAct "styleRefinement." Classify based on the general PATTERN, not exact \
    wording you've seen before.

    SECTION B — USER RESPONSE ("response.text" — the ONLY field that will actually \
    be spoken; everything else in "response" is diagnostic only): speak as FRIDAY, \
    someone the user knows well — friendly, warm, intelligent, relaxed, confident, \
    natural, socially aware, occasionally subtly playful when it genuinely fits — \
    never corporate, never customer-service-like, never childish, never sycophantic, \
    never verbose for its own sake. Avoid phrasing like "your request has been \
    successfully completed." Prefer brevity: 2-12 words for a simple conversational \
    reply, one sentence for a simple result. Do not begin every reply with the same \
    acknowledgement word — vary this naturally. Humor, when "plan" allows it, should \
    be dry, short, understated — never an exclamation or emoji. Respond to what the \
    user JUST said, using the supplied conversational context (recent turns, active \
    topic, active artifact/style, pragmatic-act suggestion) when genuinely relevant — \
    do not restart the conversation, and do not ask for information the context \
    already supplies. If the current turn continues or reacts to something already \
    discussed, react to THAT — a generic "thanks for telling me" loses the \
    relationship between turns. If asked to modify an existing artifact (a draft, an \
    email, a note) or its style, respond about THAT artifact specifically. If the \
    user reports a problem or a negative state (or "pragmaticResponseActSuggestion" \
    is "commiserate"), acknowledge the problem plainly — never praise, celebrate, or \
    imply it's already resolved or fine; don't invent a cause; offer help only if \
    contextually consistent; humor stops immediately once the user signals seriousness \
    (e.g. "I'm serious"). If the user reports a success, react to \
    the success rather than reflexive praise ("Great job!"/"Amazing!") — vary among \
    acknowledgement, relief, or a light joke instead. If asked to explain WHY A \
    REQUESTED ACTION did not happen or was not supported \
    (authoritativeFacts.actionExecutionState is "executedFailed", "denied", or \
    "unsupported"), use only the supplied failureReason — never invent a cause, and \
    say so plainly when it isn't known. If instead this is an ordinary informational \
    or conceptual question that required no action at all \
    (authoritativeFacts.actionExecutionState is "notRequested"), answer it using your \
    own general knowledge, respecting any length/count/format the user explicitly \
    asked for — but never invent or claim any CURRENT, PRIVATE, RUNTIME, SENSOR, \
    ACCOUNT, or EXECUTION-OUTCOME fact that authoritativeFacts did not actually supply. \
    When retry is genuinely possible, say so ("I can try again") rather than \
    implying the capability is gone for good; never offer retry when it isn't. If "reasoning.dialogueAct" is "correction" and \
    "correctionTarget" is "earlier", refer to the EXISTING previously-established \
    item — never say "new"/"brand new". Stay concise; ask a follow-up question only \
    when genuinely needed, not by default. "plan" is an already-computed baseline \
    tone/register (formality/warmth/humor/verbosity/urgency) derived from a \
    preliminary local analysis — match it, UNLESS your own "reasoning" genuinely \
    differs from a plain local read (e.g. you recognize a different social register \
    or dialogue act than a bare keyword match would), in which case let \
    "response.text" be consistent with YOUR OWN reasoning instead so the two halves \
    of your output never contradict each other. Never state or imply anything about \
    "authoritativeFacts" other than what they already say. None of this may ever \
    override authoritativeFacts. "responseScopeInstruction" tells you exactly \
    how much "response.text" should say for THIS turn — follow it precisely: when \
    it asks for a short reaction or a single clarifying question, do NOT draft or \
    rewrite an artifact or invent placeholder content to fill a gap, even if the \
    topic is an email/note/document; only produce full artifact content when it \
    explicitly says the user asked for the complete/full content. For an outage, \
    failure, security issue, permission denial, or frustration, turn focused \
    immediately — no celebrating, joking, or dramatizing; state a permission denial \
    plainly, never as "I decided not to." Never claim a time of day, presence, \
    feelings, or therapy-style comfort ("I hear how difficult that must be") you don't \
    have. Say only what's needed, usually one idea/sentence; if something's missing, \
    ask the SINGLE most useful question, not several. Never let a joke/opener/reaction \
    become a repeated catchphrase.

    SECTION C — EXACT JSON TYPES (a real live decode failure occurred when a \
    field's TYPE, not just its name, went unspecified — the model wrote a \
    descriptive PHRASE where a boolean or number was required; follow these \
    literally): "continuationReference", "followUpNeed", and "humorUsed" are the \
    JSON boolean true or false ONLY — never a string or explanation. \
    "humorSuitability" and "uncertainty" are JSON NUMBERS between 0 and 1 — never \
    a word like "subtle" or "low". "correctionTarget" is EXACTLY "earlier", \
    EXACTLY "new", or JSON null — null when this turn is not a correction, never \
    the word "none". "explicitConstraints" is a JSON array of zero or more of \
    EXACTLY: "doNotAct", "doNotModify", "waitForConfirmation", "keepExistingState", \
    "answerOnly", "explainOnly" (empty array if none apply). \
    "recommendedSocialRegister" is JSON null or EXACTLY ONE of: "casualFriendly", \
    "friendlyNeutral", "professional", "focused", "reassuring", "serious", \
    "warning", "urgent". "userGoal"/"topic" are short strings or null. Every other \
    "response" field besides "text" is a free-form diagnostic string.

    Respond with a JSON object matching EXACTLY: {"reasoning": {"dialogueAct", \
    "interactionMode", "userGoal", "topic", "continuationReference", \
    "correctionTarget", "explicitConstraints", "recommendedSocialRegister", \
    "humorSuitability", "followUpNeed", "uncertainty"}, "response": {"text", \
    "responseGoal", "socialRegister", "humorUsed", "prosodyIntent"}} — using EXACTLY \
    the JSON types SECTION C just specified for every field — no prose, no \
    markdown, no extra top-level keys.
    \(sharedAuthorityRules)
    """
}

/// P2-M5V8.1-O §1 — the real, working ONE-CALL provider implementation.
/// Built on the SAME `ConversationModelRequestExecutor` (unchanged) the
/// two-stage `ModelConversationReasoner`/`ModelNaturalResponseRealizer`
/// already use — identical bounded-deadline, cancellation, and stale-
/// result-rejection semantics (§25), just issuing ONE request instead of
/// coordinating two independent ones.
///
/// **P2-M5V8.1-O.1 root-cause note.** A live owner run against a real,
/// working, credentialed OpenAI endpoint found the two-stage reasoner
/// and realizer calls succeeding 100% while all 21 unified calls failed
/// with a generic "provider unavailable/failed" — with the SAME
/// endpoint/model/key/process. The failing attempts took ~3.8-6s, well
/// under the shared `config.overallDeadline` (8s default), which rules
/// out a client-side timeout: the request completed and a real HTTP
/// response came back. Structural analysis of the request builder found
/// the unified path was reusing `ConversationModelLimits.maxCompletionTokens`
/// (400 — identical to each single-stage call) UNCHANGED, even though a
/// unified response combines TWO structured objects (`reasoning` +
/// `response`) into one JSON document. OpenAI's own documentation
/// describes exactly this failure mode for `response_format: json_object`
/// against a token-limited request: the model can be cut off
/// (`finish_reason: "length"`) before producing any visible content —
/// and for reasoning-capable models specifically, PART of that SAME
/// budget can be consumed by invisible reasoning tokens before any
/// visible output begins, making a combined/larger schema materially
/// more likely to exhaust the budget than either smaller single-stage
/// schema. Before this pass, TWO separate code-level blind spots would
/// have made this failure invisible even with real credentials: (1)
/// `ChatCompletionEnvelope.Choice.Msg.content` was a non-optional
/// `String`, so a standards-compliant `"content": null` response (which
/// is exactly what OpenAI documents for this scenario) failed envelope
/// decoding ENTIRELY rather than being recognized as "truncated," and
/// (2) `finish_reason` was never decoded at all, so there was no way to
/// distinguish "the model was cut off by the token budget" from any
/// other decode failure. This pass fixes both blind spots (`ConversationModelClient.swift`:
/// nullable content + `finish_reason` decoding + the new
/// `.responseTruncatedByLength` outcome) AND gives the unified path its
/// own larger, still-bounded budget (`ConversationModelLimits.maxUnifiedCompletionTokens`).
/// **This diagnosis is evidence-based (latency profile + structural code
/// audit + OpenAI's own documented `json_object`/reasoning-model
/// behavior), not live-confirmed** — no live provider credentials exist
/// in this sandbox to reproduce the exact HTTP response body. The new
/// `.responseTruncatedByLength`/`.providerRejected` diagnostics exist
/// precisely so the OWNER's next live rerun proves (or disproves) this
/// diagnosis directly instead of remaining a guess.
public final class ModelUnifiedConversationProvider: UnifiedConversationProviding, @unchecked Sendable {
    private let executor: ConversationModelRequestExecutor
    private let config: ConversationModelConfig
    private let diagnostics: WakeDiagnosticsRecorder?
    /// P2-M5V8.1-O.2 §5 — `false` for every existing call site (including
    /// `withUnifiedModelProvider`'s own default), so raw model content is
    /// NEVER stored in `WakeDiagnosticsSnapshot.lastUnifiedDecodeDiagnostic.sanitizedContentPreview`
    /// unless a caller explicitly opts in. Only `runProviderUnifiedSmoke()`
    /// does — its own prompt/scenario is hard-coded and non-sensitive.
    private let includeContentPreviewInDiagnostics: Bool

    public init(
        client: ConversationModelRequesting = URLSessionConversationModelClient(), config: ConversationModelConfig,
        diagnostics: WakeDiagnosticsRecorder? = nil, includeContentPreviewInDiagnostics: Bool = false
    ) {
        self.executor = ConversationModelRequestExecutor(client: client, config: config)
        self.config = config
        self.diagnostics = diagnostics
        self.includeContentPreviewInDiagnostics = includeContentPreviewInDiagnostics
    }

    public func cancelOutstanding() {
        executor.cancelOutstanding()
    }

    public func propose(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        localUnderstanding: ConversationUnderstanding, localPlan: NaturalResponsePlan, avoiding: String?
    ) -> (understanding: ConversationUnderstanding, candidateText: String)? {
        diagnostics?.recordProviderArchitecture("unifiedOneCall")
        // P2-M5V8.1-O.6 §3 — recorded UNCONDITIONALLY, before any request
        // is even attempted: this is a LOCAL fact (§6 of O.5 — never
        // derived from the model), so it is always knowable regardless of
        // what happens to the request afterward. Fixes the live-observed
        // "LONG-FORM DIAGNOSTIC HOLE": every early-return branch below used
        // to leave `lastUnifiedResponseScope` at `nil` on ANY failure, so a
        // rejected/failed long-form attempt (the exact case a developer
        // most needs visibility into) silently showed "observedScope=n/a"
        // even though the scope that was ASKED for was never in doubt.
        diagnostics?.recordResponseScope(String(describing: localUnderstanding.responseScope))
        guard config.isConfigured else {
            diagnostics?.recordProviderCallCount(0)
            diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: .notConfigured)
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .notConfigured)
            return nil
        }
        guard let requestBody = Self.buildRequest(
            transcript: transcript, recentTurns: recentTurns, context: context,
            localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: avoiding, config: config
        ) else {
            diagnostics?.recordProviderCallCount(0)
            diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: .unknownFailure("request body could not be built (oversized context or encoding failure)"))
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .unknownFailure("request body could not be built (oversized context or encoding failure)"))
            return nil
        }
        // P2-M5V8.1-O.4 §3 — same request-byte instrumentation as the
        // two-stage paths, for the request-cost comparison
        // `provider-latency-profile` performs.
        diagnostics?.recordRequestBytes(stage: "unified", requestBody.count)
        // P2-M5V8.1-O.6 §5/§6 — history-cost instrumentation, so
        // `provider-latency-paired-profile` can correlate latency against
        // history depth independently of total request bytes.
        let unifiedHistory = ConversationModelLimits.historyStats(for: recentTurns)
        diagnostics?.recordHistoryStats(stage: "unified", turnCount: unifiedHistory.turnCount, bytes: unifiedHistory.bytes)

        let start = Date()
        // P2-PROD-BOOTSTRAP-R2.5 §1 — the ONE real network round trip
        // this whole one-call turn makes, bracketed for the sanitized
        // per-turn timeline (never the request/response body itself).
        diagnostics?.markTurnTiming(\.providerRequestStarted)
        let outcome = executor.executeDetailed(requestBody: requestBody)
        diagnostics?.markTurnTiming(\.providerResponseReceived)
        let responseData = outcome.data
        let latencyMs = Date().timeIntervalSince(start) * 1000
        // P2-M5V8.1-O §30 — recorded unconditionally right here: EXACTLY
        // one physical HTTP attempt was made above, regardless of what
        // happens to it from this point on (success, decode failure, or
        // semantic rejection one layer up in `ConversationalResponsePresenter`).
        diagnostics?.recordProviderCallCount(1)

        guard let responseData else {
            let classified = ProviderStageOutcome.classifyTransportFailure(outcome.failureDetail)
            diagnostics?.recordModelProviderRequest(stage: "understand", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: classified)
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: classified)
            return nil
        }
        // P2-M5V8.1-O.2 §3/§11 — computed and recorded UNCONDITIONALLY
        // whenever a real response body exists (success OR failure), so
        // `finishReason`/token usage/structural JSON facts are always
        // visible to `provider-unified-smoke` — never only on failure.
        diagnostics?.recordUnifiedDecodeDiagnostic(
            ConversationModelRequestBuilder.diagnoseUnifiedDecode(responseData, as: ModelUnifiedWire.self, includeContentPreview: includeContentPreviewInDiagnostics)
        )
        guard let wire = ConversationModelRequestBuilder.decodeChatCompletion(responseData, as: ModelUnifiedWire.self) else {
            let classified = ConversationModelRequestBuilder.classifyDecodeFailure(responseData, as: ModelUnifiedWire.self)
            diagnostics?.recordModelProviderRequest(stage: "understand", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelSchemaViolation(stage: "understand")
            diagnostics?.recordModelSchemaViolation(stage: "realize")
            diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: classified)
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: classified)
            return nil
        }
        // P2-M5V8.1-O.6 §3 — recorded here, BEFORE the semantic-validation
        // guard below, using the RAW decoded `wire.response.text` — the
        // other half of the same diagnostic hole: a long-form draft that
        // decodes as syntactically/structurally valid JSON but then gets
        // semantically REJECTED (e.g. exceeds `DeterministicResponsePresenter.maxSpokenLength`,
        // a real, live-plausible outcome for a genuine full-length email
        // draft — see this pass's own STOP report for the measured
        // implication) used to leave `lastUnifiedResponseCharacterCount`
        // at `nil` too, hiding the one fact (the model DID generate
        // something, and how long it was) that would explain the latency
        // without explaining anything about WHY it was rejected.
        diagnostics?.recordResponseCharacterCount(stage: "unified", wire.response.text.count)
        guard let unified = ConversationModelSchema.unified(from: wire) else {
            // §24 — EITHER half being invalid fails the WHOLE call; no
            // partial success is ever reported or used.
            diagnostics?.recordModelProviderRequest(stage: "understand", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelSchemaViolation(stage: "understand")
            diagnostics?.recordModelSchemaViolation(stage: "realize")
            diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: .schemaValidationFailure("unified response failed reasoning or response validation"))
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .schemaValidationFailure("unified response failed reasoning or response validation"))
            return nil
        }
        // P2-M5V8.1-O §9 — the SAME per-stage recording calls the
        // two-stage path already makes, called TWICE from this ONE
        // physical response — a deliberate, documented compatibility
        // view (see `WakeDiagnosticsSnapshot.lastProviderArchitecture`),
        // never a claim that two independent network round trips occurred.
        diagnostics?.recordModelProviderRequest(stage: "understand", latencyMs: latencyMs, succeeded: true)
        diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: true)
        diagnostics?.recordProviderStageOutcome(stage: "understand", outcome: .success)
        diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .success)
        // P2-M5V8.1-O.5 §4/§5 / O.6 §3 — `responseScope`/`responseCharacterCount`
        // are now recorded EARLIER (unconditionally at the top, and right
        // after `wire` decodes, respectively) so every failure branch above
        // also gets them — nothing further to record on the success path.
        return unified
    }

    /// P2-M5V8.1-O.5 §6/§12 — turns the locally/authoritatively-derived
    /// `ResponseScope` (never a model-decided field — see `ResponseScope`'s
    /// own doc comment) into the exact compact imperative text
    /// "responseScopeInstruction" carries in the request payload. Kept as
    /// one short sentence per case on purpose (§12: "keep it concise"),
    /// and kept OUTBOUND-ONLY — this only ever narrows what "response.text"
    /// says, never widens/replaces anything `ResponseValidation` already
    /// gates on.
    private static func responseScopeInstruction(for scope: ResponseScope, actionExecutionState: ActionExecutionState) -> String {
        switch scope {
        case .conversationalShort:
            return "Keep the reply short and natural, a brief reaction — do not draft or rewrite any artifact content."
        case .clarifyingQuestion:
            return "The request is missing details needed to act on it. Ask exactly ONE concise clarifying question — never fabricate a placeholder draft to fill the gap."
        case .briefStatus:
            return "State the constraint or status briefly and factually, a short sentence — not an explanation of why, not extra warmth."
        case .briefExplanation:
            // P2-M5V8.1-Q §6/§8 — REAL, forensically-proven fix: the old,
            // single wording ("using only what is already known") was
            // written for explaining a FAILED/UNSUPPORTED action and, read
            // literally for an ordinary general-knowledge question,
            // reinforced the same "I can't help" refusal this pass exists
            // to fix. `actionExecutionState == .notRequested` here means NO
            // action was ever attempted (§3) — this is a genuine
            // informational turn, so the model may draw on its own general
            // knowledge (§9's boundary — never current/private/runtime/
            // account/execution facts — stays enforced by SECTION B above,
            // not by this line).
            return actionExecutionState == .notRequested
                ? "Give a clear, accurate explanation in a sentence or two, drawing on your own general knowledge, and respecting any length/count the user explicitly asked for (e.g. \"two sentences,\" \"three ways\") — do not pad it, and never invent a current, private, runtime, or account-specific fact."
                : "Give a brief, grounded explanation in a sentence or two, using only what is already known — do not pad it or invent detail."
        case .artifactDraft:
            return "Produce the actual artifact draft content being requested."
        case .artifactRewrite:
            return "Produce the actual rewritten artifact content being requested."
        case .longFormRequested:
            return "The user explicitly asked for the complete/full content — full-length generation is appropriate here; do not shorten or truncate it."
        }
    }

    /// P2-M5V8.1-O §14/§15 — ONE coherent payload, built by auditing (not
    /// blindly concatenating) the two old prompts' payloads: the old
    /// reasoner's `conversationContext` (transcript+response+dialogueAct+
    /// responseFamily per recent turn) already carries everything the old
    /// realizer's SEPARATE `recentAssistantResponses`/`avoidRepeatingText`
    /// fields duplicated (the same bounded response texts, just wrapped
    /// again) — so this payload sends `conversationContext` ONCE and
    /// tells the model to avoid repeating a recent turn's own response
    /// text directly in the system prompt, eliminating that duplication
    /// rather than carrying both shapes forward.
    private static func buildRequest(
        transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext,
        localUnderstanding: ConversationUnderstanding, localPlan: NaturalResponsePlan, avoiding: String?, config: ConversationModelConfig
    ) -> Data? {
        struct RecentTurnWire: Encodable {
            let transcript: String?; let response: String; let dialogueAct: String; let responseFamily: String
        }
        struct PlanWire: Encodable {
            let socialRegister: String; let formality: Double; let warmth: Double
            let humorAllowance: Bool; let humorStrength: Double; let verbosity: String; let urgency: Double
        }
        struct AuthoritativeFactsWire: Encodable {
            let wasSuccess: Bool; let responseFamily: String; let isRetryable: Bool; let needsClarification: Bool
            let actionExecutionState: String; let retryability: String; let failureReason: String
        }
        struct ArtifactWire: Encodable { let kind: String; let requestedStyle: String? }
        struct RequestPayload: Encodable {
            let authoritativeFacts: AuthoritativeFactsWire
            let plan: PlanWire
            let conversationContext: [RecentTurnWire]
            let userUtterance: String
            let avoidRepeatingText: String?
            let correctionTarget: String?
            let turnRelation: String
            let activeTopic: String
            let artifact: ArtifactWire?
            let pragmaticResponseActSuggestion: String?
            let responseScopeInstruction: String
        }
        let payload = RequestPayload(
            authoritativeFacts: AuthoritativeFactsWire(
                wasSuccess: context.wasSuccess, responseFamily: String(describing: context.responseFamily),
                isRetryable: context.isRetryable, needsClarification: context.needsClarification,
                actionExecutionState: String(describing: localUnderstanding.actionExecutionState),
                retryability: String(describing: localUnderstanding.retryability),
                failureReason: String(describing: localUnderstanding.failureReason)
            ),
            plan: PlanWire(
                socialRegister: String(describing: localPlan.socialRegister), formality: localPlan.formality, warmth: localPlan.warmth,
                humorAllowance: localPlan.humorAllowance, humorStrength: localPlan.humorStrength,
                verbosity: String(describing: localPlan.verbosity), urgency: localPlan.urgency
            ),
            conversationContext: recentTurns.suffix(ConversationModelLimits.maxRecentTurns).map {
                RecentTurnWire(
                    transcript: $0.transcript.map { ConversationModelLimits.truncated($0, to: ConversationModelLimits.maxCharactersPerHistoricalTurn) },
                    response: ConversationModelLimits.truncated($0.responseText, to: ConversationModelLimits.maxCharactersPerHistoricalTurn),
                    dialogueAct: String(describing: $0.dialogueAct), responseFamily: String(describing: $0.responseFamily)
                )
            },
            userUtterance: ConversationModelLimits.truncated(transcript ?? "", to: ConversationModelLimits.maxTranscriptCharacters),
            avoidRepeatingText: avoiding.map { ConversationModelLimits.truncated($0, to: ConversationModelLimits.maxCharactersPerHistoricalTurn) },
            correctionTarget: localUnderstanding.correctionTarget,
            turnRelation: String(describing: localUnderstanding.turnRelation),
            activeTopic: String(describing: localUnderstanding.activeTopic),
            artifact: localUnderstanding.artifactContext.map { ArtifactWire(kind: String(describing: $0.kind), requestedStyle: $0.requestedStyle.map { String(describing: $0) }) },
            pragmaticResponseActSuggestion: localUnderstanding.pragmaticResponseAct.map { String(describing: $0) },
            responseScopeInstruction: responseScopeInstruction(for: localUnderstanding.responseScope, actionExecutionState: localUnderstanding.actionExecutionState)
        )
        guard let payloadData = try? JSONEncoder().encode(payload), let payloadJSON = String(data: payloadData, encoding: .utf8) else { return nil }
        return ConversationModelRequestBuilder.encode(
            systemPolicy: ConversationModelPersona.unifiedSystemPolicy,
            userPayloadJSON: payloadJSON, modelName: config.modelName, temperature: config.unifiedTemperature,
            tokenLimitEncoding: config.tokenLimitEncoding, temperatureEncoding: config.temperatureEncoding,
            // P2-M5V8.1-O.1 §7/§23 — the root-cause fix: a combined
            // reasoning+response payload gets a LARGER, still-bounded
            // budget than either single-stage call — see
            // `ConversationModelLimits.maxUnifiedCompletionTokens`'s own
            // doc comment.
            completionTokenBudget: ConversationModelLimits.maxUnifiedCompletionTokens,
            // P2-M5V8.1-O.3 §6/§7 — the combined system prompt (teaching
            // BOTH the reasoning vocabulary AND the realization persona,
            // now WITH explicit JSON-type guidance per SECTION C) is
            // larger than either single-stage prompt by design — see
            // `ConversationModelLimits.maxUnifiedSerializedContextBytes`'s
            // own doc comment for why this needed its own ceiling.
            maxSerializedContextBytes: ConversationModelLimits.maxUnifiedSerializedContextBytes
        )
    }
}
