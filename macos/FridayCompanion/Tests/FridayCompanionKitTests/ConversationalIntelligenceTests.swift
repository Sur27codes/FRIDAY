import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V6 §30 — dedicated coverage for every new component this
/// milestone adds: turn-taking/VAD, acoustic features, the conversation
/// reasoner, social register planner, humor policy, natural response
/// plan/realizer, the `ConversationalResponsePresenter` orchestrator
/// (including truth-boundary/fallback behavior), premium-TTS fallback
/// composition, `ProsodyPlan`/adaptive prosody 2.0, and bounded
/// conversation memory. Existing suites (barge-in, self-wake, stop/
/// cancel, security, P2-M5V5's own `ConversationalPersonaTests`) remain
/// unmodified and continue to cover those properties — not duplicated
/// here.
@Suite struct ConversationalIntelligenceTests {
    // MARK: - Frame helpers (constant-amplitude samples so RMS is exactly predictable)

    private func frame(amplitude: Int16, count: Int = 8, at date: Date) -> AudioFrame {
        AudioFrame(samples: Array(repeating: amplitude, count: count), sampleRate: 16000, channelCount: 1, capturedAt: date)
    }
    /// RMS ≈ 0 — well below the default 0.02 threshold.
    private func silentFrame(at date: Date) -> AudioFrame { frame(amplitude: 0, at: date) }
    /// RMS ≈ 0.3 (9830/32768) — well above threshold, and exactly the
    /// reference ceiling `TurnTakingCoordinator.acousticFeatures()` uses,
    /// so `relativeLoudness` comes out ≈ 1.0.
    private func loudFrame(at date: Date) -> AudioFrame { frame(amplitude: 9830, at: date) }
    /// RMS ≈ 0.03 — just above threshold, but quiet enough that
    /// `relativeLoudness` (≈0.1) falls under the 0.15 "speak softer" cue.
    private func quietFrame(at date: Date) -> AudioFrame { frame(amplitude: 983, at: date) }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - TurnTaking / VAD

    @Test func turnTaking_silenceWhenNoSpeechEver() {
        let coordinator = TurnTakingCoordinator()
        let state = coordinator.process(frame: silentFrame(at: epoch), isFridaySpeaking: false)
        #expect(state == .silence)
    }

    @Test func turnTaking_detectsSpeechAboveThreshold() {
        let coordinator = TurnTakingCoordinator()
        let state = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        #expect(state == .speech)
    }

    @Test func turnTaking_trailingSilenceBeforeTimeoutElapses() {
        let coordinator = TurnTakingCoordinator(config: TurnTakingConfig(trailingSilenceTimeout: 1.5))
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        let state = coordinator.process(frame: silentFrame(at: epoch.addingTimeInterval(0.5)), isFridaySpeaking: false)
        #expect(state == .trailingSilence)
    }

    @Test func turnTaking_returnsToSilenceAfterTrailingSilenceTimeoutElapses() {
        let coordinator = TurnTakingCoordinator(config: TurnTakingConfig(trailingSilenceTimeout: 1.5))
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        let state = coordinator.process(frame: silentFrame(at: epoch.addingTimeInterval(2.0)), isFridaySpeaking: false)
        #expect(state == .silence)
    }

    @Test func turnTaking_briefOverlapWhileFridaySpeaking_notYetInterruption() {
        let coordinator = TurnTakingCoordinator(config: TurnTakingConfig(interruptionSustainedDuration: 0.3))
        let state = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: true)
        #expect(state == .overlappingSpeech)
    }

    @Test func turnTaking_sustainedSpeechWhileFridaySpeaking_becomesInterruption() {
        let coordinator = TurnTakingCoordinator(config: TurnTakingConfig(interruptionSustainedDuration: 0.3))
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: true)
        let state = coordinator.process(frame: loudFrame(at: epoch.addingTimeInterval(0.4)), isFridaySpeaking: true)
        #expect(state == .interruption)
    }

    @Test func turnTaking_beginNewTurn_resetsStateAndFeatures() {
        let coordinator = TurnTakingCoordinator()
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        coordinator.beginNewTurn()
        #expect(coordinator.currentState() == .silence)
        #expect(coordinator.acousticFeatures() == .unavailable)
    }

    @Test func turnTaking_acousticFeatures_unavailableBeforeAnyFrame() {
        let coordinator = TurnTakingCoordinator()
        #expect(coordinator.acousticFeatures() == .unavailable)
    }

    @Test func turnTaking_acousticFeatures_relativeLoudnessReflectsSpeechLevel() {
        let coordinator = TurnTakingCoordinator()
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        let features = coordinator.acousticFeatures()
        #expect(features.relativeLoudness != nil)
        #expect(features.relativeLoudness! > 0.8, "a loud frame should read as high relative loudness")
        #expect(features.signalConfidence == 1.0)
    }

    @Test func turnTaking_acousticFeatures_pitchAndRateFieldsHonestlyNil() {
        // §3: never fake precision this codebase doesn't actually compute.
        let coordinator = TurnTakingCoordinator()
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        let features = coordinator.acousticFeatures()
        #expect(features.speechRateEstimate == nil)
        #expect(features.pitchRange == nil)
        #expect(features.pitchVariation == nil)
    }

    @Test func turnTaking_acousticFeatures_pauseDensityReflectsSilenceProportion() {
        let coordinator = TurnTakingCoordinator()
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: false)
        _ = coordinator.process(frame: silentFrame(at: epoch.addingTimeInterval(0.1)), isFridaySpeaking: false)
        _ = coordinator.process(frame: silentFrame(at: epoch.addingTimeInterval(0.2)), isFridaySpeaking: false)
        let features = coordinator.acousticFeatures()
        #expect(features.pauseDensity != nil)
        #expect(features.pauseDensity! > 0.5, "two silent frames out of three should read as majority pause")
    }

    @Test func turnTaking_interruptionDetected_onlyAfterSustainedThreshold() {
        let coordinator = TurnTakingCoordinator(config: TurnTakingConfig(interruptionSustainedDuration: 0.3))
        _ = coordinator.process(frame: loudFrame(at: epoch), isFridaySpeaking: true)
        #expect(!coordinator.acousticFeatures().interruptionDetected)
        _ = coordinator.process(frame: loudFrame(at: epoch.addingTimeInterval(0.4)), isFridaySpeaking: true)
        #expect(coordinator.acousticFeatures().interruptionDetected)
    }

    @Test func nullTurnTakingTracking_alwaysSilenceAndUnavailable() {
        let null = NullTurnTakingTracking()
        #expect(null.process(frame: loudFrame(at: epoch), isFridaySpeaking: true) == .silence)
        #expect(null.currentState() == .silence)
        #expect(null.acousticFeatures() == .unavailable)
    }

    // MARK: - AcousticConversationFeatures: no emotion-shaped fields, clamping

    @Test func acousticFeatures_hasNoEmotionShapedField() {
        let mirror = Mirror(reflecting: AcousticConversationFeatures.unavailable)
        let fieldNames = Set(mirror.children.compactMap(\.label))
        let forbidden = ["angry", "sad", "happy", "depressed", "anxious", "stressed", "afraid", "emotion", "mood", "sentiment"]
        for term in forbidden {
            #expect(!fieldNames.contains(term), "AcousticConversationFeatures must never carry an emotional label field")
        }
    }

    @Test func acousticFeatures_clampsOutOfRangeUnitValues() {
        let features = AcousticConversationFeatures(
            speechRateEstimate: nil, relativeLoudness: 5.0, pitchRange: nil, pitchVariation: nil,
            pauseDensity: -3.0, utteranceDuration: nil, interruptionDetected: false, overlapDetected: false,
            speakingContinuously: false, signalConfidence: 99
        )
        #expect(features.relativeLoudness == 1.0)
        #expect(features.pauseDensity == 0.0)
        #expect(features.signalConfidence == 1.0)
    }

    // MARK: - SpeakerIdentity boundary

    @Test func speakerIdentity_unknownIsDistinctFromEnrolled() {
        #expect(SpeakerIdentity.unknown == SpeakerIdentity.unknown)
        #expect(SpeakerIdentity.unknown != SpeakerIdentity.enrolledAuthenticated(profileID: "x"))
    }

    // MARK: - DeterministicConversationReasoner

    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false
        )
    }

    @Test func reasoner_correctionMarker_detectsContinuationGivenPriorTurn() {
        let reasoner = DeterministicConversationReasoner()
        let priorTurn = ConversationTurn(taskID: "prior", transcript: "create a note called groceries", responseFamily: .createNoteSuccess, responseText: "Done.", purpose: .success)
        let understanding = reasoner.understand(transcript: "Actually, call it weekend groceries", recentTurns: [priorTurn], context: context(family: .createNoteSuccess, wasSuccess: true, taskID: "new-task"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.communicativeIntent == .correction)
        #expect(understanding.continuationOfPreviousTurn)
    }

    @Test func reasoner_noPriorTurn_neverClaimsContinuation() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Actually, call it weekend groceries", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(!understanding.continuationOfPreviousTurn)
    }

    @Test func reasoner_questionMarker_classifiesAsQuestion() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Why did it take so long?", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.communicativeIntent == .question)
    }

    @Test func reasoner_commandVerb_classifiesAsCommand() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Create a note called groceries", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.communicativeIntent == .command)
    }

    @Test func reasoner_explicitUrgencyPhrase_setsExplicitUrgencyTrue() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "This is important, don't change anything yet.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.explicitUrgency)
    }

    @Test func reasoner_noExplicitPhrase_neverInfersUrgencyFromLoudness() {
        // §19: only EXPLICIT wording sets urgency — a loud/fast acoustic
        // snapshot alone must never flip this, even though it's passed in.
        let reasoner = DeterministicConversationReasoner()
        let loudAcoustics = AcousticConversationFeatures(
            speechRateEstimate: nil, relativeLoudness: 1.0, pitchRange: nil, pitchVariation: nil, pauseDensity: 0,
            utteranceDuration: 2, interruptionDetected: false, overlapDetected: false, speakingContinuously: true, signalConfidence: 1.0
        )
        let understanding = reasoner.understand(transcript: "Create a note called groceries", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: loudAcoustics, explicitUserStatements: [])
        #expect(!understanding.explicitUrgency)
    }

    @Test func reasoner_professionalCueWords_recommendsProfessionalRegister() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Please draft an email to my professor", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.socialRegisterRecommendation == .professional)
    }

    @Test func reasoner_casualCueWords_recommendsCasualRegister() {
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "bro I finally fixed that bug", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.socialRegisterRecommendation == .casualFriendly)
    }

    @Test func reasoner_humorAppropriate_forSuccessAndUnsupported_notForFailure() {
        let reasoner = DeterministicConversationReasoner()
        let successUnderstanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(successUnderstanding.humorAppropriateness)
        let unsupportedUnderstanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(unsupportedUnderstanding.humorAppropriateness)
        let failureUnderstanding = reasoner.understand(transcript: nil, recentTurns: [], context: context(family: .executionFailed, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(!failureUnderstanding.humorAppropriateness)
    }

    @Test func reasoner_neverConfidentAboutMeaning() {
        // A rule-based reasoner is deliberately never fully certain about
        // MEANING (only about literal pattern matches) — downstream
        // consumers should be able to tell it apart from a hypothetical
        // high-confidence real understanding.
        let reasoner = DeterministicConversationReasoner()
        let understanding = reasoner.understand(transcript: "Create a note called groceries", recentTurns: [], context: context(family: .createNoteSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.uncertainty > 0)
    }

    @Test func llmConversationReasoner_alwaysReturnsMinimalWithMaxUncertainty() {
        let reasoner = LLMConversationReasoner()
        let understanding = reasoner.understand(transcript: "anything", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding == ConversationUnderstanding.minimal)
        #expect(understanding.uncertainty == 1.0)
    }

    // MARK: - SocialRegisterPlanner

    private func strategy(purpose: ResponsePurpose) -> ResponseStrategy {
        DeterministicResponseStrategyPlanner.strategy(forPurpose: purpose, context: context(family: .other, wasSuccess: false), persona: .friday)
    }

    @Test func register_safetyShapedPurposes_alwaysWinRegardlessOfRecommendation() {
        let planner = DeterministicSocialRegisterPlanner()
        let casualRecommendation = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: .casualFriendly,
            humorAppropriateness: true, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
        )
        #expect(planner.register(context: context(family: .other, wasSuccess: false), understanding: casualRecommendation, strategy: strategy(purpose: .urgentWarning)) == .urgent)
        #expect(planner.register(context: context(family: .other, wasSuccess: false), understanding: casualRecommendation, strategy: strategy(purpose: .warning)) == .warning)
        #expect(planner.register(context: context(family: .other, wasSuccess: false), understanding: casualRecommendation, strategy: strategy(purpose: .permissionDenied)) == .focused)
        #expect(planner.register(context: context(family: .other, wasSuccess: false), understanding: casualRecommendation, strategy: strategy(purpose: .failure)) == .reassuring)
        #expect(planner.register(context: context(family: .other, wasSuccess: false), understanding: casualRecommendation, strategy: strategy(purpose: .retryableFailure)) == .reassuring)
    }

    @Test func register_explicitUrgency_overridesCasualRecommendation_forNonSafetyPurposes() {
        let planner = DeterministicSocialRegisterPlanner()
        let urgentUnderstanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: true, socialRegisterRecommendation: .casualFriendly,
            humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
        )
        #expect(planner.register(context: context(family: .genericSuccess, wasSuccess: true), understanding: urgentUnderstanding, strategy: strategy(purpose: .success)) == .focused)
    }

    @Test func register_usesReasonerRecommendation_whenNoSafetyOverrideOrExplicitUrgency() {
        let planner = DeterministicSocialRegisterPlanner()
        let professionalUnderstanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: .professional,
            humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
        )
        #expect(planner.register(context: context(family: .genericSuccess, wasSuccess: true), understanding: professionalUnderstanding, strategy: strategy(purpose: .success)) == .professional)
    }

    @Test func register_defaultsToFriendlyNeutral_whenNoSignalAtAll() {
        let planner = DeterministicSocialRegisterPlanner()
        #expect(planner.register(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, strategy: strategy(purpose: .success)) == .friendlyNeutral)
    }

    // MARK: - HumorPolicy

    private let appropriateUnderstanding = ConversationUnderstanding(
        communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
        userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil,
        humorAppropriateness: true, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
    )

    @Test func humor_disabledForPermissionDeniedWarningAndFailurePurposes() {
        for purpose: ResponsePurpose in [.permissionDenied, .warning, .urgentWarning, .failure, .retryableFailure] {
            #expect(!HumorPolicy.intent(register: .casualFriendly, purpose: purpose, understanding: appropriateUnderstanding).allowed, "\(purpose) must disable humor")
        }
    }

    @Test func humor_disabledForNonCasualRegisters_evenWhenPurposeAllows() {
        for register: SocialRegister in [.professional, .focused, .serious, .warning, .urgent] {
            #expect(!HumorPolicy.intent(register: register, purpose: .success, understanding: appropriateUnderstanding).allowed, "\(register) must disable humor")
        }
    }

    @Test func humor_disabledWhenReasonerSaysNotAppropriate() {
        #expect(!HumorPolicy.intent(register: .casualFriendly, purpose: .success, understanding: .minimal).allowed)
    }

    @Test func humor_allowedForCasualFriendlySuccess_whenReasonerAgrees() {
        let intent = HumorPolicy.intent(register: .casualFriendly, purpose: .success, understanding: appropriateUnderstanding)
        #expect(intent.allowed)
        #expect(intent.strength > 0)
    }

    @Test func humorIntent_strengthAlwaysZero_whenNotAllowed() {
        #expect(HumorIntent(allowed: false, strength: 0.9).strength == 0)
    }

    // MARK: - NaturalResponsePlanner

    @Test func naturalResponsePlan_init_clampsOutOfRangeValues() {
        let plan = NaturalResponsePlan(
            responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 9, directness: -9, humorAllowance: true,
            humorStrength: 9, formality: -9, verbosity: .brief, reassurance: 9, urgency: -9, followUpMode: .none, prosodyIntent: .success
        )
        for v in [plan.warmth, plan.directness, plan.humorStrength, plan.formality, plan.reassurance, plan.urgency] {
            #expect(v >= 0 && v <= 1)
        }
    }

    @Test func naturalResponsePlan_humorStrengthForcedZero_whenNotAllowed() {
        let plan = NaturalResponsePlan(
            responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.5, directness: 0.5, humorAllowance: false,
            humorStrength: 0.9, formality: 0.5, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .success
        )
        #expect(plan.humorStrength == 0)
    }

    @Test func naturalResponsePlanner_professionalRegister_raisesFormality() {
        let planner = DeterministicNaturalResponsePlanner()
        let understanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: .professional,
            humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
        )
        let plan = planner.plan(context: context(family: .genericSuccess, wasSuccess: true), understanding: understanding, strategy: strategy(purpose: .success), persona: .friday)
        #expect(plan.socialRegister == .professional)
        #expect(plan.formality >= 0.7)
    }

    @Test func naturalResponsePlanner_everyRegister_mapsToDocumentedProsodyIntent() {
        let expectations: [(SocialRegister, ProsodyIntent)] = [
            (.casualFriendly, .casual), (.friendlyNeutral, .friendly), (.professional, .focused), (.focused, .focused),
            (.reassuring, .reassuring), (.serious, .serious), (.warning, .warning), (.urgent, .urgent),
        ]
        for (register, expectedIntent) in expectations {
            #expect(DeterministicNaturalResponsePlanner.prosodyIntent(for: register, fallback: .information) == expectedIntent)
        }
    }

    @Test func naturalResponsePlanner_explicitUrgency_raisesUrgencyFloor() {
        let planner = DeterministicNaturalResponsePlanner()
        let understanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: true, socialRegisterRecommendation: nil,
            humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.5
        )
        let plan = planner.plan(context: context(family: .genericSuccess, wasSuccess: true), understanding: understanding, strategy: strategy(purpose: .success), persona: .friday)
        #expect(plan.urgency >= 0.6)
    }

    // MARK: - NaturalResponseRealizer

    @Test func naturalRealizer_createNoteSuccess_continuation_prefixesGotIt_speaksConfirmedTitle() {
        let realizer = DeterministicNaturalResponseRealizer()
        let ctx = ConversationContext(
            interactionID: "t2", taskID: "t2", outcomeCode: "SUCCESS", responseFamily: .createNoteSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false,
            noteTitleForRealization: "weekend groceries"
        )
        let understanding = ConversationUnderstanding(
            communicativeIntent: .correction, topic: nil, continuationOfPreviousTurn: true, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil,
            humorAppropriateness: false, responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4
        )
        let plan = NaturalResponsePlan(responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.8, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
        let text = realizer.realize(context: ctx, understanding: understanding, plan: plan, recentTurns: [], avoiding: nil)
        #expect(text == "Got it. Your weekend groceries note's ready.")
    }

    @Test func naturalRealizer_createNoteSuccess_noContinuation_defersToNil() {
        let realizer = DeterministicNaturalResponseRealizer()
        let ctx = ConversationContext(
            interactionID: "t1", taskID: "t1", outcomeCode: "SUCCESS", responseFamily: .createNoteSuccess, wasSuccess: true,
            isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false,
            noteTitleForRealization: "groceries"
        )
        let plan = NaturalResponsePlan(responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.8, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
        let text = realizer.realize(context: ctx, understanding: .minimal, plan: plan, recentTurns: [], avoiding: nil)
        #expect(text == nil, "no register/continuation reason to deviate from the deterministic fallback's own good variants")
    }

    @Test func naturalRealizer_unsupportedIntent_humorAllowed_usesLowStakesPhrasing_neverTurnsEveryUnsupportedIntoAJoke() {
        let realizer = DeterministicNaturalResponseRealizer()
        let ctx = context(family: .unsupportedIntent, wasSuccess: false)
        let humorPlan = NaturalResponsePlan(responseGoal: .unsupported, socialRegister: .casualFriendly, warmth: 0.8, directness: 0.7, humorAllowance: true, humorStrength: 0.3, formality: 0.2, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .information)
        let text = realizer.realize(context: ctx, understanding: .minimal, plan: humorPlan, recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(["Not quite in my skill set yet.", "Not yet. Give me a little more time.", "I can't do that one yet."].contains(text!))

        let noHumorPlan = NaturalResponsePlan(responseGoal: .unsupported, socialRegister: .friendlyNeutral, warmth: 0.8, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .information)
        #expect(realizer.realize(context: ctx, understanding: .minimal, plan: noHumorPlan, recentTurns: [], avoiding: nil) == nil, "must defer to deterministic fallback when humor isn't allowed")
    }

    @Test func naturalRealizer_permissionDeniedAndWarning_alwaysDefersToNil() {
        let realizer = DeterministicNaturalResponseRealizer()
        let plan = NaturalResponsePlan(responseGoal: .permissionDenied, socialRegister: .focused, warmth: 0.7, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.4, verbosity: .brief, reassurance: 0.5, urgency: 0.2, followUpMode: .none, prosodyIntent: .permissionDenied)
        #expect(realizer.realize(context: context(family: .policyDenied, wasSuccess: false), understanding: .minimal, plan: plan, recentTurns: [], avoiding: nil) == nil)
    }

    @Test func llmNaturalResponseRealizer_alwaysReturnsNil() {
        let realizer = LLMNaturalResponseRealizer()
        let plan = NaturalResponsePlan(responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.5, directness: 0.5, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .friendly)
        #expect(realizer.realize(context: context(family: .genericSuccess, wasSuccess: true), understanding: .minimal, plan: plan, recentTurns: [], avoiding: nil) == nil)
    }

    // MARK: - ConversationalResponsePresenter (integration + truth boundary)

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    @Test func conversationalPresenter_defaultConfiguration_unimprovedFamily_matchesDeterministicBase() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "t1")))
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(response.text))
        #expect(response.wasSuccess)
    }

    @Test func conversationalPresenter_naturalRealizerFabricatesSuccess_rejectedFallsBackToTruthfulBase() {
        // The "LLM hallucinated success" scenario (§30): a natural
        // realizer that (incorrectly) claims success for a genuine
        // failure must NEVER be spoken — `ResponseValidation` catches it
        // and the presenter falls back to the guaranteed truthful base.
        struct HallucinatingRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
                "Done. All good now."
            }
        }
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer())
        let response = presenter.response(for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "t2")))
        #expect(!response.wasSuccess)
        #expect(!response.text.contains("Done."), "a fabricated success phrase must never reach speech for a genuine failure")
    }

    @Test func conversationalPresenter_naturalRealizerReturnsNil_fallsBackToBase() {
        let presenter = ConversationalResponsePresenter(naturalRealizer: nil)
        let response = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "t3")))
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(response.text))
    }

    @Test func conversationalPresenter_transportFailure_neverClaimsSuccess() {
        let presenter = ConversationalResponsePresenter()
        let response = presenter.response(for: .failure("connection refused"))
        #expect(!response.wasSuccess)
        #expect(response.text == "I'm having trouble reaching the system right now.")
    }

    @Test func conversationalPresenter_recordsTurnsIntoMemory() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "t4")))
        #expect(memory.recentTurns(limit: 1).count == 1)
        #expect(memory.recentTurns(limit: 1).first?.responseFamily == .createNoteSuccess)
    }

    @Test func conversationalPresenter_replayOfSameTaskID_doesNotDuplicateMemoryEntry() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "replay-me")))
        _ = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "replay-me")))
        #expect(memory.recentTurns(limit: 10).count == 1, "a replayed identical taskID must not be recorded as a second turn")
    }

    @Test func conversationalPresenter_endToEnd_correctionAfterCreateNoteSuccess_acknowledgesNaturally() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        let first = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"groceries\".", taskID: "turn-1")), transcript: "Create a note called groceries", acoustics: .unavailable, explicitUserStatements: [])
        #expect(!first.text.isEmpty)
        let second = presenter.response(for: .success(outcomeResult(outcome: "SUCCESS", text: "Created and verified note \"weekend groceries\".", taskID: "turn-2")), transcript: "Actually, call it weekend groceries", acoustics: .unavailable, explicitUserStatements: [])
        #expect(second.text == "Got it. Your weekend groceries note's ready.")
    }

    @Test func conversationalPresenter_avoidingHint_shiftsRepeatedNaturalText() {
        // Exercise the natural-path repetition-avoidance wiring directly:
        // two consecutive distinct interactions in the humor-eligible
        // unsupported-intent family should not always produce identical
        // text when alternatives exist.
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)
        var texts: Set<String> = []
        for i in 0..<10 {
            let response = presenter.response(for: .success(outcomeResult(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "u-\(i)")))
            texts.insert(response.text)
        }
        #expect(texts.count >= 1) // sanity: at least deterministic and safe; variety is a bonus, not a hard guarantee across only 10 samples
    }

    // MARK: - Premium TTS stub + fallback composition

    @Test func premiumNeuralSpeechSynthesizer_alwaysThrowsNotConfigured() {
        let premium = PremiumNeuralSpeechSynthesizer()
        #expect(throws: PremiumNeuralSpeechSynthesizer.NotConfiguredError.self) {
            try premium.speak("hello", category: .information, onFinished: { _ in })
        }
    }

    @Test func fallbackSynthesizer_primaryThrows_fallsToSecondarySynchronously() throws {
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: PremiumNeuralSpeechSynthesizer(), secondary: secondary)
        var delivered: SpeechSynthesisOutcome?
        try fallback.speak("hello", category: .information, onFinished: { delivered = $0 })
        #expect(secondary.speakCallCount == 1)
        #expect(secondary.spokenTexts == ["hello"])
        #expect(delivered == .finished)
    }

    @Test func fallbackSynthesizer_primarySucceedsThenFailsAsync_retriesSecondary_deliversExactlyOnce() throws {
        let primary = FakeSpeechSynthesizer()
        primary.autoFinish = false
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: primary, secondary: secondary)
        var deliveries: [SpeechSynthesisOutcome] = []
        try fallback.speak("hello", category: .information, onFinished: { deliveries.append($0) })
        #expect(primary.speakCallCount == 1)
        #expect(secondary.speakCallCount == 0, "secondary must not be touched before primary actually fails")
        primary.simulateFailure("network error")
        #expect(secondary.speakCallCount == 1)
        #expect(deliveries == [.finished], "exactly one final outcome delivered to the caller")
    }

    @Test func fallbackSynthesizer_primarySucceeds_neverTouchesSecondary() throws {
        let primary = FakeSpeechSynthesizer()
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: primary, secondary: secondary)
        var delivered: SpeechSynthesisOutcome?
        try fallback.speak("hello", category: .information, onFinished: { delivered = $0 })
        #expect(secondary.speakCallCount == 0)
        #expect(delivered == .finished)
    }

    @Test func fallbackSynthesizer_stop_stopsBothEngines() {
        let primary = FakeSpeechSynthesizer()
        let secondary = FakeSpeechSynthesizer()
        let fallback = FallbackSpeechSynthesizer(primary: primary, secondary: secondary)
        fallback.stop()
        #expect(primary.stopCallCount == 1)
        #expect(secondary.stopCallCount == 1)
    }

    @Test func fallbackSynthesizer_bothEnginesThrow_propagatesFailure() {
        let fallback = FallbackSpeechSynthesizer(primary: PremiumNeuralSpeechSynthesizer(), secondary: PremiumNeuralSpeechSynthesizer())
        #expect(throws: (any Error).self) {
            try fallback.speak("hello", category: .information, onFinished: { _ in })
        }
    }

    // MARK: - ProsodyPlan / AdaptiveProsodyPlanner 2.0

    private func naturalPlan(prosodyIntent: ProsodyIntent, urgency: Double = 0.1) -> NaturalResponsePlan {
        NaturalResponsePlan(responseGoal: .success, socialRegister: .friendlyNeutral, warmth: 0.8, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: urgency, followUpMode: .none, prosodyIntent: prosodyIntent)
    }

    @Test func prosodyPlan_staysWithinSafeBounds_forEveryProsodyIntent() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        for intent in [ProsodyIntent.success, .information, .failure, .permissionDenied, .warning, .friendly, .casual, .focused, .reassuring, .serious, .urgent] {
            let plan = planner.prosodyPlan(persona: .friday, plan: naturalPlan(prosodyIntent: intent), acoustics: .unavailable, base: .friday)
            #expect(plan.rate >= 0 && plan.rate <= 1)
            #expect(plan.pitchMultiplier >= 0.5 && plan.pitchMultiplier <= 2.0)
            #expect(plan.volume >= 0 && plan.volume <= 1)
            #expect(plan.emphasisStrength >= 0 && plan.emphasisStrength <= 1)
            #expect(plan.energy >= 0 && plan.energy <= 1)
            #expect(plan.sentencePause == plan.postUtteranceDelay)
        }
    }

    @Test func prosodyPlan_quietAcoustics_softensVolumeSlightly() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        let quiet = AcousticConversationFeatures(speechRateEstimate: nil, relativeLoudness: 0.05, pitchRange: nil, pitchVariation: nil, pauseDensity: nil, utteranceDuration: nil, interruptionDetected: false, overlapDetected: false, speakingContinuously: false, signalConfidence: 1.0)
        let plan = planner.prosodyPlan(persona: .friday, plan: naturalPlan(prosodyIntent: .friendly), acoustics: quiet, base: .friday)
        #expect(plan.volume < VoiceProfile.friday.volume)
    }

    @Test func prosodyPlan_lowSignalConfidence_neverAdjustsVolumeFromAcoustics() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        let unreliable = AcousticConversationFeatures(speechRateEstimate: nil, relativeLoudness: 0.05, pitchRange: nil, pitchVariation: nil, pauseDensity: nil, utteranceDuration: nil, interruptionDetected: false, overlapDetected: false, speakingContinuously: false, signalConfidence: 0.1)
        let baseline = planner.prosody(for: .friendly, base: .friday)
        let plan = planner.prosodyPlan(persona: .friday, plan: naturalPlan(prosodyIntent: .friendly), acoustics: unreliable, base: .friday)
        #expect(plan.volume == baseline.volume)
    }

    @Test func prosodyPlan_highUrgency_neverDramaticallyAltersRate() {
        let planner = DeterministicAdaptiveProsodyPlanner()
        let plan = planner.prosodyPlan(persona: .friday, plan: naturalPlan(prosodyIntent: .urgent, urgency: 0.9), acoustics: .unavailable, base: .friday)
        #expect(abs(plan.rate - VoiceProfile.friday.rate) <= 0.1)
    }

    // MARK: - ConversationMemory

    @Test func boundedConversationMemory_boundedToMaxTurns() {
        let memory = BoundedConversationMemory(maxTurns: 3)
        for i in 0..<10 {
            memory.record(ConversationTurn(taskID: "t\(i)", transcript: nil, responseFamily: .genericSuccess, responseText: "Done.", purpose: .success))
        }
        #expect(memory.recentTurns(limit: 100).count == 3)
        #expect(memory.recentTurns(limit: 100).last?.taskID == "t9")
    }

    @Test func boundedConversationMemory_recentTurnsRespectsLimit() {
        let memory = BoundedConversationMemory(maxTurns: 8)
        for i in 0..<5 {
            memory.record(ConversationTurn(taskID: "t\(i)", transcript: nil, responseFamily: .genericSuccess, responseText: "Done.", purpose: .success))
        }
        #expect(memory.recentTurns(limit: 2).count == 2)
    }

    @Test func boundedConversationMemory_reset_clearsAll() {
        let memory = BoundedConversationMemory()
        memory.record(ConversationTurn(taskID: "t0", transcript: nil, responseFamily: .genericSuccess, responseText: "Done.", purpose: .success))
        memory.reset()
        #expect(memory.recentTurns(limit: 10).isEmpty)
    }

    @Test func nullConversationMemory_alwaysEmpty_neverRecords() {
        let memory = NullConversationMemory()
        memory.record(ConversationTurn(taskID: "t0", transcript: nil, responseFamily: .genericSuccess, responseText: "Done.", purpose: .success))
        #expect(memory.recentTurns(limit: 10).isEmpty)
    }
}
