import Foundation

/// P2-M5V6 §1/§28 — the richer orchestrator: `ConversationContextCompiler`
/// → `ResponseStrategyPlanner` → `ConversationReasoning` → `NaturalResponsePlanner`
/// → `NaturalConversationRealizing` (if configured) → `ResponseValidation`
/// → falls back to the wrapped, UNCHANGED `DeterministicResponsePresenter`
/// whenever the natural path has nothing to offer or fails validation.
///
/// This type WRAPS `DeterministicResponsePresenter` by composition, never
/// by inheritance or modification (§0: preserve P2-M5V5 exactly) — with
/// no `naturalRealizer` configured (the default is
/// `DeterministicNaturalResponseRealizer`, itself deterministic/no-LLM),
/// behavior for every family this pass didn't specifically improve is
/// BYTE-IDENTICAL to routing straight through `DeterministicResponsePresenter`,
/// because this type's own fallback path IS that unchanged presenter.
///
/// **Not wired as `WakeCoordinator`'s default `responsePresenter` this
/// milestone** — it is a real, fully tested, standalone component ready
/// to be opted into by a future pass once real owner audition on
/// hardware validates the richer wording (§28's own "quality is the
/// primary product requirement, but reliability must never regress").
public final class ConversationalResponsePresenter: ResponsePresenting, @unchecked Sendable {
    private let base: ResponsePresenting
    private let contextCompiler: ConversationContextCompiling
    private let strategyPlanner: ResponseStrategyPlanning
    private let reasoner: ConversationReasoning
    private let planPlanner: NaturalResponsePlanning
    private let naturalRealizer: NaturalConversationRealizing?
    /// P2-M5V8.1-O §1/§18 — `nil` for every pre-existing configuration
    /// (including the default initializer and `withModelProvider`) —
    /// only `withUnifiedModelProvider` ever sets this, and only when
    /// `config.architecture == .unifiedOneCall`. When set, `response(for:transcript:...)`
    /// takes the ONE-CALL branch instead of the two-stage `reasoner`/
    /// `naturalRealizer` branch; `reasoner`/`naturalRealizer` above still
    /// exist and are still fully wired even in that configuration (see
    /// `withUnifiedModelProvider`'s own doc comment) so nothing about the
    /// two-stage path is ever deleted or made unreachable in code.
    private let unifiedProvider: UnifiedConversationProviding?
    private let memory: ConversationMemoryStoring
    private let persona: FridayPersona
    /// P2-M5V8.1-S2 §18/§19 — optional side-channel for the THREE split
    /// acceptance diagnostics (`schemaValid`/`semanticGroundingValid`/`responseAccepted`).
    /// `nil` by default (every pre-existing call site keeps compiling and
    /// behaving unchanged) — set only by `withModelProvider`, the one
    /// configuration that has a real model candidate worth diagnosing.
    private let diagnostics: WakeDiagnosticsRecorder?

    /// Defaults form the Final Architectural Invariants §4 "complete
    /// fallback chain" FOR REAL, not just theoretically: `reasoner`/
    /// `naturalRealizer` each default to a `Fallback...` composite trying
    /// the (currently-stub) LLM path first and the guaranteed
    /// deterministic path second. Since `LLMConversationReasoner`/
    /// `LLMNaturalResponseRealizer` always defer today (no provider
    /// exists), these defaults are BYTE-IDENTICAL in behavior to passing
    /// the deterministic types directly — this is a zero-behavior-change,
    /// purely architectural completion, ready for the day a real Stage C
    /// provider is plugged into the `primary` side of each composite.
    public init(
        base: ResponsePresenting = DeterministicResponsePresenter(),
        contextCompiler: ConversationContextCompiling = DeterministicConversationContextCompiler(),
        strategyPlanner: ResponseStrategyPlanning = DeterministicResponseStrategyPlanner(),
        reasoner: ConversationReasoning = FallbackConversationReasoning(primary: LLMConversationReasoner(), secondary: DeterministicConversationReasoner()),
        planPlanner: NaturalResponsePlanning = DeterministicNaturalResponsePlanner(),
        naturalRealizer: NaturalConversationRealizing? = FallbackNaturalResponseRealizing(primary: LLMNaturalResponseRealizer(), secondary: DeterministicNaturalResponseRealizer()),
        unifiedProvider: UnifiedConversationProviding? = nil,
        memory: ConversationMemoryStoring = BoundedConversationMemory(),
        persona: FridayPersona = .friday,
        diagnostics: WakeDiagnosticsRecorder? = nil
    ) {
        self.base = base
        self.contextCompiler = contextCompiler
        self.strategyPlanner = strategyPlanner
        self.reasoner = reasoner
        self.planPlanner = planPlanner
        self.naturalRealizer = naturalRealizer
        self.unifiedProvider = unifiedProvider
        self.memory = memory
        self.persona = persona
        self.diagnostics = diagnostics
    }

    /// P2-M5V8 §32 — the explicit, documented way to opt into the model
    /// provider path. NOT the default constructor's behavior (calling
    /// `ConversationalResponsePresenter()` with no arguments never reads
    /// the environment or attempts a network call) — a caller must
    /// explicitly ask for this, matching §32's "must not be a hidden
    /// magic flag." Composes the EXACT SAME `FallbackConversationReasoning`/
    /// `FallbackNaturalResponseRealizing` composites every other
    /// configuration already uses (§0/§2: reuse existing types, no
    /// parallel orchestration) — when `config.isConfigured` is `false`
    /// (no credentials, or `mode == .deterministicOnly`), this is
    /// byte-identical to the plain default configuration.
    public static func withModelProvider(
        config: ConversationModelConfig, client: ConversationModelRequesting = URLSessionConversationModelClient(),
        diagnostics: WakeDiagnosticsRecorder? = nil, memory: ConversationMemoryStoring = BoundedConversationMemory()
    ) -> ConversationalResponsePresenter {
        ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(
                primary: ModelConversationReasoner(client: client, config: config, diagnostics: diagnostics),
                secondary: DeterministicConversationReasoner()
            ),
            naturalRealizer: FallbackNaturalResponseRealizing(
                primary: ModelNaturalResponseRealizer(client: client, config: config, diagnostics: diagnostics),
                secondary: DeterministicNaturalResponseRealizer()
            ),
            memory: memory, diagnostics: diagnostics
        )
    }

    /// P2-M5V8.1-O §1/§18/§39 — the explicit, documented way to opt into
    /// the ONE-CALL architecture. NOT the default constructor's behavior
    /// (mirrors `withModelProvider`'s own "must not be a hidden magic
    /// flag" discipline exactly). When `config.architecture != .unifiedOneCall`
    /// (the fail-closed default — see `ConversationModelArchitecture`'s
    /// own doc comment), this is BYTE-IDENTICAL to `withModelProvider` —
    /// `unifiedProvider` stays `nil`, and every turn takes the unchanged,
    /// still-fully-wired two-stage path. §39: the two-stage `reasoner`/
    /// `naturalRealizer` composites are STILL constructed here (never
    /// removed), so `response(for:transcript:...)`'s fallback-when-
    /// `unifiedProvider` -returns-`nil` branch and any future rollback
    /// both keep working with zero code changes.
    /// - Parameter includeUnifiedContentPreviewInDiagnostics: P2-M5V8.1-O.2
    ///   §5 — `false` by default (every existing caller keeps storing zero
    ///   raw model content). Only `VoiceAuditionTool.runProviderUnifiedSmoke()`
    ///   passes `true`, since its own prompt/scenario is hard-coded and
    ///   non-sensitive — see `ModelUnifiedConversationProvider`'s own doc
    ///   comment for where this actually gets used.
    public static func withUnifiedModelProvider(
        config: ConversationModelConfig, client: ConversationModelRequesting = URLSessionConversationModelClient(),
        diagnostics: WakeDiagnosticsRecorder? = nil, memory: ConversationMemoryStoring = BoundedConversationMemory(),
        includeUnifiedContentPreviewInDiagnostics: Bool = false
    ) -> ConversationalResponsePresenter {
        ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(
                primary: ModelConversationReasoner(client: client, config: config, diagnostics: diagnostics),
                secondary: DeterministicConversationReasoner()
            ),
            naturalRealizer: FallbackNaturalResponseRealizing(
                primary: ModelNaturalResponseRealizer(client: client, config: config, diagnostics: diagnostics),
                secondary: DeterministicNaturalResponseRealizer()
            ),
            unifiedProvider: config.architecture == .unifiedOneCall
                ? ModelUnifiedConversationProvider(
                    client: client, config: config, diagnostics: diagnostics,
                    includeContentPreviewInDiagnostics: includeUnifiedContentPreviewInDiagnostics
                ) : nil,
            memory: memory, diagnostics: diagnostics
        )
    }

    public func response(for outcome: CommandRuntimeOutcome) -> SpokenResponse {
        response(for: outcome, transcript: nil, acoustics: .unavailable, explicitUserStatements: [])
    }

    /// P2-PROD-BOOTSTRAP-R2 §2.2 — the real production integration point.
    /// `WakeCoordinator` now delivers the validated command transcript, so
    /// the one-call brain (when configured via `withUnifiedModelProvider`)
    /// finally reasons about the user's actual words. Acoustic features
    /// still have no live feed at this call site (unchanged), so
    /// `.unavailable` is passed exactly as `response(for:)` above does.
    public func response(for outcome: CommandRuntimeOutcome, transcript: String?) -> SpokenResponse {
        response(for: outcome, transcript: transcript, acoustics: .unavailable, explicitUserStatements: [])
    }

    /// The richer entry point — used directly by the conversation harness
    /// and tests; `response(for:)` above (satisfying `ResponsePresenting`)
    /// calls this with no transcript/acoustic signal attached, matching
    /// today's real integration point (§6: this pipeline is synchronous
    /// and has no live transcript/acoustic feed wired into `WakeCoordinator`'s
    /// call site yet).
    public func response(
        for outcome: CommandRuntimeOutcome, transcript: String?, acoustics: AcousticConversationFeatures,
        explicitUserStatements: [String], failureEvidence: String? = nil
    ) -> SpokenResponse {
        let recent = memory.recentTurns(limit: 8)
        var context = contextCompiler.compile(outcome: outcome, recentResponseFamilies: recent.map(\.responseFamily))
        if let failureEvidence { context = context.withFailureEvidence(failureEvidence) }
        let strategy = strategyPlanner.strategy(for: context, persona: persona)

        let understanding: ConversationUnderstanding
        let plan: NaturalResponsePlan
        let response: SpokenResponse
        let avoiding = avoidingText(context: context, recent: recent)

        if let unifiedProvider {
            // P2-M5V8.1-O §1/§4 — the ONE-CALL path. §4/§5: a cheap,
            // purely LOCAL preliminary pass runs FIRST (no network) —
            // this is what already makes the deterministic-only
            // configuration fully correct today, so it is always a safe
            // baseline to hand the model as context/fallback, regardless
            // of whether the single network call below succeeds at all.
            let localUnderstanding = DeterministicConversationReasoner().understand(
                transcript: transcript, recentTurns: recent, context: context, acoustics: acoustics, explicitUserStatements: explicitUserStatements
            )
            let localPlan = planPlanner.plan(context: context, understanding: localUnderstanding, strategy: strategy, persona: persona)
            if let proposal = unifiedProvider.propose(
                transcript: transcript, recentTurns: recent, context: context,
                localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: avoiding
            ) {
                // §4/§6 — the SAME authoritative recomputation the
                // two-stage path already runs, unconditionally
                // discarding/overriding every safety-critical field the
                // model's reasoning proposal claimed. §5: the candidate
                // TEXT was generated against `localPlan` (necessarily —
                // it doesn't exist until this network call returns), so
                // `plan` recomputed here from the FINAL merged
                // understanding may occasionally differ in tone/register
                // from what the candidate text was actually written
                // against — an ACCEPTED, bounded imperfection (§5: "that
                // is acceptable... ResponseValidation must catch it" —
                // only for TRUTH violations, never mere tone drift).
                understanding = Self.authoritative(
                    proposal.understanding, context: context, transcript: transcript, recentTurns: recent,
                    acoustics: acoustics, explicitUserStatements: explicitUserStatements
                )
                plan = planPlanner.plan(context: context, understanding: understanding, strategy: strategy, persona: persona)
                response = realizeUnified(
                    context: context, understanding: understanding, plan: plan, candidateText: proposal.candidateText,
                    recent: recent, avoiding: avoiding, outcome: outcome
                )
            } else {
                // §24 — the unified call failed completely (not
                // configured, transport, timeout, decode, or schema
                // failure): full local fallback, no partial success, and
                // — per §7 — no second provider call to try to repair it.
                understanding = Self.authoritative(
                    localUnderstanding, context: context, transcript: transcript, recentTurns: recent,
                    acoustics: acoustics, explicitUserStatements: explicitUserStatements
                )
                plan = planPlanner.plan(context: context, understanding: understanding, strategy: strategy, persona: persona)
                diagnostics?.recordResponseAcceptance(schemaValid: false, semanticGroundingValid: false, responseAccepted: false)
                diagnostics?.recordFinalResponseSource(.deterministicFallback)
                response = safetyNetResponse(context: context, understanding: understanding, plan: plan, recent: recent, avoiding: avoiding, outcome: outcome)
            }
        } else {
            // The original, unchanged two-stage path.
            diagnostics?.recordProviderArchitecture("twoStage")
            understanding = Self.authoritative(
                reasoner.understand(transcript: transcript, recentTurns: recent, context: context, acoustics: acoustics, explicitUserStatements: explicitUserStatements),
                context: context, transcript: transcript, recentTurns: recent, acoustics: acoustics, explicitUserStatements: explicitUserStatements
            )
            plan = planPlanner.plan(context: context, understanding: understanding, strategy: strategy, persona: persona)
            response = realize(context: context, understanding: understanding, plan: plan, recent: recent, avoiding: avoiding, outcome: outcome)
        }

        recordTurn(
            context: context, transcript: transcript, text: response.text, purpose: strategy.purpose, dialogueAct: understanding.dialogueAct, register: plan.socialRegister,
            activeTopic: understanding.activeTopic, artifactContext: understanding.artifactContext, pragmaticResponseAct: understanding.pragmaticResponseAct
        )
        return response
    }

    /// **Final Architectural Invariants §3 — "generated language cannot
    /// create facts," enforced BY CONSTRUCTION, not by convention.**
    /// `actionExecutionState`/`failureReason`/`retryability` are ALWAYS
    /// recomputed here from verified `context` (via `DeterministicConversationReasoner`'s
    /// own pure, stateless, non-overridable derivation functions),
    /// discarding whatever value ANY configured `ConversationReasoning`
    /// — including a future LLM-backed one — returned for those three
    /// fields specifically. Only genuinely reasoning-derived, non-
    /// authoritative fields (`dialogueAct`, `interactionMode`, `topic`,
    /// `explicitConstraints` — the user's own stated wishes, `socialRegisterRecommendation`,
    /// `humorSuitability`, etc.) pass through unchanged, since choosing
    /// among THOSE is exactly what §8/§9 of P2-M5V7 authorize a
    /// conversational reasoner to do.
    ///
    /// **P2-M5V8.1-S §7/§24/§26 hardening.** A real live-model gap this
    /// pass fixes: `interactionMode` used to pass through UNVALIDATED,
    /// meaning a reasoner (deterministic OR a real model) that
    /// mis-classified a plain follow-up statement ("It was one
    /// environment variable.") or a situational remark ("Production is
    /// down now.") as `.actionRequest` would make `actionExecutionState`
    /// correctly-computed-from-a-wrong-input become `.executedSucceeded`
    /// — producing a truthful-LOOKING but actually fabricated "Done."
    /// §24: "use model semantic interpretation as NON-AUTHORITATIVE
    /// evidence only." This is now enforced structurally: a LOCAL,
    /// evidence-based classification (`DeterministicConversationReasoner`,
    /// the same hardened classifier §3-§6 of this pass built) is always
    /// computed from the same transcript/recentTurns/context, and acts as
    /// a ONE-DIRECTION VETO — if the local classification concludes
    /// `.conversational` or `.constraint` (i.e., "no genuine action
    /// evidence exists, or the user explicitly said don't act"), that
    /// LOCAL reading wins regardless of what any reasoner claimed,
    /// because a false `.conversational`/`.constraint` reading only risks
    /// under-confirming (safe), while a false `.actionRequest` reading
    /// risks a fabricated completion claim (unsafe) — §5's asymmetric
    /// safety principle. When local evidence does NOT already rule out an
    /// action, the reasoner's (possibly model-informed, possibly richer)
    /// classification is still used, so genuine value-add from real
    /// semantic interpretation is preserved wherever it isn't unsafe.
    private static func authoritative(
        _ understanding: ConversationUnderstanding, context: ConversationContext, transcript: String?,
        recentTurns: [ConversationTurn], acoustics: AcousticConversationFeatures, explicitUserStatements: [String]
    ) -> ConversationUnderstanding {
        let local = DeterministicConversationReasoner().understand(
            transcript: transcript, recentTurns: recentTurns, context: context, acoustics: acoustics, explicitUserStatements: explicitUserStatements
        )
        // P2-M5V8.1-S2 §11 — the veto ALSO fires when local classification
        // recognizes a needStatement/styleRefinement pattern, even though
        // their interactionMode is `.actionRequest` (not conversational/
        // constraint): a reasoner (deterministic OR a real model) that
        // instead calls the SAME utterance a plain `.statement` must not
        // be allowed to route around the needStatement/styleRefinement
        // safety net in `actionExecutionState` below — local evidence for
        // "this is a need/style-refinement pattern" is exactly the same
        // kind of asymmetric-safety local override as conversational/
        // constraint (§5/§7), just expressed as a dialogueAct rather than
        // an interactionMode.
        let vetoesToSafe = local.interactionMode == .conversational || local.interactionMode == .constraint
            || local.dialogueAct == .needStatement || local.dialogueAct == .styleRefinement
        let effectiveInteractionMode = vetoesToSafe ? local.interactionMode : understanding.interactionMode
        // dialogueAct/explicitConstraints are overridden ALONGSIDE
        // interactionMode (not independently) only when the veto fires,
        // so the realizer's own dialogueAct-keyed wording (e.g.
        // `conversationalAcknowledgment`/`constraintAcknowledgment`)
        // stays coherent with the safe interactionMode it now receives,
        // rather than potentially mismatching a still-model-claimed
        // dialogueAct against a now-overridden interactionMode.
        let effectiveDialogueAct = vetoesToSafe ? local.dialogueAct : understanding.dialogueAct
        let effectiveExplicitConstraints = vetoesToSafe ? local.explicitConstraints : understanding.explicitConstraints

        // P2-M5V8.1-Q §2/§4 — ALWAYS local, never askable of a model
        // reasoner (identical discipline to `turnRelation`/`responseScope`
        // below): whether THIS turn needs a real capability at all is
        // exactly the kind of safety-critical gating fact §2 requires stay
        // local-only.
        let actionExecutionState = DeterministicConversationReasoner.actionExecutionState(
            interactionMode: effectiveInteractionMode, context: context, dialogueAct: effectiveDialogueAct,
            capabilityRequirement: local.capabilityRequirement
        )
        let failureReason = DeterministicConversationReasoner.failureReason(actionExecutionState: actionExecutionState, context: context)
        let retryability = DeterministicConversationReasoner.retryability(actionExecutionState: actionExecutionState, context: context, failureReason: failureReason)
        return ConversationUnderstanding(
            communicativeIntent: understanding.communicativeIntent, topic: understanding.topic,
            continuationOfPreviousTurn: understanding.continuationOfPreviousTurn, clarificationNeeded: understanding.clarificationNeeded,
            userExplicitPreference: understanding.userExplicitPreference, explicitUrgency: understanding.explicitUrgency,
            socialRegisterRecommendation: understanding.socialRegisterRecommendation, humorAppropriateness: understanding.humorAppropriateness,
            responseGoal: understanding.responseGoal, recommendedVerbosity: understanding.recommendedVerbosity,
            followUpNeeded: understanding.followUpNeeded, uncertainty: understanding.uncertainty,
            dialogueAct: effectiveDialogueAct, interactionMode: effectiveInteractionMode,
            actionExecutionState: actionExecutionState, explicitConstraints: effectiveExplicitConstraints,
            // P2-M5V8.1-P.1 §14 — `userGoal` now also carries the LOCAL
            // greeting-mirroring token (see `DeterministicConversationReasoner.greetingToken(lowerTranscript:)`)
            // whenever the veto fires — the SAME "local wins" precedent
            // already applied to dialogueAct/interactionMode/explicitConstraints
            // just above, extended to this one sibling field so a
            // model-supplied `userGoal` (a generic "short restatement,"
            // never guaranteed to carry a greeting token at all) can never
            // silently shadow the trustworthy local one on exactly the
            // turns where local has ALREADY determined this is a
            // conversational greeting.
            failureReason: failureReason, retryability: retryability, userGoal: vetoesToSafe ? local.userGoal : understanding.userGoal,
            // P2-M5V8.1-S2.2 §1 — root cause #1 of the referential
            // regression: this used to prefer the REASONER's (possibly
            // model-supplied, possibly generic/unhelpful) own
            // `correctionTarget` string over the LOCAL, evidence-based
            // `referentialDirection` value — meaning a model that set
            // ANY non-nil correctionTarget (even one that wasn't the
            // literal string "earlier") silently defeated
            // `referentialCorrectionClaimGuard`'s exact-match gate. Now
            // LOCAL wins unconditionally, matching the same "safety-
            // critical gating facts are never trusted from a reasoner"
            // discipline already applied to `actionExecutionState`/the
            // interactionMode veto above.
            correctionTarget: local.correctionTarget ?? understanding.correctionTarget, explanationRequested: understanding.explanationRequested,
            humorSuitability: understanding.humorSuitability,
            // §5/§6 — ALWAYS local: `ConversationModelSchema.understanding(from:)`
            // never populates this field at all (the model is never even
            // asked for it), so `understanding.userReportedState` is
            // structurally always `nil` on the model path regardless —
            // sourcing it from `local` is not a "local wins" choice here,
            // it is the ONLY source that could ever be non-nil.
            userReportedState: local.userReportedState,
            // P2-M5V8.1-S3 §3/§4/§20 — turnRelation/activeTopic/artifactContext
            // are ALWAYS local for the identical reason `userReportedState`
            // is: `ConversationModelSchema` never asks the model for them,
            // so `understanding`'s copies are structurally always the
            // type's own safe defaults on the model path, never a real
            // model opinion to weigh against local in the first place.
            // `pragmaticResponseAct` is the ONE field in this group that
            // §20 explicitly allows the reasoner to suggest — but this
            // codebase's model schema doesn't carry it either today, so
            // it too resolves to local for now; documented here so a
            // future schema addition knows exactly where to plug in a
            // real "local may override" precedence instead of this
            // simpler "local always wins" one.
            turnRelation: local.turnRelation, activeTopic: local.activeTopic, artifactContext: local.artifactContext,
            pragmaticResponseAct: local.pragmaticResponseAct,
            // P2-M5V8.1-O.5 §1/§6 — ALWAYS local, for the identical reason
            // as the fields immediately above: never trusted from, or
            // even askable of, a model reasoner (no wire field exists for
            // it, by design — §6: "do not give the model new authority").
            responseScope: local.responseScope, capabilityRequirement: local.capabilityRequirement
        )
    }

    private func realize(
        context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan,
        recent: [ConversationTurn], avoiding: String?, outcome: CommandRuntimeOutcome
    ) -> SpokenResponse {
        if let naturalRealizer, let draft = naturalRealizer.realize(context: context, understanding: understanding, plan: plan, recentTurns: recent, avoiding: avoiding) {
            // P2-M5V8.1-S2.1 §2/§3 — determined RIGHT HERE, immediately
            // after `naturalRealizer.realize(...)` above has ALREADY run
            // and (if a model is configured) already written to this same
            // diagnostics recorder — checking this BEFORE the call (a
            // real bug this pass's own test suite caught while writing
            // it) would read a stale value from whatever the PREVIOUS
            // turn recorded, not this one. `FallbackNaturalResponseRealizing.realize()`
            // is `primary.realize(...) ?? secondary.realize(...)` — the
            // `??` short-circuits on the model's non-nil result, so if
            // the model's own `realize()` call just succeeded, `draft`
            // MUST be its text; if the model failed, `draft` (if any)
            // MUST be the deterministic secondary's. This is what makes
            // `finalResponseSource`/the fixed `realizerUsedModel`
            // derivation possible without threading a new parameter
            // through `NaturalConversationRealizing`'s protocol.
            let candidateFromModel = diagnostics?.snapshot().lastRealizerUsed == "model"
            return acceptOrFallback(
                draft: draft, candidateFromModel: candidateFromModel, context: context, understanding: understanding,
                plan: plan, recent: recent, avoiding: avoiding, outcome: outcome
            )
        }
        // No draft at all (realizer not configured, or every tier of the
        // fallback chain returned nil) — nothing to grade for grounding;
        // both are simply not applicable.
        diagnostics?.recordResponseAcceptance(schemaValid: false, semanticGroundingValid: false, responseAccepted: false)
        diagnostics?.recordFinalResponseSource(.deterministicFallback)
        return safetyNetResponse(context: context, understanding: understanding, plan: plan, recent: recent, avoiding: avoiding, outcome: outcome)
    }

    /// P2-M5V8.1-O §1/§6 — the ONE-CALL sibling of `realize(...)` above:
    /// `candidateText` already exists (produced by the SAME single
    /// provider round trip that produced `understanding`'s own reasoning
    /// proposal, before authoritative recomputation) rather than being
    /// obtained by calling a `NaturalConversationRealizing` a second
    /// time. Everything AFTER "a draft exists" is IDENTICAL to the
    /// two-stage path — same sanitize call, same `passesSemanticGuards`
    /// gate, same diagnostics recording, same deterministic safety net —
    /// via the shared `acceptOrFallback` helper, so the one-call path can
    /// never drift from the two-stage path's safety behavior (§6: "run
    /// existing semantic guards... exactly as today").
    private func realizeUnified(
        context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan,
        candidateText: String, recent: [ConversationTurn], avoiding: String?, outcome: CommandRuntimeOutcome
    ) -> SpokenResponse {
        acceptOrFallback(
            draft: candidateText, candidateFromModel: true, context: context, understanding: understanding,
            plan: plan, recent: recent, avoiding: avoiding, outcome: outcome
        )
    }

    /// The shared "is this draft safe to speak" decision both `realize(...)`
    /// and `realizeUnified(...)` reduce to — extracted so the SAME
    /// sanitize/validate/accept/reject/diagnostics logic can never
    /// diverge between the two architectures (a real correctness
    /// concern, not just a maintainability one: two independently-
    /// maintained copies of a safety gate is exactly how a future
    /// one-path-only fix could silently leave the other path unguarded).
    private func acceptOrFallback(
        draft: String, candidateFromModel: Bool, context: ConversationContext, understanding: ConversationUnderstanding,
        plan: NaturalResponsePlan, recent: [ConversationTurn], avoiding: String?, outcome: CommandRuntimeOutcome
    ) -> SpokenResponse {
        // P2-M5V7 §3: whether this interaction reads as "successful" can
        // NEVER be `context.wasSuccess` alone when the utterance never
        // requested an action in the first place — a synthetic/attached
        // SUCCESS outcome must not make a personal update or a
        // constraint acknowledgment report `wasSuccess: true` (there was
        // nothing to succeed AT). This is the exact fix for a real bug
        // this milestone's own test suite caught: without it, "I finally
        // fixed that bug" would correctly avoid saying "Done." but would
        // still incorrectly report `wasSuccess: true`.
        let effectiveWasSuccess = understanding.actionExecutionState == .notRequested ? false : context.wasSuccess
        let fallbackText = effectiveWasSuccess ? "Done." : "I couldn't complete that request."
        let sanitized = ResponseValidation.sanitize(draft, fallback: fallbackText)
        // P2-M5V7 §21 Response Validation 2.0: any single guard failing
        // means "discard the generated response, use the deterministic
        // fallback" — never a partial/softened use of offending text
        // (§27/§28: the truth boundary is never negotiable, even
        // reworded).
        let semanticGroundingValid = ResponseValidation.passesSemanticGuards(
            sanitized, wasSuccess: effectiveWasSuccess, actionExecutionState: understanding.actionExecutionState,
            retryability: understanding.retryability, failureReason: understanding.failureReason,
            dialogueAct: understanding.dialogueAct, correctionTarget: understanding.correctionTarget,
            userReportedState: understanding.userReportedState, responseScope: understanding.responseScope
        )
        // P2-M5V8.1-S2 §18/§19 — the ONLY point in this whole pipeline
        // where the RAW candidate (before any fallback substitution) is
        // available to diagnose non-tautologically: `schemaValid` (a
        // realizer — model or deterministic — produced SOME draft),
        // `semanticGroundingValid` (that draft is compatible with
        // authoritative facts), and `responseAccepted` (both are true,
        // so THIS text is what's actually spoken) are recorded here,
        // distinctly, exactly once per turn.
        diagnostics?.recordResponseAcceptance(schemaValid: true, semanticGroundingValid: semanticGroundingValid, responseAccepted: semanticGroundingValid)
        if semanticGroundingValid {
            // P2-M5V8.1-S2.1 §3/§4 — the fix: the model's own inference
            // succeeding is NOT sufficient for `finalResponseSource ==
            // .model` — its candidate must ALSO have been the one
            // actually accepted here.
            diagnostics?.recordFinalResponseSource(candidateFromModel ? .model : .deterministicFallback)
            return SpokenResponse(
                text: sanitized, wasSuccess: effectiveWasSuccess, category: plan.prosodyIntent,
                responseFamily: context.responseFamily, truthClassification: TruthClassification.classify(wasSuccess: effectiveWasSuccess, family: context.responseFamily),
                followUp: plan.followUpMode
            )
        }
        // §4/§7 — semantic rejection: the candidate (possibly the
        // model's own) is discarded outright; every path below this
        // point is unconditionally deterministic, so the final source is
        // recorded as such HERE, at the point of rejection, not inferred
        // later. P2-M5V8.1-O §7 — NEVER a second provider call to try to
        // repair this: the caller (`response(for:transcript:...)`) always
        // proceeds straight to the deterministic safety net below.
        diagnostics?.recordFinalResponseSource(.deterministicFallback)
        return safetyNetResponse(context: context, understanding: understanding, plan: plan, recent: recent, avoiding: avoiding, outcome: outcome)
    }

    /// P2-M5V7 §3/§21 safety net: the UNCHANGED `base` presenter
    /// (`DeterministicResponsePresenter`) has no transcript/dialogue-act
    /// awareness at all — it would happily speak "Done." for a
    /// `.notRequested` action state, since it only ever sees the
    /// (possibly synthetic) runtime outcome. A conversational/constraint
    /// utterance must NEVER reach it. Shared by every path (two-stage
    /// draft rejected, one-call candidate rejected, one-call provider
    /// call failed completely, no realizer configured at all) that ends
    /// up needing the fully deterministic, guaranteed-safe fallback.
    private func safetyNetResponse(
        context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan,
        recent: [ConversationTurn], avoiding: String?, outcome: CommandRuntimeOutcome
    ) -> SpokenResponse {
        // P2-M5V8.1-P.2-FINAL-CLOSURE §3/§4/§5 — a real, confirmed truth-
        // loss this fix closes: this safety net used to consult the rich,
        // `failureReason`/`retryability`-AWARE `DeterministicNaturalResponseRealizer`
        // ONLY for `actionExecutionState == .notRequested`, falling straight
        // to the flat `base` presenter (which sees only the RAW runtime
        // outcome — no grounded-cause/retry awareness at all) for every
        // other state. That meant a genuine KNOWN failure with grounded
        // connectivity evidence — which the DIRECT deterministic-only
        // path already surfaces correctly via `groundedFailureText`
        // (§7 of the mission this closes: "I couldn't reach the
        // service.") — silently lost that specificity here, landing on
        // `base`'s generic "I couldn't complete that request."/"That
        // didn't go through." instead, purely because this turn happened
        // to reach the safety net via a ONE-CALL semantic REJECTION
        // rather than the two-stage/deterministic-only path. Fixed by
        // ALWAYS trying the rich realizer first (its own long-established
        // `nil` contract — "nothing safer/better to offer" — already
        // makes it safe to consult unconditionally); `base` is now
        // reached only when the rich realizer genuinely declines, exactly
        // preserving today's behavior for every case it already handled
        // (`.executedSucceeded` outside professional register,
        // `.denied`, `.unsupported` without humor allowed all still
        // return `nil` from the rich realizer, unchanged, and fall
        // through to `base` exactly as before).
        if let safeText = DeterministicNaturalResponseRealizer().realize(context: context, understanding: understanding, plan: plan, recentTurns: recent, avoiding: avoiding) {
            let effectiveWasSuccess = understanding.actionExecutionState == .notRequested ? false : context.wasSuccess
            return SpokenResponse(
                text: safeText, wasSuccess: effectiveWasSuccess, category: plan.prosodyIntent, responseFamily: context.responseFamily,
                truthClassification: understanding.actionExecutionState == .notRequested
                    // Not a real failure — nothing was attempted — but
                    // `TruthClassification` has no dedicated "no action
                    // taken" case; `.definitiveFailure` ("a genuine,
                    // definitive non-success the runtime is certain
                    // about") is the closest accurate reading: this is
                    // DEFINITELY not a confirmed success, with no
                    // ambiguity about why.
                    ? .definitiveFailure : TruthClassification.classify(wasSuccess: effectiveWasSuccess, family: context.responseFamily),
                followUp: plan.followUpMode
            )
        }
        return base.response(for: outcome)
    }

    /// Mirrors `DeterministicResponsePresenter`'s own replay-safe
    /// repetition-avoidance rule exactly (§15 of P2-M5V5, unchanged):
    /// only avoid the immediately-previous DISTINCT turn's exact text in
    /// the SAME family, never perturb a replay of the same taskID.
    private func avoidingText(context: ConversationContext, recent: [ConversationTurn]) -> String? {
        guard let last = recent.last, last.taskID != context.taskID, last.responseFamily == context.responseFamily else { return nil }
        return last.responseText
    }

    private func recordTurn(
        context: ConversationContext, transcript: String?, text: String, purpose: ResponsePurpose, dialogueAct: DialogueAct, register: SocialRegister,
        activeTopic: ActiveConversationTopic, artifactContext: ArtifactContext?, pragmaticResponseAct: PragmaticResponseAct?
    ) {
        // A replay of the same taskID must not add a duplicate memory
        // entry (would corrupt "last distinct turn" repetition-avoidance
        // and let a single replayed interaction count as two turns of
        // conversational history).
        if let recent = memory.recentTurns(limit: 1).last, recent.taskID == context.taskID { return }
        memory.record(ConversationTurn(
            taskID: context.taskID, transcript: transcript, responseFamily: context.responseFamily, responseText: text,
            purpose: purpose, dialogueAct: dialogueAct, previousRegister: register,
            activeTopic: activeTopic, artifactContext: artifactContext, pragmaticResponseAct: pragmaticResponseAct
        ))
    }
}
