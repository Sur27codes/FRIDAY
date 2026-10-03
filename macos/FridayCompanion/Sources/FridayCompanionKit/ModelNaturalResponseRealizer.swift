import Foundation

/// P2-M5V8 §2/§6 STAGE B — a real `NaturalConversationRealizing`
/// implementation backed by `ConversationModelRequestExecutor`. Only ever
/// extracts `text` from the model's structured response (§8: "authoritative
/// truth still comes from local verified context" — `socialRegister`/
/// `humorUsed`/`prosodyIntent`/`responseGoal` in the wire response are
/// accepted for diagnostics only, never used to override the LOCAL
/// `NaturalResponsePlan` already computed before this type is even
/// called). Returns `nil` (the established, first-class "defer to the
/// next fallback tier" signal) on every failure path — not configured,
/// timeout, transport error, schema violation, or an empty/oversized
/// text field.
public final class ModelNaturalResponseRealizer: NaturalConversationRealizing, @unchecked Sendable {
    private let executor: ConversationModelRequestExecutor
    private let config: ConversationModelConfig
    private let diagnostics: WakeDiagnosticsRecorder?

    public init(client: ConversationModelRequesting = URLSessionConversationModelClient(), config: ConversationModelConfig, diagnostics: WakeDiagnosticsRecorder? = nil) {
        self.executor = ConversationModelRequestExecutor(client: client, config: config)
        self.config = config
        self.diagnostics = diagnostics
    }

    public func cancelOutstanding() {
        executor.cancelOutstanding()
    }

    public func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
        guard config.isConfigured else {
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .notConfigured)
            return nil
        }
        guard let requestBody = Self.buildRequest(context: context, understanding: understanding, plan: plan, recentTurns: recentTurns, avoiding: avoiding, config: config) else {
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .unknownFailure("request body could not be built (oversized context or encoding failure)"))
            return nil
        }
        // P2-M5V8.1-O.4 §3 — same request-byte instrumentation as the
        // reasoner and unified paths.
        diagnostics?.recordRequestBytes(stage: "realize", requestBody.count)
        // P2-M5V8.1-O.6 §5/§6 — same history-cost instrumentation as the
        // reasoner and unified paths, for the paired-profile comparison.
        let realizerHistory = ConversationModelLimits.historyStats(for: recentTurns)
        diagnostics?.recordHistoryStats(stage: "realize", turnCount: realizerHistory.turnCount, bytes: realizerHistory.bytes)

        let start = Date()
        let outcome = executor.executeDetailed(requestBody: requestBody)
        let responseData = outcome.data
        let latencyMs = Date().timeIntervalSince(start) * 1000
        // P2-M5V8.1-O.4 §3/§4 — the SAME generic structural decode
        // diagnostic (byte counts, token usage, finishReason).
        if let responseData {
            diagnostics?.recordStageDecodeDiagnostic(stage: "realize", ConversationModelRequestBuilder.diagnoseUnifiedDecode(responseData, as: ModelRealizationWire.self))
        }

        // P2-M5V8.1-S §1 — same fix as `ModelConversationReasoner.understand`:
        // `succeeded` is recorded exactly once, after decode, meaning
        // "this stage produced a genuinely usable result" — never merely
        // "the HTTP transport returned a body." §2/§3/§9 of P2-M5V8.1-S2:
        // each rejection branch also records the exact stage.
        guard let responseData else {
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: ProviderStageOutcome.classifyTransportFailure(outcome.failureDetail))
            return nil
        }
        guard let wire = ConversationModelRequestBuilder.decodeChatCompletion(responseData, as: ModelRealizationWire.self) else {
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelSchemaViolation(stage: "realize")
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: ConversationModelRequestBuilder.classifyDecodeFailure(responseData, as: ModelRealizationWire.self))
            return nil
        }
        guard let text = ConversationModelSchema.realizedText(from: wire) else {
            diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: false)
            diagnostics?.recordModelSchemaViolation(stage: "realize")
            diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .semanticValidationFailure)
            return nil
        }
        diagnostics?.recordModelProviderRequest(stage: "realize", latencyMs: latencyMs, succeeded: true)
        diagnostics?.recordProviderStageOutcome(stage: "realize", outcome: .success)
        // P2-M5V8.1-O.5 §4 — same output-cost instrumentation the unified
        // path records, so the two-stage path's actual response length is
        // comparable for the SAME turn/scope class.
        diagnostics?.recordResponseCharacterCount(stage: "realize", text.count)
        return text
    }

    /// §5/§17: `authoritativeFacts` and the already-computed, LOCAL
    /// `plan`/`understanding` are handed to the model as read-only
    /// context to speak intelligently ABOUT — never as fields it can
    /// redefine. §6's own "avoiding" repetition hint is passed through so
    /// the model can vary phrasing the same way the deterministic
    /// realizer already does.
    private static func buildRequest(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?, config: ConversationModelConfig) -> Data? {
        struct PlanWire: Encodable {
            let socialRegister: String; let formality: Double; let warmth: Double; let humorAllowance: Bool; let humorStrength: Double; let verbosity: String; let urgency: Double
        }
        struct AuthoritativeFactsWire: Encodable {
            let wasSuccess: Bool; let responseFamily: String; let actionExecutionState: String; let retryability: String
            // P2-M5V8.1-S §13/§14/§15 — the realizer previously had NO
            // access to `failureReason` at all, so an `explanationRequest`
            // turn had nothing grounded to explain, and a candidate could
            // not be checked against the real cause. Now included exactly
            // as `ResponseValidation`'s own guards read it (§19).
            let failureReason: String
        }
        // P2-M5V8.1-S3 §3/§4/§5/§19 — the bounded conversational context
        // frame: active topic/artifact/turn-relation, all LOCALLY/
        // authoritatively determined already (never redefinable by the
        // model — see `ConversationalResponsePresenter.authoritative`),
        // handed over as read-only continuity hints so the realizer can
        // actually USE them instead of restarting the conversation each
        // turn. Never the previous user utterance's raw text beyond the
        // already-bounded `recentAssistantResponses`/`avoidRepeatingText`
        // this codebase already sends — no new unbounded transcript data.
        struct ArtifactWire: Encodable { let kind: String; let requestedStyle: String? }
        struct RequestPayload: Encodable {
            let authoritativeFacts: AuthoritativeFactsWire
            let plan: PlanWire
            let dialogueAct: String
            // P2-M5V8.1-S §12 — "earlier"/"new"/nil, parsed from the
            // correction's own wording (`DeterministicConversationReasoner.referentialDirection`)
            // — grounds a `.correction` turn's realization in WHICH prior
            // item is meant, instead of leaving the model to invent one.
            let correctionTarget: String?
            let turnRelation: String
            let activeTopic: String
            let artifact: ArtifactWire?
            let pragmaticResponseActSuggestion: String?
            let avoidRepeatingText: String?
            let recentAssistantResponses: [String]
        }
        let payload = RequestPayload(
            authoritativeFacts: AuthoritativeFactsWire(
                wasSuccess: context.wasSuccess, responseFamily: String(describing: context.responseFamily),
                actionExecutionState: String(describing: understanding.actionExecutionState), retryability: String(describing: understanding.retryability),
                failureReason: String(describing: understanding.failureReason)
            ),
            plan: PlanWire(
                socialRegister: String(describing: plan.socialRegister), formality: plan.formality, warmth: plan.warmth,
                humorAllowance: plan.humorAllowance, humorStrength: plan.humorStrength, verbosity: String(describing: plan.verbosity), urgency: plan.urgency
            ),
            dialogueAct: String(describing: understanding.dialogueAct),
            correctionTarget: understanding.correctionTarget,
            turnRelation: String(describing: understanding.turnRelation),
            activeTopic: String(describing: understanding.activeTopic),
            artifact: understanding.artifactContext.map { ArtifactWire(kind: String(describing: $0.kind), requestedStyle: $0.requestedStyle.map { String(describing: $0) }) },
            pragmaticResponseActSuggestion: understanding.pragmaticResponseAct.map { String(describing: $0) },
            // P2-M5V8.1 §20: bounded — never the full memory store.
            avoidRepeatingText: avoiding.map { ConversationModelLimits.truncated($0, to: ConversationModelLimits.maxCharactersPerHistoricalTurn) },
            recentAssistantResponses: recentTurns.suffix(ConversationModelLimits.maxRecentTurns).map { ConversationModelLimits.truncated($0.responseText, to: ConversationModelLimits.maxCharactersPerHistoricalTurn) }
        )
        guard let payloadData = try? JSONEncoder().encode(payload), let payloadJSON = String(data: payloadData, encoding: .utf8) else { return nil }
        return ConversationModelRequestBuilder.encode(
            systemPolicy: ConversationModelPersona.realizationSystemPolicy + "\nRespond with JSON matching: {text, responseGoal, socialRegister, humorUsed, prosodyIntent}. \"text\" is the only field that will actually be spoken; keep it natural and match \"plan\". Never state or imply anything about authoritativeFacts other than what they already say — you may not claim success, a cause, or retry support beyond what authoritativeFacts and plan already establish. If dialogueAct is \"correction\" and correctionTarget is \"earlier\", refer to the EXISTING previously-established item — never say \"new\"/\"new one\"/\"brand new\" or imply a fresh item was just created. If dialogueAct is \"explanationRequest\", your job is to EXPLAIN, in plain language, the failureReason/actionExecutionState already given in authoritativeFacts (this turn is a request to explain the PRIOR outcome, not a new request to reject) — if failureReason is \"unknown\", say plainly that the cause isn't known yet; never invent a specific cause (network/server/internal/permission/timeout) that authoritativeFacts does not state. \"turnRelation\"/\"activeTopic\"/\"artifact\"/\"pragmaticResponseActSuggestion\" describe the conversational continuity already established locally — if turnRelation is \"continuation\", react to the SAME subject as the recent responses, don't treat this as an unrelated update; if dialogueAct is \"needStatement\" or \"styleRefinement\" and \"artifact\" is present, respond ABOUT that specific artifact (its kind and requestedStyle) — never a generic \"I'm here if you need anything\"; pragmaticResponseActSuggestion is a non-authoritative hint for which kind of response fits, you may deviate from it if the content itself suggests otherwise. If pragmaticResponseActSuggestion is \"commiserate\" (the user reported a problem or a negative situation), acknowledge the problem plainly — never praise, celebrate, or say the situation/news is good, never say \"that's good to hear\" or similar, and never imply it is already resolved or fine; stay concise, don't invent a cause, and only offer to help if that's already consistent with the rest of this context.",
            userPayloadJSON: payloadJSON, modelName: config.modelName, temperature: config.realizationTemperature,
            tokenLimitEncoding: config.tokenLimitEncoding, temperatureEncoding: config.temperatureEncoding
        )
    }
}
