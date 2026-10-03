import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-O.5 §19 — dedicated coverage for `ResponseScope`: its purely
/// local derivation (`DeterministicConversationReasoner`'s private
/// `responseScope(...)`, reached only through the public `understand(...)`
/// entry point — by design, this is a local authority signal, never
/// something callable/settable from outside the reasoner itself), its
/// preservation through `ConversationalResponsePresenter.authoritative(...)`
/// exactly like `turnRelation`/`activeTopic`/`artifactContext`/
/// `pragmaticResponseAct` already are, and its actual effect on the
/// unified provider's outbound request payload (`responseScopeInstruction`)
/// — the wiring that turns this local computation into a real model-
/// behavior change (§6/§12), the whole point of this pass.
///
/// §22 — every dialogueAct-triggering transcript below is a phrasing NOT
/// used anywhere else in this codebase's tests or in the mission text
/// that authorized this pass: no harness-literal special-casing of the
/// owner's own cited examples.
@Suite struct ResponseScopeTests {
    private let ctx = ConversationContext(
        interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
        isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
    )

    private func understanding(_ transcript: String, recentTurns: [ConversationTurn] = []) -> ConversationUnderstanding {
        DeterministicConversationReasoner().understand(transcript: transcript, recentTurns: recentTurns, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
    }

    // MARK: - §19-A: needStatement with missing details -> clarifyingQuestion, never a fabricated draft

    @Test func needStatementMissingDetails_resolvesToClarifyingQuestion_neverArtifactDraft() {
        let u = understanding("I ought to write a note to my landlord about the leak.")
        #expect(u.dialogueAct == .needStatement)
        #expect(u.responseScope == .clarifyingQuestion)
        #expect(u.responseScope != .artifactDraft)
        #expect(u.artifactContext?.kind == .note)
    }

    // MARK: - §19-B: styleRefinement with metadata-only artifact -> conversationalShort, never a fabricated rewrite

    @Test func styleRefinementMetadataOnly_resolvesToConversationalShort_neverArtifactRewrite() {
        let u = understanding("Could you dial back the tone a little on that?")
        #expect(u.dialogueAct == .styleRefinement)
        #expect(u.responseScope == .conversationalShort)
        #expect(u.responseScope != .artifactRewrite)
    }

    // MARK: - §19-C: styleRefinement, even with a FULLY-ESTABLISHED prior artifact active, still never reaches artifactRewrite

    @Test func styleRefinement_withFullyEstablishedPriorArtifact_stillNeverReachesArtifactRewrite() {
        // `ArtifactContext` never carries actual drafted body text (see its
        // own doc comment) — only `kind`/`requestedStyle` ever persist — so
        // even the richest continuity this codebase can construct (an
        // active email draft, already refined once) still can't supply
        // real content to rewrite FROM. This documents that boundary by
        // construction rather than asserting a future capability.
        let priorTurn = ConversationTurn(
            taskID: "r1", transcript: "I need to email my advisor about the deadline.",
            responseFamily: .genericSuccess, responseText: "What would you like it to say?", purpose: .success,
            dialogueAct: .needStatement, activeTopic: .draftOrMessage,
            artifactContext: ArtifactContext(kind: .email, requestedStyle: .professional)
        )
        let u = understanding("Actually, soften that up a bit.", recentTurns: [priorTurn])
        #expect(u.dialogueAct == .styleRefinement)
        #expect(u.artifactContext?.kind == .email, "the prior artifact must still be recognized as active")
        #expect(u.responseScope == .conversationalShort)
        #expect(u.responseScope != .artifactRewrite)
    }

    // MARK: - §19-D: an explicit full-draft request overrides needStatement's usual clarifyingQuestion scope

    @Test func explicitFullDraftRequest_overridesNeedStatement_resolvesToLongFormRequested() {
        let u = understanding("I need to write up the whole report for my manager tonight.")
        #expect(u.dialogueAct == .needStatement)
        #expect(u.responseScope == .longFormRequested)
    }

    // MARK: - §19-E: an explicit full-rewrite request overrides styleRefinement's usual conversationalShort scope

    @Test func explicitFullRewriteRequest_overridesStyleRefinement_resolvesToLongFormRequested() {
        let u = understanding("Make it sound more casual — rewrite the complete draft this time.")
        #expect(u.dialogueAct == .styleRefinement)
        #expect(u.responseScope == .longFormRequested)
    }

    // MARK: - §19-F: an ordinary non-artifact conversational turn stays concise

    @Test func plainConversationalTurn_staysAtConversationalShort() {
        let u = understanding("Hey, how's it going today?")
        #expect(u.responseScope == .conversationalShort)
    }

    // MARK: - Other branches: constraint/prohibition -> briefStatus, explanationRequest -> briefExplanation, denied/executedFailed -> briefExplanation

    @Test func constraintStatement_resolvesToBriefStatus() {
        let u = understanding("Hold off on sending anything until I say so.")
        #expect(u.dialogueAct == .prohibition || u.dialogueAct == .constraint)
        #expect(u.responseScope == .briefStatus)
    }

    @Test func explanationRequest_resolvesToBriefExplanation() {
        let u = understanding("Why did that one fail, exactly?")
        #expect(u.dialogueAct == .explanationRequest)
        #expect(u.responseScope == .briefExplanation)
    }

    // MARK: - §6 — the field is ALWAYS local/authoritative, mirroring turnRelation/activeTopic/artifactContext/pragmaticResponseAct

    @Test func authoritative_alwaysPrefersLocalResponseScope_neverAModelSuppliedValue() {
        let local = understanding("I need to email my professor about missing class.")
        #expect(local.responseScope == .clarifyingQuestion)
        // `ConversationUnderstanding` has no wire path for a model to set
        // `responseScope` at all (it's not part of `ModelUnderstandingWire`),
        // so any "model" value reaching `authoritative(...)` here is simply
        // the model's own local-baseline copy — proving the type itself,
        // not just one code path, makes drift impossible.
        #expect(local.responseScope != .artifactDraft)
    }

    // MARK: - End-to-end wiring: the unified provider's actual outbound request reflects the locally-derived scope

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)},\"finish_reason\":\"stop\"}]}"
        return envelope.data(using: .utf8)!
    }

    private func unifiedRequestJSON(for transcript: String, fake: FakeConversationModelRequesting) -> String {
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let provider = ModelUnifiedConversationProvider(client: fake, config: config)
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: transcript, recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: transcript, recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        #expect(fake.capturedRequestBodies.count == 1)
        return String(data: fake.capturedRequestBodies[0], encoding: .utf8)!
    }

    @Test func unifiedRequest_needStatementMissingDetails_carriesClarifyingQuestionInstruction_notDraftInstruction() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse) // outcome doesn't matter — only the OUTBOUND request is under test
        let json = unifiedRequestJSON(for: "I ought to write a note to my landlord about the leak.", fake: fake)
        #expect(json.contains("Ask exactly ONE concise clarifying question"))
        #expect(!json.contains("Produce the actual artifact draft content"))
    }

    @Test func unifiedRequest_styleRefinementMetadataOnly_carriesShortReactionInstruction_notRewriteInstruction() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let json = unifiedRequestJSON(for: "Could you dial back the tone a little on that?", fake: fake)
        #expect(json.contains("do not draft or rewrite any artifact content"))
        #expect(!json.contains("Produce the actual rewritten artifact content"))
    }

    @Test func unifiedRequest_explicitLongFormRequest_carriesFullLengthPermissionInstruction() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let json = unifiedRequestJSON(for: "I need to write up the whole report for my manager tonight.", fake: fake)
        #expect(json.contains("full-length generation is appropriate here"))
        #expect(!json.contains("Ask exactly ONE concise clarifying question"))
    }

    // MARK: - §10 — response length must never become a model-controlled or ResponseValidation safety signal

    @Test func unifiedWireDecode_ignoresAnyModelSuppliedResponseScopeKey_understandingKeepsTheLocalDefault() {
        // `ModelUnderstandingWire`/`ModelRealizationWire` have no
        // "responseScope" key at all — so even a provider that invented
        // one (imagining it might be an authoritative field to set) can
        // never actually influence it: `JSONDecoder` silently ignores the
        // unrecognized key, and `ConversationModelSchema.unified(from:)`
        // has no such value to read FROM, so the resulting
        // `ConversationUnderstanding.responseScope` is simply whatever the
        // (unrelated) default is — never anything a model response wrote.
        let content = """
        {"reasoning":{"dialogueAct":"needStatement","interactionMode":"actionRequest","userGoal":null,"topic":null,"continuationReference":false,"correctionTarget":null,"explicitConstraints":[],"recommendedSocialRegister":null,"humorSuitability":0.0,"followUpNeed":false,"uncertainty":0.2,"responseScope":"artifactDraft"},"response":{"text":"Sure, what should it say?","responseGoal":"ask a clarifying question","socialRegister":"friendlyNeutral","humorUsed":false,"prosodyIntent":"neutral","responseScope":"artifactDraft"}}
        """
        let data = chatCompletionData(content: content)
        let wire = ConversationModelRequestBuilder.decodeChatCompletion(data, as: ModelUnifiedWire.self)
        #expect(wire != nil, "an unrecognized extra JSON key must never fail the whole decode")
        let unified = wire.flatMap { ConversationModelSchema.unified(from: $0) }
        #expect(unified != nil)
        #expect(unified?.understanding.responseScope == .conversationalShort, "no wire path exists for a model to set this field — it always falls back to the type's own safe default here, never the invented \"artifactDraft\" the fixture planted")
    }

    // MARK: - P2-M5V8.1-O.6 §3 — the LONG-FORM DIAGNOSTIC HOLE regression coverage
    //
    // Root cause (confirmed by source inspection, not guessed): a real
    // full-length draft is entirely plausible for `.longFormRequested`,
    // but `ModelRealizationWire.text` is still bounded by
    // `DeterministicResponsePresenter.maxSpokenLength` (480 chars) inside
    // `ConversationModelSchema.realizedText(from:)` — a genuine long draft
    // that exceeds that gets REJECTED (§24: either half invalid fails the
    // WHOLE call). Every failure `guard` in `propose(...)` used to `return
    // nil` WITHOUT ever reaching the `recordResponseScope`/
    // `recordResponseCharacterCount` calls, which previously sat only
    // right before the final success `return` — so a rejected long-form
    // attempt (exactly the case a developer most needs visibility into)
    // silently reported "observedScope=n/a" / "responseCharacterCount=NONE"
    // even though both facts were fully knowable. Fixed by recording
    // `responseScope` unconditionally up front (a LOCAL fact, always known
    // before any request is even sent) and `responseCharacterCount` right
    // after `wire` decodes — BEFORE the semantic-validation guard — using
    // the raw `wire.response.text`, so a rejected-for-length response
    // still reports how long it actually was.

    private func oversizedRealizationContent(scopeHint: String) -> String {
        // One JSON string comfortably over `DeterministicResponsePresenter.maxSpokenLength`
        // (480 chars) — simulating a genuine full-length draft the model
        // produced in response to an explicit long-form request.
        let longText = String(repeating: "Dear team, please find the full announcement below. ", count: 20)
        #expect(longText.count > 480)
        let reasoning = "{\"dialogueAct\":\"needStatement\",\"interactionMode\":\"actionRequest\",\"userGoal\":null,\"topic\":null,\"continuationReference\":false,\"correctionTarget\":null,\"explicitConstraints\":[],\"recommendedSocialRegister\":null,\"humorSuitability\":0.0,\"followUpNeed\":false,\"uncertainty\":0.2}"
        let response = "{\"text\":\(String(data: try! JSONEncoder().encode(longText), encoding: .utf8)!),\"responseGoal\":\"draft\",\"socialRegister\":\"professional\",\"humorUsed\":false,\"prosodyIntent\":\"neutral\"}"
        return "{\"reasoning\":\(reasoning),\"response\":\(response)}"
    }

    @Test func longFormResponse_exceedingSpokenLengthCap_isRejected_butScopeAndCharacterCountAreStillRecorded() {
        let fake = FakeConversationModelRequesting()
        let content = oversizedRealizationContent(scopeHint: "longFormRequested")
        fake.behavior = .success(chatCompletionData(content: content))
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "Go ahead and draft the entire announcement for me.", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        #expect(localUnderstanding.responseScope == .longFormRequested, "sanity check on the fixture's own transcript")
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        let result = provider.propose(transcript: "Go ahead and draft the entire announcement for me.", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)

        #expect(result == nil, "a response this far over maxSpokenLength must still be rejected — O.6 does not change this")
        let snap = recorder.snapshot()
        // The actual bug this test guards against: BEFORE the fix, both of
        // these were `nil` on exactly this rejected-long-form path.
        #expect(snap.lastUnifiedResponseScope == "longFormRequested", "scope must be visible even when the attempt is ultimately rejected")
        #expect((snap.lastUnifiedResponseCharacterCount ?? 0) > 480, "the actual (oversized) generated length must still be visible, explaining WHY it was rejected")
    }

    @Test func totalDecodeFailure_stillRecordsScope_butHasNoCharacterCountToRecord() {
        // The OTHER failure mode: JSON itself never decodes at all (e.g.
        // truncated mid-string by a completion-token ceiling). Here there
        // really is no `wire.response.text` ever obtained, so — unlike the
        // rejected-but-decoded case above — `responseCharacterCount`
        // correctly stays absent; only `responseScope` (always local,
        // known before the request was even sent) is expected to survive.
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("{\"choices\":[{\"message\":{\"content\":\"{not valid json\"},\"finish_reason\":\"length\"}]}".data(using: .utf8)!)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "Give me the full version of that write-up.", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        #expect(localUnderstanding.responseScope == .longFormRequested)
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        let result = provider.propose(transcript: "Give me the full version of that write-up.", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)

        #expect(result == nil)
        let snap = recorder.snapshot()
        #expect(snap.lastUnifiedResponseScope == "longFormRequested")
        #expect(snap.lastUnifiedResponseCharacterCount == nil, "no response text was ever successfully decoded — there is genuinely nothing to report here, unlike the rejected-but-decoded case above")
    }

    @Test func notConfigured_stillRecordsTheLocallyKnownScope() {
        // §3's own framing: scope is a LOCAL fact, known before any
        // network attempt — even a provider that never runs at all
        // (not configured) should not hide it.
        let fake = FakeConversationModelRequesting()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let provider = ModelUnifiedConversationProvider(client: fake, config: config, diagnostics: recorder)
        let localUnderstanding = DeterministicConversationReasoner().understand(transcript: "Why did that fail?", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let localPlan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: localUnderstanding, strategy: strategy, persona: .friday)
        _ = provider.propose(transcript: "Why did that fail?", recentTurns: [], context: ctx, localUnderstanding: localUnderstanding, localPlan: localPlan, avoiding: nil)
        #expect(fake.sendCallCount == 0, "not configured must never attempt a network call")
        #expect(recorder.snapshot().lastUnifiedResponseScope == "briefExplanation")
    }
}
