import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-S3 §31 — dedicated coverage for CONTEXTUAL RELEVANCE,
/// CONVERSATIONAL CONTINUITY, NATURALNESS, and SOCIAL INTELLIGENCE.
/// Every test here is about conversational QUALITY (§1-§20) — none of
/// them touch authority/correctness, which stays covered by the earlier
/// S/S2/S2.1/S2.2 test files (P2-M5 correctness FREEZE, unchanged).
@Suite struct ContextualRelevanceAndSocialIntelligenceTests {
    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private let reasoner = DeterministicConversationReasoner()

    /// Derives a real, fully-formed `NaturalResponsePlan` the same way
    /// production does — via the actual planner — rather than hand-
    /// constructing one (its many fields/clamping are an implementation
    /// detail this test file shouldn't have to track).
    private func plan(context: ConversationContext, understanding: ConversationUnderstanding) -> NaturalResponsePlan {
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: context, persona: .friday)
        return DeterministicNaturalResponsePlanner().plan(context: context, understanding: understanding, strategy: strategy, persona: .friday)
    }

    // MARK: - §4/§25: topic continuity + topic shift

    @Test func topicContinuity_bugOrIssue_carriesForwardAcrossAPlainFollowUpStatement() {
        let turn1 = reasoner.understand(transcript: "I finally fixed that bug.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(turn1.activeTopic == .bugOrIssue)
        let recorded = ConversationTurn(taskID: "t1", transcript: "I finally fixed that bug.", responseFamily: .genericSuccess, responseText: "Acknowledged.", purpose: .success, activeTopic: turn1.activeTopic, artifactContext: turn1.artifactContext, pragmaticResponseAct: turn1.pragmaticResponseAct)
        let turn2 = reasoner.understand(transcript: "It was one environment variable.", recentTurns: [recorded], context: context(family: .genericSuccess, wasSuccess: true, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(turn2.turnRelation == .continuation)
        #expect(turn2.activeTopic == .bugOrIssue)
    }

    @Test func topicShift_unrelatedActionRequest_doesNotInheritThePriorTopic() {
        let priorTurn = ConversationTurn(taskID: "t1", transcript: "I finally fixed that bug.", responseFamily: .genericSuccess, responseText: "Acknowledged.", purpose: .success, activeTopic: .bugOrIssue, artifactContext: nil, pragmaticResponseAct: .celebrate)
        // §25 — a genuinely new dialogue act (a fresh action request)
        // must never silently keep the old topic alive.
        let understanding = reasoner.understand(transcript: "Can you order me a pizza?", recentTurns: [priorTurn], context: context(family: .unsupportedIntent, wasSuccess: false, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.activeTopic != .bugOrIssue)
        #expect(understanding.turnRelation != .continuation)
    }

    // MARK: - §5/§6: active artifact continuity + needStatement continuation

    @Test func needStatement_establishesAnEmailArtifact() {
        let understanding = reasoner.understand(transcript: "I need to email my professor about missing class.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .needStatement)
        #expect(understanding.artifactContext?.kind == .email)
        #expect(understanding.activeTopic == .draftOrMessage)
    }

    @Test func needStatementContinuation_wordingVariesByArtifactKind() {
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let realizer = DeterministicNaturalResponseRealizer()
        for (kind, expectedSubstring) in [(ArtifactContext.Kind.email, "tell them"), (.note, "should it say"), (.message, "want it to say"), (.document, "include")] {
            let understanding = ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
                dialogueAct: .needStatement, interactionMode: .actionRequest, actionExecutionState: .notRequested,
                artifactContext: ArtifactContext(kind: kind)
            )
            let text = realizer.realize(context: ctx, understanding: understanding, plan: plan(context: ctx, understanding: understanding), recentTurns: [], avoiding: nil)
            #expect(text?.lowercased().contains(expectedSubstring) == true, "\(kind) → \(String(describing: text))")
        }
    }

    // MARK: - §7/§8: styleRefinement continuity + multi-turn style state ("latest wins")

    @Test func styleRefinement_carriesForwardTheArtifactKindFromNeedStatement() {
        let need = reasoner.understand(transcript: "I need to email my professor about missing class.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        let recorded = ConversationTurn(taskID: "t1", transcript: nil, responseFamily: .genericSuccess, responseText: "x", purpose: .success, activeTopic: need.activeTopic, artifactContext: need.artifactContext, pragmaticResponseAct: need.pragmaticResponseAct)
        let refine = reasoner.understand(transcript: "Make it a little less formal.", recentTurns: [recorded], context: context(family: .genericSuccess, wasSuccess: true, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(refine.dialogueAct == .styleRefinement)
        #expect(refine.artifactContext?.kind == .email) // carried forward, not lost
        #expect(refine.artifactContext?.requestedStyle == .casual)
    }

    @Test func multiTurnStyleState_latestExplicitRefinementWins() {
        // First refinement: casual. Second refinement (later turn):
        // professional. §8 — the SECOND, more recent one must win.
        let afterCasual = ConversationTurn(taskID: "t1", transcript: nil, responseFamily: .genericSuccess, responseText: "x", purpose: .success, activeTopic: .draftOrMessage, artifactContext: ArtifactContext(kind: .email, requestedStyle: .casual), pragmaticResponseAct: .applyStyleRefinement)
        let understanding = reasoner.understand(transcript: "Actually, keep this professional.", recentTurns: [afterCasual], context: context(family: .genericSuccess, wasSuccess: true, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.artifactContext?.requestedStyle == .professional)
    }

    @Test func multiTurnStyleState_persistsWhenALaterTurnNamesNoNewStyle() {
        // A styleRefinement-flavored turn whose OWN wording names no
        // specific style must keep whatever was already established, not
        // silently drop it to `nil`.
        let afterProfessional = ConversationTurn(taskID: "t1", transcript: nil, responseFamily: .genericSuccess, responseText: "x", purpose: .success, activeTopic: .draftOrMessage, artifactContext: ArtifactContext(kind: .email, requestedStyle: .professional), pragmaticResponseAct: .applyStyleRefinement)
        let understanding = reasoner.understand(transcript: "Tone it down a bit.", recentTurns: [afterProfessional], context: context(family: .genericSuccess, wasSuccess: true, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .styleRefinement)
        #expect(understanding.artifactContext?.requestedStyle == .professional)
    }

    @Test func styleRefinementContinuation_wordingVariesByRequestedStyle() {
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let realizer = DeterministicNaturalResponseRealizer()
        let cases: [(ArtifactContext.Style?, String)] = [(.casual, "casual"), (.professional, "professional"), (.concise, "shorten"), (nil, "adjust the tone")]
        for (style, expectedSubstring) in cases {
            let understanding = ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
                dialogueAct: .styleRefinement, interactionMode: .actionRequest, actionExecutionState: .notRequested,
                artifactContext: ArtifactContext(kind: .email, requestedStyle: style)
            )
            let text = realizer.realize(context: ctx, understanding: understanding, plan: plan(context: ctx, understanding: understanding), recentTurns: [], avoiding: nil)
            #expect(text?.lowercased().contains(expectedSubstring) == true, "\(String(describing: style)) → \(String(describing: text))")
        }
    }

    // MARK: - §23 generalization: unseen wording for the same categories

    @Test func generalization_soundLessStiff_classifiesAsStyleRefinementWithCasualTarget() {
        let understanding = reasoner.understand(transcript: "Make that sound less stiff.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .styleRefinement)
        #expect(understanding.artifactContext?.requestedStyle == .casual)
    }

    @Test func generalization_keepThisProfessional_classifiesAsStyleRefinementWithProfessionalTarget() {
        let understanding = reasoner.understand(transcript: "Actually, keep this professional.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.dialogueAct == .styleRefinement)
        #expect(understanding.artifactContext?.requestedStyle == .professional)
    }

    // MARK: - §10 pragmatic response act

    @Test func pragmaticResponseAct_mapsEachDialogueActToTheExpectedSuggestion() {
        let cases: [(String, ResponseFamily, Bool, PragmaticResponseAct)] = [
            ("I finally fixed that bug.", .genericSuccess, true, .celebrate),
            ("I need to email my professor about missing class.", .genericSuccess, true, .continueDraft),
            ("Make it less formal.", .genericSuccess, true, .applyStyleRefinement),
            ("This is important. Don't change anything yet.", .genericSuccess, true, .confirmConstraint),
            ("Why?", .policyDenied, false, .explain),
            ("Hey, good morning.", .genericSuccess, true, .greeting),
            ("Talk soon.", .genericSuccess, true, .farewell),
            ("No, I meant the first note.", .genericSuccess, true, .clarify),
        ]
        for (transcript, family, wasSuccess, expected) in cases {
            let understanding = reasoner.understand(transcript: transcript, recentTurns: [], context: context(family: family, wasSuccess: wasSuccess), acoustics: .unavailable, explicitUserStatements: [])
            #expect(understanding.pragmaticResponseAct == expected, "\"\(transcript)\" → \(String(describing: understanding.pragmaticResponseAct))")
        }
    }

    @Test func pragmaticResponseAct_userReportedProblem_suggestsCommiserate() {
        let understanding = reasoner.understand(transcript: "Production is down now.", recentTurns: [], context: context(family: .genericSuccess, wasSuccess: true), acoustics: .unavailable, explicitUserStatements: [])
        #expect(understanding.pragmaticResponseAct == .commiserate)
    }

    // MARK: - §11/§28 repetition avoidance

    @Test func pick_avoidingAny_skipsEveryRecentlyUsedVariant() {
        let variants = ["A", "B", "C", "D"]
        let hashSelected = DeterministicResponseRealizer.pick(variants, taskID: "same-task")
        // Avoid everything except one specific survivor; the function
        // must return exactly that survivor, never one of the avoided.
        let survivor = variants.first { $0 != hashSelected } ?? "B"
        let avoided = variants.filter { $0 != survivor }
        let result = DeterministicResponseRealizer.pick(variants, taskID: "same-task", avoidingAny: avoided)
        #expect(result == survivor)
    }

    @Test func pick_avoidingAny_fallsBackToHashSelectionWhenEveryVariantIsAvoided() {
        let variants = ["A", "B"]
        let result = DeterministicResponseRealizer.pick(variants, taskID: "t", avoidingAny: variants)
        #expect(variants.contains(result)) // never crashes, never returns ""
    }

    @Test func conversationalAcknowledgment_doesNotRepeatWithinTheRecentWindow() {
        // Three consecutive negative-userReportedState turns, sharing the
        // SAME taskID (worst case for the plain hash-only selector) —
        // the repetition-avoidance overload must still avoid repeating
        // any of the last two turns' texts.
        let ctx = context(family: .genericSuccess, wasSuccess: true, taskID: "same-task")
        let realizer = DeterministicNaturalResponseRealizer()
        var recent: [ConversationTurn] = []
        var seen: [String] = []
        for i in 0..<3 {
            let understanding = ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
                dialogueAct: .statement, interactionMode: .conversational, actionExecutionState: .notRequested,
                userReportedState: UserReportedState(polarity: .negative, source: .userReported)
            )
            let text = realizer.realize(context: ctx, understanding: understanding, plan: plan(context: ctx, understanding: understanding), recentTurns: recent, avoiding: nil) ?? ""
            if !seen.isEmpty {
                #expect(!seen.suffix(2).contains(text), "turn \(i) repeated a recent text: \"\(text)\" in \(seen)")
            }
            seen.append(text)
            recent.append(ConversationTurn(taskID: "r\(i)", transcript: nil, responseFamily: .genericSuccess, responseText: text, purpose: .success))
        }
    }

    // MARK: - §12 seriousness suppresses humor (linguistic, not acoustic-emotion)

    @Test func explicitSeriousness_suppressesHumorAppropriateness() {
        let casual = reasoner.understand(transcript: "Can you launch a spaceship?", recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        #expect(casual.humorAppropriateness == true)
        let serious = reasoner.understand(transcript: "I'm serious, this is important.", recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false, taskID: "t2"), acoustics: .unavailable, explicitUserStatements: [])
        #expect(serious.humorAppropriateness == false)
        #expect(serious.humorSuitability == 0)
    }

    @Test func explicitSeriousness_humorPolicyNeverAllowsHumor() {
        let understanding = reasoner.understand(transcript: "I'm serious.", recentTurns: [], context: context(family: .unsupportedIntent, wasSuccess: false), acoustics: .unavailable, explicitUserStatements: [])
        // §12: humorSuitability forced to 0 by explicit seriousness, so
        // the decision is never one of the two positive-recommendation
        // cases (`.optional`/`.appropriate`) — it's always `.unnecessary`
        // (or `.prohibited`, if the register/purpose already disabled it).
        let decision = HumorPolicy.decision(register: .casualFriendly, purpose: .information, understanding: understanding)
        #expect(decision == .unnecessary)
    }

    // MARK: - §13 user-reported-problem response class

    @Test func userReportedProblem_getsARealAcknowledgement_neverClaimsResolution() {
        let ctx = context(family: .genericSuccess, wasSuccess: true)
        let understanding = ConversationUnderstanding(
            communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            dialogueAct: .statement, interactionMode: .conversational, actionExecutionState: .notRequested,
            userReportedState: UserReportedState(polarity: .negative, source: .userReported)
        )
        let text = DeterministicNaturalResponseRealizer().realize(context: ctx, understanding: understanding, plan: plan(context: ctx, understanding: understanding), recentTurns: [], avoiding: nil) ?? ""
        let resolutionClaims = ["fixed", "resolved", "all good", "working now", "everything's fine"]
        #expect(!resolutionClaims.contains { text.lowercased().contains($0) }, "\"\(text)\" must never claim resolution")
        #expect(!text.isEmpty)
    }

    // MARK: - §16 follow-up question decision: not a default, a real choice

    @Test func userReportedProblemPool_includesAtLeastOneNonQuestionVariant() {
        var sawNonQuestion = false
        for i in 0..<12 {
            let ctx = context(family: .genericSuccess, wasSuccess: true, taskID: "vary-\(i)")
            let understanding = ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
                dialogueAct: .statement, interactionMode: .conversational, actionExecutionState: .notRequested,
                userReportedState: UserReportedState(polarity: .negative, source: .userReported)
            )
            let text = DeterministicNaturalResponseRealizer().realize(context: ctx, understanding: understanding, plan: plan(context: ctx, understanding: understanding), recentTurns: [], avoiding: nil) ?? ""
            if !text.hasSuffix("?") { sawNonQuestion = true }
        }
        #expect(sawNonQuestion, "every variant in the user-reported-problem pool asked a question — §16 requires a real decision, not a default")
    }

    // MARK: - §24 5+ turn drafting-continuity battery (exact shape: draft → refine → refine → continue → topic shift)

    @Test func fiveTurnBattery_draftingContinuityThenTopicShift() {
        let memory = BoundedConversationMemory()
        let presenter = ConversationalResponsePresenter(memory: memory)

        func turn(_ transcript: String, outcome: String, text: String, taskID: String) -> ConversationUnderstanding {
            let recent = memory.recentTurns(limit: 8)
            let result = RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
            _ = presenter.response(for: .success(result), transcript: transcript, acoustics: .unavailable, explicitUserStatements: [])
            let ctx = DeterministicConversationContextCompiler().compile(outcome: .success(result), recentResponseFamilies: recent.map(\.responseFamily))
            return reasoner.understand(transcript: transcript, recentTurns: recent, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
        }

        let t1 = turn("I need to email my professor about missing class.", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.", taskID: "b1")
        #expect(t1.artifactContext?.kind == .email)

        let t2 = turn("Make it a little less formal.", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.", taskID: "b2")
        #expect(t2.artifactContext?.kind == .email)
        #expect(t2.artifactContext?.requestedStyle == .casual)

        let t3 = turn("Actually, keep this professional.", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.", taskID: "b3")
        #expect(t3.artifactContext?.kind == .email)
        #expect(t3.artifactContext?.requestedStyle == .professional)

        let t4 = turn("I still need to mention the exam date.", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.", taskID: "b4")
        #expect(t4.dialogueAct == .needStatement)
        #expect(t4.artifactContext?.kind == .email, "continuing the SAME draft must not reset kind to .unspecified")
        #expect(t4.artifactContext?.requestedStyle == .professional, "continuing the SAME draft must not drop the already-refined style")

        let t5 = turn("Check the system.", outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "b5")
        #expect(t5.activeTopic != .draftOrMessage, "an unrelated new request must not inherit the prior draft's topic")
        #expect(t5.artifactContext == nil, "an unrelated new request must not inherit the prior draft's artifact")
    }
}
