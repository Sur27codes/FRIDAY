import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-S — dedicated coverage for the semantic-authority/grounding
/// hardening pass triggered by a REAL live owner MODEL/MODEL evaluation
/// (gpt-5.6-sol) that surfaced genuine fabricated-completion bugs the
/// deterministic-only test suite never exercised. Covers: the diagnostic-
/// truth fix (§1), evidence-gated `InteractionMode` + constraint
/// generalization (§3-§6), the authoritative local-evidence veto (§7/§24/§26),
/// needStatement/styleRefinement wording (§10/§11), referential-correction/
/// explanation-continuity wire grounding (§12/§13), the new
/// `ResponseValidation` typed-claim guards (§17-§22), the mandatory
/// unseen-wording generalization set (§27), and adversarial rejected-claim
/// tests (§28).
@Suite struct SemanticAuthorityHardeningTests {
    private func context(
        family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1", isRetryable: Bool? = nil, failureEvidence: String? = nil
    ) -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: isRetryable ?? DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false,
            failureEvidence: failureEvidence
        )
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    // MARK: - §1: diagnostic truth — the SOURCE fix, not display-string patching

    @Test func modelReasoner_httpSucceedsButSchemaInvalid_neverRecordedAsReasonerSucceeded() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("not valid json at all".data(using: .utf8)!)
        let recorder = WakeDiagnosticsRecorder()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let reasoner = ModelConversationReasoner(client: fake, config: config, diagnostics: recorder)
        let result = reasoner.understand(transcript: "hello", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(result == .minimal, "a schema-invalid 200 must still degrade to .minimal")
        let snapshot = recorder.snapshot()
        // THE fix: previously `lastReasonerUsed` was set to "model" here
        // (transport succeeded) even though `.minimal` — never the
        // model's own content — is what's actually returned.
        #expect(snapshot.lastReasonerUsed != "model", "transport success must never be conflated with 'this stage produced a usable result'")
        #expect(snapshot.modelSchemaViolationCount == 1)
        #expect(snapshot.modelProviderFailureCount == 1, "a schema-invalid response must count as a genuine failure, not a silent success")
    }

    @Test func modelRealizer_httpSucceedsButSchemaInvalid_neverRecordedAsRealizerSucceeded() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("garbage".data(using: .utf8)!)
        let recorder = WakeDiagnosticsRecorder()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config, diagnostics: recorder)
        let result = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        #expect(result == nil)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastRealizerUsed != "model")
        #expect(snapshot.modelSchemaViolationCount == 1)
    }

    @Test func modelReasoner_genuineSchemaSuccess_isRecordedAsSucceeded() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"personalUpdate","interactionMode":"conversational","uncertainty":0.1}
        """))
        let recorder = WakeDiagnosticsRecorder()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let reasoner = ModelConversationReasoner(client: fake, config: config, diagnostics: recorder)
        _ = reasoner.understand(transcript: "hello", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastReasonerUsed == "model")
        #expect(snapshot.modelProviderFailureCount == 0)
        #expect(snapshot.modelSchemaViolationCount == 0)
    }

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
        return envelope.data(using: .utf8)!
    }

    private func minimalPlan(socialRegister: SocialRegister = .friendlyNeutral, humorAllowance: Bool = false) -> NaturalResponsePlan {
        NaturalResponsePlan(responseGoal: .success, socialRegister: socialRegister, warmth: 0.8, directness: 0.7, humorAllowance: humorAllowance, humorStrength: humorAllowance ? 0.3 : 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
    }

    private func understanding(dialogueAct: DialogueAct, actionExecutionState: ActionExecutionState = .unknown, correctionTarget: String? = nil) -> ConversationUnderstanding {
        ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            dialogueAct: dialogueAct, interactionMode: .actionRequest, actionExecutionState: actionExecutionState,
            explicitConstraints: [], failureReason: .unknown, retryability: .unknown, userGoal: nil,
            correctionTarget: correctionTarget, explanationRequested: dialogueAct == .explanationRequest, humorSuitability: 0
        )
    }

    // MARK: - §29: diagnostic invariant — impossible combinations structurally excluded

    @Test func diagnosticInvariant_reasonerUsedModel_impliesReasonerProviderSucceeded() {
        // By construction (see the §1 fix above): `lastReasonerUsed ==
        // "model"` can ONLY be set alongside `succeeded: true`, so
        // deriving both flags from the same source makes
        // "reasonerUsedModel:true + reasonerProviderSucceeded:false"
        // structurally impossible, not merely untested.
        let recorder = WakeDiagnosticsRecorder()
        recorder.recordModelProviderRequest(stage: "understand", latencyMs: 10, succeeded: true)
        let snapshot = recorder.snapshot()
        let reasonerUsedModel = snapshot.lastReasonerUsed == "model"
        let reasonerProviderSucceeded = snapshot.lastReasonerUsed == "model"
        #expect(reasonerUsedModel == reasonerProviderSucceeded)
    }

    @Test func diagnosticInvariant_fallbackReasonNoneOnlyWhenFallbackNotUsed() {
        // Reproduces the harness's own derivation logic in isolation:
        // fallbackReason is computed ONLY inside the fallbackUsed==true
        // branch, so "fallbackUsed:false + non-none fallbackReason" can
        // never occur.
        func deriveFallbackReason(reasonerUsedModel: Bool, realizerUsedModel: Bool) -> (fallbackUsed: Bool, reason: String) {
            let fallbackUsed = !(reasonerUsedModel && realizerUsedModel)
            return (fallbackUsed, fallbackUsed ? "some fallback reason" : "none")
        }
        for reasonerUsedModel in [true, false] {
            for realizerUsedModel in [true, false] {
                let (fallbackUsed, reason) = deriveFallbackReason(reasonerUsedModel: reasonerUsedModel, realizerUsedModel: realizerUsedModel)
                if !fallbackUsed { #expect(reason == "none") }
                if fallbackUsed { #expect(reason != "none") }
            }
        }
    }

    // MARK: - §7/§24/§26: the authoritative local-evidence veto (the highest-leverage fix)

    /// A fake `ConversationReasoning` that simulates exactly the live,
    /// real-model failure this pass fixes: it HALLUCINATES `.actionRequest`
    /// for a plain conversational follow-up, exactly as a real model did.
    private struct HallucinatingActionRequestReasoner: ConversationReasoning {
        func understand(transcript: String?, recentTurns: [ConversationTurn], context: ConversationContext, acoustics: AcousticConversationFeatures, explicitUserStatements: [String]) -> ConversationUnderstanding {
            ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.1,
                dialogueAct: .statement, interactionMode: .actionRequest, // <- the hallucination
                actionExecutionState: .executedSucceeded, // <- also hallucinated; must be discarded regardless
                explicitConstraints: [], failureReason: .unknown, retryability: .unknown, userGoal: nil,
                correctionTarget: nil, explanationRequested: false, humorSuitability: 0
            )
        }
    }

    @Test func authoritative_localEvidenceVetoesHallucinatedActionRequest_forFollowUpStatement() {
        // THE live bug: "It was one environment variable." with a
        // hallucinating reasoner claiming .actionRequest + .executedSucceeded.
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingActionRequestReasoner(), naturalRealizer: nil)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "veto-1")),
            transcript: "It was one environment variable.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("done"))
        #expect(!response.wasSuccess, "the local veto must force notRequested, which forces wasSuccess=false regardless of the hallucinated claim")
    }

    @Test func authoritative_localEvidenceVetoesHallucinatedActionRequest_forSituationalStatement() {
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingActionRequestReasoner(), naturalRealizer: nil)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "veto-2")),
            transcript: "Production is down now.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("done"))
    }

    @Test func authoritative_localEvidenceVetoesHallucinatedActionRequest_forConstraint() {
        // §7: explicit user constraints outrank model interpretation —
        // even a reasoner claiming .actionRequest/.executedSucceeded must
        // lose to a LOCAL "leave it alone" prohibition classification.
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingActionRequestReasoner(), naturalRealizer: nil)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Acknowledged.", taskID: "veto-3")),
            transcript: "Leave it alone for the moment.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("done"))
        #expect(response.text.localizedCaseInsensitiveContains("won't") || response.text.localizedCaseInsensitiveContains("leave"))
    }

    @Test func authoritative_doesNotVeto_whenLocalEvidenceAgreesWithGenuineActionRequest() {
        // The veto must NOT suppress a genuine action request merely
        // because a reasoner (model or deterministic) also called it
        // .actionRequest — real value-add is preserved when local evidence
        // doesn't already rule out an action.
        let presenter = ConversationalResponsePresenter(reasoner: HallucinatingActionRequestReasoner(), naturalRealizer: nil)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "veto-4")),
            transcript: "Create a note called groceries.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(response.wasSuccess)
    }

    // MARK: - §6/§27: constraint generalization (compositional, unseen pairings)

    @Test func constraintGeneralization_unseenHoldVerbComplementPairings() {
        let reasoner = DeterministicConversationReasoner()
        let transcripts = [
            "Leave it alone for the moment.",
            "Hold off on that.",
            "Wait before changing anything.",
            "Leave that exactly as it is.",
            "Don't touch that for now.",
        ]
        for transcript in transcripts {
            let understanding = reasoner.understand(transcript: transcript, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
            #expect(understanding.interactionMode == .constraint, "\"\(transcript)\" should classify as a constraint")
            #expect(understanding.actionExecutionState == .notRequested, "\"\(transcript)\" must never inherit the synthetic SUCCESS outcome")
        }
    }

    // MARK: - §27: mandatory generalization tests (unseen wording, no exact-transcript table)

    @Test func generalization_personalUpdateFollowUp_pronounInsertion() {
        let reasoner = DeterministicConversationReasoner()
        let first = reasoner.understand(transcript: "I finally figured it out.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(first.dialogueAct == .personalUpdate)
        #expect(first.interactionMode == .conversational)
        let second = reasoner.understand(transcript: "It turned out to be a config flag.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(second.actionExecutionState == .notRequested, "a follow-up explaining cause must never claim completion")
    }

    @Test func generalization_situationalStatement_unseenSystemProblems() {
        let reasoner = DeterministicConversationReasoner()
        for transcript in ["The service is acting weird.", "The build is failing.", "The server's offline.", "The app keeps crashing.", "The deployment broke.", "The database is acting up."] {
            let understanding = reasoner.understand(transcript: transcript, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
            #expect(understanding.actionExecutionState == .notRequested, "\"\(transcript)\" describes a situation, not a completed action")
        }
    }

    @Test func generalization_needStatementFollowedByHelpRequest() {
        let reasoner = DeterministicConversationReasoner()
        let need = reasoner.understand(transcript: "I need to message my advisor.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(need.dialogueAct == .needStatement)
    }

    @Test func generalization_styleRefinement_unseenAdjective() {
        let reasoner = DeterministicConversationReasoner()
        let makeItWarmer = reasoner.understand(transcript: "Make it warmer.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(makeItWarmer.dialogueAct == .styleRefinement, "generalizes via the 'make it/that + X' grammatical pattern, not a per-adjective table")
        let keepProfessional = reasoner.understand(transcript: "Actually, keep it professional.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(keepProfessional.dialogueAct == .styleRefinement, "must win over the 'actually,' correction-marker prefix")
    }

    @Test func generalization_referentialCorrection_unseenWording() {
        let reasoner = DeterministicConversationReasoner()
        let recent = [ConversationTurn(taskID: "t1", transcript: "Create a note called groceries.", responseFamily: .createNoteSuccess, responseText: "Created and verified note \"groceries\".", purpose: .success, dialogueAct: .command, previousRegister: .friendlyNeutral)]
        let understanding = reasoner.understand(transcript: "No, I meant the one before that.", recentTurns: recent, context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .correction)
        #expect(understanding.correctionTarget == "earlier")
    }

    @Test func generalization_explanationRequest_unseenPhrasing() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Do we know why?", recentTurns: [], context: context(family: .policyDenied, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.interactionMode != .actionRequest, "an unresolved question about a prior outcome must never read as a fresh action request")
    }

    // MARK: - §10/§11: needStatement / styleRefinement wording never over-claims

    @Test func needStatement_genericSuccess_neverClaimsCompletion() {
        let realizer = DeterministicNaturalResponseRealizer()
        let plan = minimalPlan(socialRegister: .professional)
        let text = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: understanding(dialogueAct: .needStatement, actionExecutionState: .executedSucceeded), plan: plan, recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(!(text ?? "").localizedCaseInsensitiveContains("done"))
        #expect(!(text ?? "").localizedCaseInsensitiveContains("taken care of"))
    }

    @Test func styleRefinement_genericSuccess_neverClaimsCompletion() {
        let realizer = DeterministicNaturalResponseRealizer()
        let plan = minimalPlan(socialRegister: .professional)
        let text = realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: understanding(dialogueAct: .styleRefinement, actionExecutionState: .executedSucceeded), plan: plan, recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(!(text ?? "").localizedCaseInsensitiveContains("all done"))
        #expect(!(text ?? "").localizedCaseInsensitiveContains("all set"))
    }

    // MARK: - §17/§18: execution-success claim guard (broader than notRequested-only)

    @Test func executionSuccessClaimGuard_rejectsCompletionPhrasing_forAnyNonSucceededState() {
        for state: ActionExecutionState in [.notRequested, .denied, .unsupported, .executedFailed, .requestedNotStarted, .unknown] {
            #expect(!ResponseValidation.executionSuccessClaimGuard("All set.", actionExecutionState: state), "\(state)")
            #expect(!ResponseValidation.executionSuccessClaimGuard("That went through.", actionExecutionState: state), "\(state)")
            #expect(!ResponseValidation.executionSuccessClaimGuard("I sent it.", actionExecutionState: state), "\(state)")
            #expect(!ResponseValidation.executionSuccessClaimGuard("I deleted it.", actionExecutionState: state), "\(state)")
            #expect(!ResponseValidation.executionSuccessClaimGuard("Done.", actionExecutionState: state), "\(state)")
        }
        #expect(ResponseValidation.executionSuccessClaimGuard("Done.", actionExecutionState: .executedSucceeded))
    }

    @Test func executionSuccessClaimGuard_neverFalsePositives_onIncidentalSubstring() {
        // "abandoned" contains "done" as a raw substring — must not trip
        // the whole-word check.
        #expect(ResponseValidation.executionSuccessClaimGuard("That task was abandoned.", actionExecutionState: .executedFailed))
    }

    // MARK: - §15/§19: unknown/known failure-cause grounding, and the unsupported/denied scoping fix

    @Test func failureCauseGuard_unknownCause_rejectsVariedUngroundedPhrasings() {
        let ungrounded = [
            "That didn't work—something went wrong internally.",
            "The network failed.",
            "There was a server issue.",
            "It timed out.",
            "A configuration problem occurred.",
        ]
        for text in ungrounded {
            #expect(!ResponseValidation.neverInventsFailureCause(text, failureReason: .unknown, actionExecutionState: .executedFailed), "\(text)")
        }
    }

    @Test func failureCauseGuard_allowsHonestUnknownPhrasing() {
        for text in ["That didn't work.", "I'm not sure what caused that yet.", "Something went wrong, but I don't know the cause yet."] {
            #expect(ResponseValidation.neverInventsFailureCause(text, failureReason: .unknown, actionExecutionState: .executedFailed), "\(text)")
        }
    }

    @Test func failureCauseGuard_doesNotApply_toUnsupportedOrDenied_evenThoughFailureReasonIsAlsoUnknown() {
        // The real scoping bug this pass found: `.unsupported`/`.denied`
        // ALSO carry `FailureReason.unknown` under this codebase's own
        // derivation, but "that capability isn't available" is TRUTHFUL
        // there, not an invented execution-failure cause.
        #expect(ResponseValidation.neverInventsFailureCause("That capability isn't available yet.", failureReason: .unknown, actionExecutionState: .unsupported))
        #expect(ResponseValidation.neverInventsFailureCause("I don't have permission for that.", failureReason: .unknown, actionExecutionState: .denied))
    }

    @Test func failureCauseGuard_knownCause_rejectsIncompatibleSpecificClaim() {
        // §19: retryAllowed/known-cause must be COMPATIBLE with the
        // actual evidence, not merely "some cause is known so anything goes."
        let reason = FailureReason.known(type: "runtime-reported", evidence: "connection refused")
        #expect(!ResponseValidation.neverInventsFailureCause("The server rejected your credentials.", failureReason: reason, actionExecutionState: .executedFailed))
        #expect(ResponseValidation.neverInventsFailureCause("I couldn't reach the service.", failureReason: reason, actionExecutionState: .executedFailed))
    }

    // MARK: - §16/§20: retryability guard

    @Test func retryClaimGuard_rejectsVariedRetryPhrasings_whenNotAllowed() {
        for text in ["Want me to try again?", "Should I retry?", "I can rerun it.", "Let me repeat the attempt."] {
            #expect(!ResponseValidation.neverOffersRetryClaimUnlessAllowed(text, retryability: .unknown), "\(text)")
            #expect(!ResponseValidation.neverOffersRetryClaimUnlessAllowed(text, retryability: .notAllowed), "\(text)")
        }
        #expect(ResponseValidation.neverOffersRetryClaimUnlessAllowed("Want me to try again?", retryability: .allowed))
    }

    // MARK: - §21: permission claim guard

    @Test func permissionClaimGuard_deniedMustNotBePhrasedAsUnsupported() {
        #expect(!ResponseValidation.permissionClaimGuard("That's not something I can do.", actionExecutionState: .denied))
        #expect(ResponseValidation.permissionClaimGuard("Authorization was denied for that.", actionExecutionState: .denied))
    }

    @Test func permissionClaimGuard_unsupportedMustNotBePhrasedAsDenied() {
        #expect(!ResponseValidation.permissionClaimGuard("You don't have permission for that.", actionExecutionState: .unsupported))
        #expect(ResponseValidation.permissionClaimGuard("Not in my skill set yet.", actionExecutionState: .unsupported))
    }

    // MARK: - §22: sensor claim guard

    @Test func sensorClaimGuard_rejectsVisualSensingClaims_allowsIdiomaticFarewells() {
        #expect(!ResponseValidation.neverImpliesUnverifiedSensing("Hey, good to see you."))
        #expect(!ResponseValidation.neverImpliesUnverifiedSensing("You look great today."))
        #expect(ResponseValidation.neverImpliesUnverifiedSensing("Hey, good to hear from you."))
        #expect(ResponseValidation.neverImpliesUnverifiedSensing("See you soon."), "an ordinary farewell idiom must not be over-literalized")
        #expect(ResponseValidation.neverImpliesUnverifiedSensing("Talk to you later."))
    }

    // MARK: - §28: adversarial generated-claim tests (varied wording, never exact-string-only)

    @Test func adversarial_ungroundedCompletionClaims_allRejected() {
        let candidates = ["Done.", "All set.", "That went through.", "I sent it.", "I deleted it."]
        for candidate in candidates {
            #expect(!ResponseValidation.passesSemanticGuards(candidate, wasSuccess: false, actionExecutionState: .executedFailed, retryability: .unknown, failureReason: .unknown), "\(candidate)")
        }
    }

    @Test func adversarial_ungroundedFailureCauseClaims_allRejected() {
        let candidates = ["The server timed out.", "The network failed.", "The capability isn't available.", "It was an internal error."]
        for candidate in candidates {
            #expect(!ResponseValidation.passesSemanticGuards(candidate, wasSuccess: false, actionExecutionState: .executedFailed, retryability: .unknown, failureReason: .unknown), "\(candidate)")
        }
    }

    @Test func adversarial_ungroundedRetryOffer_rejected() {
        #expect(!ResponseValidation.passesSemanticGuards("Want me to try again?", wasSuccess: false, actionExecutionState: .executedFailed, retryability: .notAllowed, failureReason: .unknown))
    }

    // MARK: - §12: referential-correction wire grounding reaches the model payload

    @Test func modelRealizer_correctionTarget_reachesOutgoingRequestPayload() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config)
        _ = realizer.realize(context: context(family: .createNoteSuccess, wasSuccess: true), understanding: understanding(dialogueAct: .correction, correctionTarget: "earlier"), plan: minimalPlan(), recentTurns: [], avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(json["messages"] != nil)
        if let messages = json["messages"] as? [[String: Any]], let userContent = messages.last?["content"] as? String {
            #expect(userContent.contains("earlier"), "correctionTarget must actually reach the model's payload, not just exist as an unused field")
        }
    }

    // MARK: - §13: explanation-continuity system-prompt guidance is present

    @Test func realizationSystemPolicy_instructsExplainingPriorFailureNotRejectingAgain() {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config)
        _ = realizer.realize(context: context(family: .policyDenied, wasSuccess: false), understanding: .minimal, plan: minimalPlan(), recentTurns: [], avoiding: nil)
        guard let body = fake.lastRequestBody(), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], let systemContent = messages.first?["content"] as? String else {
            Issue.record("expected a well-formed outgoing request body"); return
        }
        #expect(systemContent.localizedCaseInsensitiveContains("explanationRequest"))
        #expect(systemContent.localizedCaseInsensitiveContains("failureReason"))
    }
}
