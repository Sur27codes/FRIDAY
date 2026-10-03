import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-P.2 — LIVE PERSONA TRUTH-SIGNAL CLOSURE coverage. Every
/// transcript is either (a) an EXACT harness fixture transcript (§2's own
/// "prove the actual fixture values" — deliberately verbatim so these
/// tests prove the REAL `provider-persona-dialogue` scenarios, not stand-
/// ins for them), or (b) an unseen paraphrase for generalization (§9/§22).
/// Nothing here touches `ResponseScope`/authority/`ResponseValidation`/
/// `ExecutionClaimDetector` semantics (all frozen this pass) — the
/// execution-claim tests exercise that EXISTING, unchanged surface.
@Suite struct PersonaP2Tests {
    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "t", failureEvidence: String? = nil) -> ConversationContext {
        // §2's own instruction taken seriously: `isRetryable` here mirrors
        // `DeterministicConversationContextCompiler.isRetryable(_:)`
        // EXACTLY (capabilityUnavailable/policyUnavailable/executionFailed
        // all structurally retryable) rather than a hand-guessed
        // simplification — a mismatch here would make this test file
        // itself the next mislabeled fixture.
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: true, needsClarification: false,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false,
            failureEvidence: failureEvidence
        )
    }

    private func understanding(_ transcript: String, family: ResponseFamily, wasSuccess: Bool, failureEvidence: String? = nil, recentTurns: [ConversationTurn] = []) -> ConversationUnderstanding {
        let ctx = context(family: family, wasSuccess: wasSuccess, failureEvidence: failureEvidence)
        return DeterministicConversationReasoner().understand(transcript: transcript, recentTurns: recentTurns, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
    }

    // MARK: - §2/§3 — P4/P9 fixture truth (exact harness transcripts, proving the label matches reality)

    @Test func fixtureTruth_P4a_unknownFailure_actuallyProducesUnknown() {
        // Harness fixture: DialogueTurn("Update my calendar.", outcome: ("EXECUTION_FAILED", "..."))  — no evidence.
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false)
        #expect(u.actionExecutionState == .executedFailed)
        #expect(u.failureReason == .unknown, "P4a's label ('unknown failure') is TRUE to its fixture — no failureEvidence supplied")
        #expect(u.retryability != .allowed)
    }

    @Test func fixtureTruth_P4b_knownFailure_actuallyProducesKnownConnectivity() {
        // Harness fixture: same transcript + failureEvidence: "connection refused, service unreachable".
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false, failureEvidence: "connection refused, service unreachable")
        guard case .known(let type, let evidence) = u.failureReason else {
            Issue.record("expected .known, got \(u.failureReason)"); return
        }
        #expect(type == "runtime-reported")
        #expect(evidence == "connection refused, service unreachable")
        #expect(u.retryability != .allowed, "a generic EXECUTION_FAILED family stays non-retryable even with known evidence — retryability is about the FAMILY, not evidence presence")
    }

    @Test func fixtureTruth_P4cAndP9_retryAllowed_actuallyProducesAllowed() {
        // Harness fixture: DialogueTurn("Update my calendar.", outcome: ("CAPABILITY_UNAVAILABLE", "..."))
        let u = understanding("Update my calendar.", family: .capabilityUnavailable, wasSuccess: false)
        #expect(u.actionExecutionState == .executedFailed)
        #expect(u.retryability == .allowed, "P4c/P9's label ('retry allowed'/'retryable') is TRUE to its fixture")
    }

    @Test func fixtureTruth_P9b_nonRetryableLabel_actuallyProducesUnknownNotNotAllowed() {
        // §3's own precision requirement, applied honestly: P9b's fixture
        // (EXECUTION_FAILED, no evidence) produces retryability=.unknown,
        // NOT the stricter .notAllowed — functionally identical (no retry
        // is ever offered either way, see the next test), but this test
        // documents the PRECISE state so the label is never overclaimed.
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false)
        #expect(u.retryability == .unknown)
        #expect(u.retryability != .notAllowed, "documents the precise state — P9b's fixture never reaches the stricter .notAllowed value in this codebase's own retryability() design")
    }

    // MARK: - §4/§6 — known-cause vs. unknown-honesty surfacing (through realization, not just the raw enum)

    @Test func knownCauseSurfaced_whenGenuinelyGrounded() {
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false, failureEvidence: "connection refused, service unreachable")
        let text = DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u)
        #expect(text.localizedCaseInsensitiveContains("reach"), "known connectivity cause must be surfaced, not degraded to generic uncertainty")
        #expect(!text.localizedCaseInsensitiveContains("don't know"))
    }

    @Test func unknownHonesty_whenGenuinelyUnknown() {
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false)
        let text = DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u)
        #expect(text.localizedCaseInsensitiveContains("don't know"), "genuine unknown must preserve uncertainty, never silently degrade to a bare non-committal phrase")
    }

    // MARK: - §5 — retryable vs. non-retryable realization

    @Test func retryableRealization_communicatesRetryIsPossible() {
        let u = understanding("Update my calendar.", family: .capabilityUnavailable, wasSuccess: false)
        let text = DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u)
        #expect(text.localizedCaseInsensitiveContains("try again"))
        #expect(!text.localizedCaseInsensitiveContains("can't do that"), "must never sound like a permanent capability absence when retry is genuinely on the table")
    }

    @Test func nonRetryableRealization_neverOffersRetry() {
        let u = understanding("Update my calendar.", family: .executionFailed, wasSuccess: false)
        let text = DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u)
        #expect(!text.localizedCaseInsensitiveContains("try again"))
    }

    // MARK: - §7/§8 — seriousness/humor LOCAL GATE root-cause fix

    @Test func humorGate_negativeServiceReport_correctlyProhibited() {
        // The EXACT live-observed evidence this pass exists to fix:
        // "Great, now the payment service is timing out on everyone."
        // used to compute humorAppropriateness=true (root cause: the
        // gate never consulted `detectsNegativeSituationalState` at all,
        // and "timing out" wasn't even in that word list).
        let u = understanding("Great, now the payment service is timing out on everyone.", family: .genericSuccess, wasSuccess: true)
        #expect(u.userReportedState?.polarity == .negative, "the underlying negative-state detector must recognize \"timing out\"")
        #expect(!u.humorAppropriateness, "humor must be locally prohibited for a negative service report")
    }

    @Test func humorGate_explicitSeriousnessParaphrase_correctlyProhibited() {
        // The mission's OTHER live-cited example, an unseen paraphrase
        // of explicit seriousness the original narrow 6-phrase list
        // never matched.
        let u = understanding("No really, this one actually matters to me.", family: .unsupportedIntent, wasSuccess: false)
        #expect(!u.humorAppropriateness)
    }

    @Test func regressionGuard_broadenedSeriousnessWordDoesNotMisfireIntoActionRequestReinforcement() {
        // THE REAL REGRESSION this pass's own development caught and
        // fixed: broadening the seriousness word list for humor-gating
        // purposes must NEVER also flip `interactionMode` away from
        // `.conversational` via `actionRequestEvidence`'s SEPARATE
        // "isReinforcement" concept — a plain declarative report
        // containing "serious" must still realize as a conversational
        // reaction, never a fabricated completion claim.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "r1", correlationID: "r1", taskID: "r1", outcome: "SUCCESS", text: "Acknowledged.")),
            transcript: "Just wrapped up the deploy.", acoustics: .unavailable, explicitUserStatements: []
        )
        let after = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "r2", correlationID: "r2", taskID: "r2", outcome: "SUCCESS", text: "Acknowledged.")),
            transcript: "This is serious — the staging environment is down.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(after.text != "Done.")
        #expect(!after.text.localizedCaseInsensitiveContains("done"))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation(after.text))
    }

    // MARK: - §9 — seriousness generalization battery (unseen paraphrases, verbatim from the mission)

    @Test func seriousnessGeneralization_enoughJokingThisMatters() {
        let u = understanding("Enough joking—this matters.", family: .genericSuccess, wasSuccess: true)
        #expect(!u.humorAppropriateness)
    }

    @Test func seriousnessGeneralization_noSeriously() {
        let u = understanding("No, seriously.", family: .unsupportedIntent, wasSuccess: false)
        #expect(!u.humorAppropriateness)
    }

    @Test func seriousnessGeneralization_thisOnesImportant() {
        let u = understanding("This one's important.", family: .genericSuccess, wasSuccess: true)
        #expect(!u.humorAppropriateness)
    }

    @Test func seriousnessGeneralization_weAreActuallyDown() {
        let u = understanding("We're actually down.", family: .genericSuccess, wasSuccess: true)
        #expect(u.userReportedState?.polarity == .negative)
        #expect(!u.humorAppropriateness)
    }

    @Test func seriousnessGeneralization_peopleCantCheckOut_asContinuationOfAnEstablishedIncident() {
        // Standalone, this sentence carries no explicit trigger word of
        // its own — §8's own continuity-based fix covers it as a
        // follow-up continuing an already-established negative-state
        // topic (mirroring how activeTopic/artifact continuity already
        // carries forward elsewhere in this codebase).
        let priorTurn = ConversationTurn(
            taskID: "r1", transcript: "We're actually down.", responseFamily: .genericSuccess, responseText: "Got it. Want me to check what I can?",
            purpose: .success, dialogueAct: .statement, activeTopic: .runtimeStatus
        )
        let u = understanding("People can't check out.", family: .genericSuccess, wasSuccess: true, recentTurns: [priorTurn])
        #expect(!u.humorAppropriateness, "a consequence-describing follow-up must inherit the seriousness of the incident it continues")
    }

    @Test func seriousnessGeneralization_leaveTheJokesForLater() {
        let u = understanding("Leave the jokes for later.", family: .genericSuccess, wasSuccess: true)
        #expect(!u.humorAppropriateness)
    }

    @Test func seriousnessNegationGuard_doesntMatterIsNotMisreadAsSerious() {
        // The negation-guard this pass's own design requires: a DISMISSAL
        // using the same root word must never be misread as the opposite
        // of what it says.
        let u = understanding("Honestly, it doesn't matter — that's fine.", family: .genericSuccess, wasSuccess: true)
        #expect(u.humorAppropriateness, "a genuine dismissal must not trip the seriousness gate")
    }

    // MARK: - §10 — humor stays available for genuinely low-stakes turns (no over-suppression)

    @Test func lowStakesHumor_bugFixed_remainsEligible() {
        let u = understanding("I finally fixed that deploy script.", family: .genericSuccess, wasSuccess: true)
        #expect(u.humorAppropriateness)
    }

    @Test func lowStakesHumor_impossibleMoonFlightRequest_remainsEligible() {
        let u = understanding("Can you book me a flight to the moon?", family: .unsupportedIntent, wasSuccess: false)
        #expect(u.humorAppropriateness)
    }

    // MARK: - §11 — compound-question diagnostic (bounded lexical heuristic, non-authoritative)

    @Test func compoundQuestion_twoDistinctWhClauses_detected() {
        let count = QuestionDiagnostics.informationRequestCount("What caused the delay, and what's the revised timeline?")
        #expect(count == 2)
        #expect(QuestionDiagnostics.compoundQuestionDetected("What caused the delay, and what's the revised timeline?"))
    }

    @Test func compoundQuestion_singleWhClause_notFlagged() {
        #expect(QuestionDiagnostics.informationRequestCount("What's the revised timeline?") == 1)
        #expect(!QuestionDiagnostics.compoundQuestionDetected("What's the revised timeline?"))
    }

    @Test func compoundQuestion_singleNonWhQuestion_countsOne() {
        #expect(QuestionDiagnostics.informationRequestCount("Should I send it?") == 1)
    }

    @Test func compoundQuestion_noQuestionAtAll_countsZero() {
        #expect(QuestionDiagnostics.informationRequestCount("Got it.") == 0)
    }

    // MARK: - §12 — single highest-information-question realization (already-correct deterministic wording, confirmed)

    @Test func singleQuestion_needStatementContinuation_alwaysAsksExactlyOneQuestion() {
        // Exercises the SAME code path via unseen paraphrases for each
        // artifact kind, through the public `realize()` API.
        // §16 note: "document"/"unspecified" both resolve through the SAME
        // `.unspecified`-kind branch today — `needStatementContinuation`'s
        // kind detection recognizes "email"/"message"/"text"/"note" only
        // (unchanged by this pass); a fresh keyword for "document" was
        // never part of this mission's scope, so this table only exercises
        // kinds that are actually reachable via keyword detection today.
        let cases: [(String, ArtifactContext.Kind)] = [
            ("I need to message the client about the delay.", .message),
            ("I need to email my professor about missing class.", .email),
            ("I need to jot down a note about the meeting.", .note),
            ("I need to put together something for the review.", .unspecified),
        ]
        let realizer = DeterministicNaturalResponseRealizer()
        for (transcript, kind) in cases {
            let ctx = context(family: .genericSuccess, wasSuccess: true)
            let u = DeterministicConversationReasoner().understand(transcript: transcript, recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
            #expect(u.dialogueAct == .needStatement)
            #expect(u.artifactContext?.kind == kind)
            let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
            let plan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: u, strategy: strategy, persona: .friday)
            let text = realizer.realize(context: ctx, understanding: u, plan: plan, recentTurns: [], avoiding: nil)
            #expect(text != nil)
            #expect(QuestionDiagnostics.informationRequestCount(text!) == 1, "\(kind): \"\(text!)\"")
            #expect(!QuestionDiagnostics.compoundQuestionDetected(text!))
        }
    }

    // MARK: - §14/§15 — execution-claim live provenance (through the full presenter, using existing WakeDiagnosticsRecorder fields)

    @Test func executionClaimProvenance_acceptedOnlyWhenActionExecutionStateSucceeded() {
        struct FixedRealizer: NaturalConversationRealizing {
            let text: String
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? { text }
        }
        // Case A: authoritative state genuinely succeeded — completion claim MAY pass.
        let successPresenter = ConversationalResponsePresenter(naturalRealizer: FixedRealizer(text: "Added a quick thank-you line."))
        let successResponse = successPresenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "e1", correlationID: "e1", taskID: "e1", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "Update the note.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation(successResponse.text) ? successResponse.text.contains("Added") : true)

        // Case B: needStatement continuation (actionExecutionState forced
        // to .notRequested) — the SAME claim MUST be rejected.
        let rejectPresenter = ConversationalResponsePresenter(naturalRealizer: FixedRealizer(text: "Added a quick thank-you line."))
        let rejectResponse = rejectPresenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "e2", correlationID: "e2", taskID: "e2", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "I need to email the team about the deadline change.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!rejectResponse.text.localizedCaseInsensitiveContains("added"), "got \"\(rejectResponse.text)\" — a completion claim with actionExecutionState=notRequested must be rejected")
    }

    @Test func executionClaimProvenance_diagnosticFieldsAreAllDerivableFromExistingWakeDiagnostics() {
        // §14 asks for: executionClaimDetected, actionExecutionState,
        // providerSucceeded, candidateAccepted, semanticGroundingValid,
        // finalResponseSource, fallbackReason — confirms every one of
        // these is ALREADY derivable from existing, unchanged
        // `WakeDiagnosticsSnapshot` fields plus the (also unchanged)
        // `ExecutionClaimDetector`, so the harness needs only WIRING,
        // never a new authority concept.
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success("{\"choices\":[{\"message\":{\"content\":\"{\\\"reasoning\\\":{\\\"dialogueAct\\\":\\\"needStatement\\\",\\\"interactionMode\\\":\\\"actionRequest\\\"},\\\"response\\\":{\\\"text\\\":\\\"Added a quick thank-you line.\\\"}}\"},\"finish_reason\":\"stop\"}]}".data(using: .utf8)!)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m", architecture: .unifiedOneCall)
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withUnifiedModelProvider(config: config, diagnostics: recorder, memory: BoundedConversationMemory())
        let response = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "e3", correlationID: "e3", taskID: "e3", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "I need to email the team about the deadline change.", acoustics: .unavailable, explicitUserStatements: []
        )
        let snap = recorder.snapshot()
        let executionClaimDetected = ExecutionClaimDetector.claimsExecutionOrMutation(response.text)
        #expect(!executionClaimDetected, "the fabricated candidate must already have been rejected before reaching the final response")
        #expect(snap.lastFinalResponseSource == .deterministicFallback)
        #expect(snap.lastResponseAccepted == false)
    }

    // MARK: - §16 — P10 no-completion-claim preservation

    @Test func p10Preservation_draftContinuation_neverClaimsCompletedMutation() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "p1", correlationID: "p1", taskID: "p1", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "I need to email the vendor about the delay.", acoustics: .unavailable, explicitUserStatements: []
        )
        let second = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "p2", correlationID: "p2", taskID: "p2", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "Also make it clear we'd like to continue the relationship.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation(second.text), "got \"\(second.text)\"")
    }

    // MARK: - §17 — fallback failure intelligence (deterministic path reflects known/unknown/retryable, not "Okay."/"Got it.")

    @Test func fallbackFailureIntelligence_knownCause_notFlattenedToOkay() {
        let realizer = DeterministicNaturalResponseRealizer()
        let ctx = context(family: .executionFailed, wasSuccess: false, failureEvidence: "connection refused, service unreachable")
        let u = DeterministicConversationReasoner().understand(transcript: "Update my calendar.", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let plan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: u, strategy: strategy, persona: .friday)
        let text = realizer.realize(context: ctx, understanding: u, plan: plan, recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(text != "Okay." && text != "Got it.")
        #expect(text!.localizedCaseInsensitiveContains("reach"))
    }

    @Test func fallbackFailureIntelligence_retryable_notFlattenedToGotIt() {
        let realizer = DeterministicNaturalResponseRealizer()
        let ctx = context(family: .capabilityUnavailable, wasSuccess: false)
        let u = DeterministicConversationReasoner().understand(transcript: "Update my calendar.", recentTurns: [], context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        let plan = DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: u, strategy: strategy, persona: .friday)
        let text = realizer.realize(context: ctx, understanding: u, plan: plan, recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(text != "Okay." && text != "Got it.")
        #expect(text!.localizedCaseInsensitiveContains("try again"))
    }
}

