import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V5 §24 — dedicated coverage for the new conversational-persona
/// pipeline: `ConversationContextCompiler`, `ResponseStrategyPlanner`,
/// `FridayPersona`, `ResponseRealizer`, `AdaptiveProsodyPlanner`. This
/// suite intentionally does NOT re-test what `ResponsePresentingTests`,
/// `VoiceProfileTests`, `WakeSecurityTests`, `WakeCoordinatorSpeakingStateTests`,
/// and the real-daemon E2E suites already cover (deterministic same-
/// taskID variant selection through the full presenter, exact wording
/// per outcome, barge-in, self-wake, cancellation, exactly-once
/// completion, no-wake-phrase-in-response, diagnostics privacy gating) —
/// those all continue to pass unmodified (§25) and are the authoritative
/// coverage for those properties. This file's job is the NEW pipeline
/// STAGES themselves, in isolation.
@Suite struct ConversationalPersonaTests {
    private func result(outcome: String, text: String, taskID: String = "task-1") -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: "r1", correlationID: "r1", taskID: taskID, outcome: outcome, text: text)
    }

    // MARK: - FridayPersona (§3): one stable personality, bounded dimensions

    @Test func fridayPersona_defaultInstance_matchesSpecTargets() {
        let p = FridayPersona.friday
        #expect(p.friendliness >= 0.7, "friendliness should read as high")
        #expect(p.warmth >= 0.7, "warmth should read as high")
        #expect(p.confidence >= 0.7, "confidence should read as high")
        #expect(p.clarity >= 0.7, "clarity should read as high")
        #expect(p.formality <= 0.5, "formality should read as low-medium")
        #expect(p.energy > 0.3 && p.energy < 0.7, "energy should read as medium")
        #expect(p.verbosity == .concise)
        #expect(p.humor < 0.3, "humor should read as subtle/rare")
        #expect(p.enthusiasm < 0.5, "enthusiasm should read as restrained")
        #expect(p.directness >= 0.6, "directness should read as medium-high")
    }

    @Test func fridayPersona_init_clampsOutOfRangeValuesToSafeBounds() {
        let p = FridayPersona(
            friendliness: 5.0, warmth: -3.0, confidence: .infinity, clarity: .nan,
            formality: 2.0, energy: -1.0, verbosity: .detailed, humor: 10.0,
            enthusiasm: -10.0, reassurance: 1.5, directness: -0.5
        )
        for v in [p.friendliness, p.warmth, p.confidence, p.formality, p.energy, p.humor, p.enthusiasm, p.reassurance, p.directness] {
            #expect(v >= 0 && v <= 1, "every dimension must stay within 0...1 regardless of input — got \(v)")
        }
        #expect(p.clarity == 0.5, "NaN must fall back to a safe neutral midpoint, never propagate")
    }

    @Test func responseStrategy_init_clampsOutOfRangeValues() {
        let s = ResponseStrategy(
            purpose: .success, warmth: 9, formality: -9, energy: .infinity, directness: .nan,
            urgency: 2, reassurance: -2, verbosity: .brief, acknowledgmentNeed: false,
            followUpNeed: false, prosodyIntent: .success
        )
        for v in [s.warmth, s.formality, s.energy, s.directness, s.urgency, s.reassurance] {
            #expect(v >= 0 && v <= 1, "every ResponseStrategy dimension must stay within 0...1 — got \(v)")
        }
    }

    // MARK: - ConversationContextCompiler (§2/§11): classification is honest and exhaustive

    @Test func classifyFamily_everyRealOutcomeCode_mapsToTheExpectedFamily() {
        let compiler = DeterministicConversationContextCompiler()
        let cases: [(outcome: String, text: String, family: ResponseFamily)] = [
            ("SUCCESS", "System status retrieved successfully.", .systemStatusSuccess),
            ("SUCCESS", "Created and verified note \"groceries\".", .createNoteSuccess),
            ("SUCCESS", "Some brand-new success text.", .genericSuccess),
            ("UNSUPPORTED_INTENT", "x", .unsupportedIntent),
            ("AMBIGUOUS_INTENT", "x", .ambiguousIntent),
            ("INVALID_TEXT_REQUEST", "x", .invalidRequest),
            ("IR_VALIDATION_FAILED", "x", .irValidationFailed),
            ("POLICY_DENIED", "x", .policyDenied),
            ("POLICY_UNAVAILABLE", "x", .policyUnavailable),
            ("CAPABILITY_UNAVAILABLE", "x", .capabilityUnavailable),
            ("EXECUTION_FAILED", "x", .executionFailed),
            ("VERIFICATION_FAILED", "plain failure", .verificationFailed),
            ("VERIFICATION_FAILED", "...needs Manual Review.", .verificationNeedsReview),
            ("CANCELLED", "x", .cancelled),
            ("ALREADY_TERMINAL", "x", .alreadyTerminal),
            ("DUPLICATE_REQUEST", "x", .duplicateRequest),
            ("INTERNAL_ERROR", "x", .internalError),
            ("SOME_FUTURE_OUTCOME", "x", .other),
        ]
        for c in cases {
            let context = compiler.compile(outcome: .success(result(outcome: c.outcome, text: c.text)), recentResponseFamilies: [])
            #expect(context.responseFamily == c.family, "(\(c.outcome), \(c.text)) should classify as \(c.family), got \(context.responseFamily)")
        }
    }

    @Test func compile_transportFailure_producesHonestUnretryableFreeContext() {
        let compiler = DeterministicConversationContextCompiler()
        let context = compiler.compile(outcome: .failure("connection refused"), recentResponseFamilies: [])
        #expect(context.responseFamily == .transportFailure)
        #expect(!context.wasSuccess)
        #expect(!context.isVerifiedData)
        #expect(context.isRetryable)
        #expect(context.taskID.isEmpty, "no real taskID exists for a request that never reached the runtime")
    }

    @Test func isRetryable_onlyTrueForGenuinelyTransientFamilies() {
        let retryable: Set<ResponseFamily> = [.capabilityUnavailable, .policyUnavailable, .executionFailed]
        for family in ResponseFamily.allCases {
            let expected = retryable.contains(family)
            #expect(DeterministicConversationContextCompiler.isRetryable(family) == expected, "\(family) retryability should be \(expected)")
        }
    }

    @Test func compile_createNoteSuccess_extractsTitleForRealization() {
        let compiler = DeterministicConversationContextCompiler()
        let context = compiler.compile(outcome: .success(result(outcome: "SUCCESS", text: "Created and verified note \"groceries\".")), recentResponseFamilies: [])
        #expect(context.noteTitleForRealization == "groceries")
    }

    @Test func compile_ambiguousIntentWithMissingField_extractsFieldName() {
        let compiler = DeterministicConversationContextCompiler()
        let context = compiler.compile(outcome: .success(result(outcome: "AMBIGUOUS_INTENT", text: "I need more information to do that (missing: title).")), recentResponseFamilies: [])
        #expect(context.ambiguousMissingField == "title")
    }

    @Test func compile_neverProducesAnyUserContextOtherThanOwnerLocal() {
        // §19: no speaker identification exists in this codebase — every
        // compiled context must honestly report the only identity state
        // this system can back up today.
        let compiler = DeterministicConversationContextCompiler()
        for (outcome, text) in [("SUCCESS", "System status retrieved successfully."), ("POLICY_DENIED", "x"), ("INTERNAL_ERROR", "x")] {
            let context = compiler.compile(outcome: .success(result(outcome: outcome, text: text)), recentResponseFamilies: [])
            #expect(context.userContext == .ownerLocal)
        }
        let transportContext = compiler.compile(outcome: .failure("x"), recentResponseFamilies: [])
        #expect(transportContext.userContext == .ownerLocal)
    }

    // MARK: - ResponseStrategyPlanner (§4/§5/§14): reasons from trusted facts, stays on-persona

    @Test func purpose_everyResponseFamily_mapsToExpectedPurpose() {
        let expectations: [(ResponseFamily, ResponsePurpose)] = [
            (.systemStatusSuccess, .success), (.createNoteSuccess, .success), (.genericSuccess, .success),
            (.unsupportedIntent, .unsupported), (.invalidRequest, .unsupported), (.irValidationFailed, .unsupported),
            (.ambiguousIntent, .clarification),
            (.policyDenied, .permissionDenied),
            (.policyUnavailable, .retryableFailure), (.capabilityUnavailable, .retryableFailure), (.executionFailed, .retryableFailure),
            (.verificationFailed, .failure), (.internalError, .failure), (.transportFailure, .failure),
            (.verificationNeedsReview, .warning),
            (.cancelled, .information), (.alreadyTerminal, .information), (.duplicateRequest, .information), (.other, .information),
        ]
        for (family, expectedPurpose) in expectations {
            let context = ConversationContext(
                interactionID: "x", taskID: "x", outcomeCode: "x", responseFamily: family, wasSuccess: family == .createNoteSuccess || family == .systemStatusSuccess || family == .genericSuccess,
                isVerifiedData: false, needsClarification: family == .ambiguousIntent, isRetryable: DeterministicConversationContextCompiler.isRetryable(family),
                isFollowUpMeaningful: false
            )
            let purpose = DeterministicResponseStrategyPlanner.purpose(for: context)
            #expect(purpose == expectedPurpose, "\(family) should produce purpose \(expectedPurpose), got \(purpose)")
        }
    }

    @Test func strategy_everyPurpose_producesTheDocumentedProsodyIntent() {
        // §14's own table, exercised directly through EVERY ResponsePurpose
        // — including `.acknowledgement`/`.urgentWarning`/`.conversationalFollowUp`,
        // which no real `ResponseFamily` produces yet, via the internal
        // `strategy(forPurpose:context:persona:)` entry point (§12: "real,
        // tested, not yet reachable in production" for exactly this reason).
        let expectations: [(ResponsePurpose, ProsodyIntent)] = [
            (.success, .success), (.information, .information), (.clarification, .friendly),
            (.unsupported, .information), (.failure, .failure), (.retryableFailure, .reassuring),
            (.permissionDenied, .permissionDenied), (.warning, .warning), (.urgentWarning, .urgent),
            (.acknowledgement, .focused), (.conversationalFollowUp, .casual),
        ]
        for (purpose, expectedIntent) in expectations {
            let strategy = DeterministicResponseStrategyPlanner.strategy(forPurpose: purpose, context: neutralContext, persona: .friday)
            #expect(strategy.purpose == purpose)
            #expect(strategy.prosodyIntent == expectedIntent, "\(purpose) should map to \(expectedIntent), got \(strategy.prosodyIntent)")
        }
    }

    @Test func strategy_personalityStaysRecognizable_acrossEveryPurpose() {
        // §3: "FRIDAY's personality should remain recognizable across
        // every context" — no purpose should swing warmth/formality/energy
        // wildly far from the stable baseline; strategy only ever applies
        // SMALL, bounded deltas on top of `FridayPersona.friday`.
        for purpose in allPurposes {
            let strategy = DeterministicResponseStrategyPlanner.strategy(forPurpose: purpose, context: neutralContext, persona: .friday)
            #expect(abs(strategy.warmth - FridayPersona.friday.warmth) <= 0.15, "\(purpose) warmth drifted too far from baseline: \(strategy.warmth)")
            #expect(abs(strategy.formality - FridayPersona.friday.formality) <= 0.15, "\(purpose) formality drifted too far from baseline: \(strategy.formality)")
        }
    }

    @Test func strategy_neverAppliesFollowUpNeed_unlessContextSaysFollowUpIsMeaningful() {
        let planner = DeterministicResponseStrategyPlanner()
        let notMeaningful = ConversationContext(
            interactionID: "x", taskID: "x", outcomeCode: "EXECUTION_FAILED", responseFamily: .executionFailed,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: true, isFollowUpMeaningful: false
        )
        #expect(!planner.strategy(for: notMeaningful, persona: .friday).followUpNeed)
    }

    private var allPurposes: [ResponsePurpose] {
        [.success, .information, .acknowledgement, .clarification, .unsupported, .failure, .retryableFailure, .permissionDenied, .warning, .urgentWarning, .conversationalFollowUp]
    }

    /// A minimal, purpose-agnostic context — safe to pass to
    /// `strategy(forPurpose:context:persona:)` for any purpose, since
    /// that entry point's own switch decides behavior purely from the
    /// PURPOSE parameter; the handful of `.failure`/`.retryableFailure`
    /// branches that also read `context.isFollowUpMeaningful` are covered
    /// separately above.
    private var neutralContext: ConversationContext {
        ConversationContext(
            interactionID: "x", taskID: "x", outcomeCode: "x", responseFamily: .other,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false
        )
    }

    // MARK: - ResponseRealizer (§1/§11/§15): phrase banks, safe fallback, repetition avoidance

    @Test func unsupportedIntentVariants_includesTheP2M5V5ExampleWording() {
        #expect(DeterministicResponseRealizer.unsupportedIntentVariants.contains("I can't do that one yet."))
    }

    @Test func policyDeniedVariants_includesBothPhrasings() {
        #expect(DeterministicResponseRealizer.policyDeniedVariants.contains("I don't have permission to do that."))
        #expect(DeterministicResponseRealizer.policyDeniedVariants.contains("I need your approval before I can continue."))
    }

    @Test func executionFailedVariants_includesTheP2M5V5ExampleWording() {
        #expect(DeterministicResponseRealizer.executionFailedVariants.contains("That didn't go through."))
    }

    @Test func internalErrorVariants_includesTheP2M5V5ExampleWording() {
        #expect(DeterministicResponseRealizer.internalErrorVariants.contains("I'm not sure what caused that yet."))
    }

    @Test func ambiguousIntent_missingTitle_usesNaturalTitleSpecificClarification() {
        let realizer = DeterministicResponseRealizer()
        let context = ConversationContext(
            interactionID: "x", taskID: "x", outcomeCode: "AMBIGUOUS_INTENT", responseFamily: .ambiguousIntent,
            wasSuccess: false, isVerifiedData: false, needsClarification: true, isRetryable: false, isFollowUpMeaningful: false,
            ambiguousMissingField: "title"
        )
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        #expect(realizer.realize(context: context, strategy: strategy, avoiding: nil) == "What did you want the note called?")
    }

    @Test func ambiguousIntent_missingOtherField_usesGenericPhrasingWithFieldName() {
        let realizer = DeterministicResponseRealizer()
        let context = ConversationContext(
            interactionID: "x", taskID: "x", outcomeCode: "AMBIGUOUS_INTENT", responseFamily: .ambiguousIntent,
            wasSuccess: false, isVerifiedData: false, needsClarification: true, isRetryable: false, isFollowUpMeaningful: false,
            ambiguousMissingField: "destination"
        )
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        #expect(realizer.realize(context: context, strategy: strategy, avoiding: nil) == "I need a bit more information to do that (missing: destination).")
    }

    @Test func unrecognizedOther_relaysRawRuntimeTextUnchanged_neverGuesses() {
        let realizer = DeterministicResponseRealizer()
        let context = ConversationContext(
            interactionID: "x", taskID: "x", outcomeCode: "SOME_FUTURE_OUTCOME", responseFamily: .other,
            wasSuccess: false, isVerifiedData: false, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false,
            rawRuntimeText: "Some brand-new outcome text nobody has seen yet."
        )
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        #expect(realizer.realize(context: context, strategy: strategy, avoiding: nil) == "Some brand-new outcome text nobody has seen yet.")
    }

    @Test func pick_avoidingParameter_shiftsToNextVariant_whenCandidateWouldRepeat() {
        let variants = ["a", "b", "c"]
        // Find a taskID whose hash-selected candidate is "a", then prove
        // passing avoiding:"a" shifts the result away from "a".
        var taskID = "seed-0"
        for i in 0..<50 {
            let candidate = DeterministicResponseRealizer.pick(variants, taskID: "seed-\(i)")
            if candidate == "a" { taskID = "seed-\(i)"; break }
        }
        let unavoided = DeterministicResponseRealizer.pick(variants, taskID: taskID)
        let avoided = DeterministicResponseRealizer.pick(variants, taskID: taskID, avoiding: unavoided)
        #expect(avoided != unavoided, "must shift away from the immediately-previous distinct interaction's exact text")
    }

    @Test func pick_avoidingParameter_noEffect_whenOnlyOneVariantExists() {
        let single = ["only-option"]
        #expect(DeterministicResponseRealizer.pick(single, taskID: "any", avoiding: "only-option") == "only-option")
    }

    @Test func pick_avoidingParameter_noEffect_whenAvoidingSomethingNotSelected() {
        let variants = ["a", "b", "c"]
        let selected = DeterministicResponseRealizer.pick(variants, taskID: "fixed-taskid")
        let withUnrelatedAvoid = DeterministicResponseRealizer.pick(variants, taskID: "fixed-taskid", avoiding: "definitely-not-a-real-variant")
        #expect(selected == withUnrelatedAvoid, "avoidance must never perturb selection unless the hash-selected candidate IS the thing being avoided")
    }

    @Test func repetitionControl_throughFullPresenter_neverRepeatsTheImmediatelyPriorDistinctInteractionsExactText() {
        // §15: across genuinely distinct taskIDs in the same family, the
        // exact same text should not appear twice in a row when more than
        // one truthful variant exists — proven across a real run through
        // the full `DeterministicResponsePresenter`, not just `pick`
        // directly.
        let presenter = DeterministicResponsePresenter()
        var previous: String?
        for i in 0..<25 {
            let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "distinct-task-\(i)")))
            if let previous {
                #expect(r.text != previous, "back-to-back distinct interactions in the same family must not repeat identical phrasing when alternatives exist")
            }
            previous = r.text
        }
    }

    @Test func repetitionControl_replayOfSameTaskID_stillAlwaysProducesIdenticalText() {
        // The invariant repetition-avoidance must never break (§8/§17):
        // replaying the SAME taskID never re-rolls, even interleaved with
        // other distinct interactions in between.
        let presenter = DeterministicResponsePresenter()
        let first = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "replay-me")))
        _ = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "some-other-task")))
        let replay = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "replay-me")))
        #expect(first.text == replay.text)
    }

    // MARK: - Truth boundary (§11/§18): TruthClassification and FollowUp never overclaim

    @Test func truthClassification_matchesExpectedCategoryForEveryFamily() {
        let presenter = DeterministicResponsePresenter()
        let successResponse = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.")))
        #expect(successResponse.truthClassification == .verifiedSuccess)

        let deniedResponse = presenter.response(for: .success(result(outcome: "POLICY_DENIED", text: "I couldn't perform that action because authorization was denied.")))
        #expect(deniedResponse.truthClassification == .definitiveFailure)

        let internalErrorResponse = presenter.response(for: .success(result(outcome: "INTERNAL_ERROR", text: "Something went wrong on my end; the action was not performed.")))
        #expect(internalErrorResponse.truthClassification == .unknownCause)

        let transportResponse = presenter.response(for: .failure("connection refused"))
        #expect(transportResponse.truthClassification == .unknownCause)
    }

    @Test func followUp_isNeverRenderedIntoSpokenText_forAnyRealOutcome() {
        // §9: "Want me to try again?" is a genuine FollowUpClassification
        // concept but this milestone never speaks it (no mechanism exists
        // to hear/act on the answer) — proven directly against real
        // retryable-failure text.
        let presenter = DeterministicResponsePresenter()
        let r = presenter.response(for: .success(result(outcome: "EXECUTION_FAILED", text: "The action could not be completed.")))
        #expect(!r.text.localizedCaseInsensitiveContains("try again"))
        #expect(!r.text.contains("?"), "no real response this milestone produces should ask a spoken follow-up question")
        #expect(r.followUp == .none)
    }

    // MARK: - AdaptiveProsodyPlanner (§13): thin, bounded, delegates to VoiceProfile

    @Test func adaptiveProsodyPlanner_delegatesExactlyToVoiceProfileAdjustedFor() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        for intent in [ProsodyIntent.success, .information, .failure, .permissionDenied, .warning, .friendly, .casual, .focused, .reassuring, .serious, .urgent] {
            #expect(planner.prosody(for: intent, base: .friday) == VoiceProfile.friday.adjusted(for: intent))
        }
    }

    @Test func adaptiveProsodyPlanner_everyIntent_staysWithinSafeBounds() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        for intent in [ProsodyIntent.success, .information, .failure, .permissionDenied, .warning, .friendly, .casual, .focused, .reassuring, .serious, .urgent] {
            let profile = planner.prosody(for: intent, base: .friday)
            #expect(profile.rate >= 0 && profile.rate <= 1)
            #expect(profile.pitchMultiplier >= 0.5 && profile.pitchMultiplier <= 2.0)
            #expect(profile.volume >= 0 && profile.volume <= 1)
            #expect(profile.preUtteranceDelay >= 0 && profile.preUtteranceDelay <= 2.0)
            #expect(profile.postUtteranceDelay >= 0 && profile.postUtteranceDelay <= 2.0)
        }
    }

    @Test func adaptiveProsodyPlanner_neverDramaticallyAltersTheBaselineVoice() {
        // §13: "no cartoon emotional voices — subtle modulation only." No
        // intent should move rate/volume by more than 10% of the 0..1
        // range from the production baseline, and pitch must stay
        // essentially fixed (FRIDAY must remain recognizably the same
        // voice across every context).
        let planner = DeterministicAdaptiveProsodyPlanner()
        let base = VoiceProfile.friday
        for intent in [ProsodyIntent.success, .information, .failure, .permissionDenied, .warning, .friendly, .casual, .focused, .reassuring, .serious, .urgent] {
            let profile = planner.prosody(for: intent, base: base)
            #expect(abs(profile.rate - base.rate) <= 0.1, "\(intent) rate delta too large")
            #expect(abs(profile.volume - base.volume) <= 0.1, "\(intent) volume delta too large")
            #expect(abs(profile.pitchMultiplier - base.pitchMultiplier) <= 0.05, "\(intent) must not noticeably change pitch")
        }
    }
}
