import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-P — dedicated coverage for the PERSONA/naturalness/humor/
/// continuity polish this pass adds. Every assertion here targets WORDING
/// (what `DeterministicNaturalResponseRealizer` produces, and what the
/// two-stage/unified prompts teach the model) — nothing here touches or
/// re-tests `ActionExecutionState`/`FailureReason`/`Retryability`/
/// `ResponseScope`/authority truth themselves (those stay exactly as
/// `ArchitecturalInvariantsTests`/`SemanticAuthorityHardeningTests`/
/// `ResponseScopeTests` already establish, unchanged by this pass — §16/§15
/// of the P mission).
@Suite struct PersonaTests {
    private let ctx = ConversationContext(
        interactionID: "t", taskID: "t", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
        isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
    )

    private func understanding(_ transcript: String, recentTurns: [ConversationTurn] = []) -> ConversationUnderstanding {
        DeterministicConversationReasoner().understand(transcript: transcript, recentTurns: recentTurns, context: ctx, acoustics: .unavailable, explicitUserStatements: [])
    }

    private func plan(understanding: ConversationUnderstanding) -> NaturalResponsePlan {
        let strategy = DeterministicResponseStrategyPlanner().strategy(for: ctx, persona: .friday)
        return DeterministicNaturalResponsePlanner().plan(context: ctx, understanding: understanding, strategy: strategy, persona: .friday)
    }

    // MARK: - §5 natural acknowledgements: bounded pools, not one flat string

    @Test func greetingPool_hasMultipleDistinctVariants_reachableAcrossTaskIDs() {
        let realizer = DeterministicNaturalResponseRealizer()
        var seen: Set<String> = []
        for i in 0..<20 {
            let c = ConversationContext(
                interactionID: "t\(i)", taskID: "t\(i)", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
                isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
            )
            let u = DeterministicConversationReasoner().understand(transcript: "Hey there.", recentTurns: [], context: c, acoustics: .unavailable, explicitUserStatements: [])
            if let text = realizer.realize(context: c, understanding: u, plan: plan(understanding: u), recentTurns: [], avoiding: nil) { seen.insert(text) }
        }
        #expect(seen.count >= 2, "a bounded repertoire, not one flat greeting string — got \(seen)")
        // §14 — never a fabricated time-of-day/presence/location claim.
        for text in seen {
            #expect(!text.localizedCaseInsensitiveContains("morning"))
            #expect(!text.localizedCaseInsensitiveContains("evening"))
            #expect(!text.localizedCaseInsensitiveContains("see you"), "\"see you\" implies visual presence this codebase never verifies")
        }
    }

    @Test func farewellPool_hasMultipleDistinctVariants() {
        let realizer = DeterministicNaturalResponseRealizer()
        var seen: Set<String> = []
        for i in 0..<20 {
            let c = ConversationContext(
                interactionID: "t\(i)", taskID: "t\(i)", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
                isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
            )
            let u = DeterministicConversationReasoner().understand(transcript: "Alright, catch you later.", recentTurns: [], context: c, acoustics: .unavailable, explicitUserStatements: [])
            if let text = realizer.realize(context: c, understanding: u, plan: plan(understanding: u), recentTurns: [], avoiding: nil) { seen.insert(text) }
        }
        #expect(seen.count >= 2, "got \(seen)")
    }

    @Test func personalUpdatePool_includesNewVariant_stillNeverClaimsAnAction() {
        let u = understanding("I finally fixed that deploy script.")
        #expect(u.dialogueAct == .personalUpdate)
        let realizer = DeterministicNaturalResponseRealizer()
        let text = realizer.realize(context: ctx, understanding: u, plan: plan(understanding: u), recentTurns: [], avoiding: nil)
        #expect(text != nil)
        #expect(ResponseValidation.neverClaimsActionForNotRequested(text!, actionExecutionState: u.actionExecutionState))
    }

    @Test func unsupportedIntentHumorPool_includesNewVariant_stillGatedByHumorAllowance() {
        let humorPlan = NaturalResponsePlan(responseGoal: .unsupported, socialRegister: .casualFriendly, warmth: 0.8, directness: 0.7, humorAllowance: true, humorStrength: 0.3, formality: 0.2, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .information)
        let realizer = DeterministicNaturalResponseRealizer()
        var seen: Set<String> = []
        for i in 0..<30 {
            let c = ConversationContext(
                interactionID: "u\(i)", taskID: "u\(i)", outcomeCode: "x", responseFamily: .unsupportedIntent, wasSuccess: false,
                isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
            )
            if let text = realizer.realize(context: c, understanding: .minimal, plan: humorPlan, recentTurns: [], avoiding: nil) { seen.insert(text) }
        }
        #expect(seen.contains("Afraid not. My launch credentials are conspicuously absent."))
        #expect(seen.count >= 2)
        // Humor stays OFF when not allowed — unaffected by the new variant.
        let noHumorPlan = NaturalResponsePlan(responseGoal: .unsupported, socialRegister: .friendlyNeutral, warmth: 0.8, directness: 0.7, humorAllowance: false, humorStrength: 0, formality: 0.3, verbosity: .brief, reassurance: 0.5, urgency: 0.1, followUpMode: .none, prosodyIntent: .information)
        #expect(realizer.realize(context: ctx, understanding: .minimal, plan: noHumorPlan, recentTurns: [], avoiding: nil) == nil)
    }

    // MARK: - §13 corrections: natural acknowledgement, never a re-execution claim

    @Test func correction_earlierTarget_acknowledgesWithoutClaimingReexecution() {
        let priorTurn = ConversationTurn(taskID: "r1", transcript: "Create a note called groceries.", responseFamily: .createNoteSuccess, responseText: "Created and verified note \"groceries\".", purpose: .success)
        let u = understanding("No, I meant the earlier one.", recentTurns: [priorTurn])
        #expect(u.dialogueAct == .correction)
        let realizer = DeterministicNaturalResponseRealizer()
        let text = realizer.realize(context: ctx, understanding: u, plan: plan(understanding: u), recentTurns: [priorTurn], avoiding: nil)
        if u.correctionTarget == "earlier" {
            #expect(text == "Got it—the earlier one.")
        }
        // Regardless of which correctionTarget the local reasoner resolved
        // (grounding logic itself is frozen/untouched by this pass), the
        // wording must never claim anything was re-created/re-run.
        if let text {
            #expect(!text.localizedCaseInsensitiveContains("recreated"))
            #expect(!text.localizedCaseInsensitiveContains("re-run"))
            #expect(!text.localizedCaseInsensitiveContains("created a new"))
        }
    }

    @Test func correction_noIdentifiableTarget_defersRatherThanGuessing() {
        // `correctionTarget` is derived purely from the transcript's OWN
        // wording (`DeterministicConversationReasoner.referentialDirection`,
        // untouched by this pass) — a correction that names neither an
        // "earlier"/"first"/"before" nor a "new"/"latest" referent leaves
        // it `nil`, and this new branch must defer (return nil) rather
        // than invent a target, letting the existing fallback chain
        // handle it exactly as it did before this pass.
        let u = understanding("No, that's not right.", recentTurns: [])
        #expect(u.dialogueAct == .correction)
        #expect(u.correctionTarget == nil)
        let realizer = DeterministicNaturalResponseRealizer()
        let text = realizer.realize(context: ctx, understanding: u, plan: plan(understanding: u), recentTurns: [], avoiding: nil)
        #expect(text == nil, "no safe target identified — must defer, never guess")
    }

    // MARK: - §11 failure language: more honest for TRUE unknown, unchanged for known/connectivity

    @Test func groundedFailureText_trueUnknown_usesTheMoreHonestPhrasing() {
        let u = ConversationUnderstanding(
            communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            failureReason: .unknown, retryability: .notAllowed
        )
        #expect(DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u) == "I couldn't complete that, and I don't know why yet.")
    }

    @Test func groundedFailureText_knownButUnrecognizedEvidence_staysAtTheOriginalNeutralPhrasing() {
        // A `.known` reason whose evidence text `mentionsConnectivity`
        // doesn't recognize must NOT claim "I don't know why" (that would
        // be dishonest in the OTHER direction — the reason IS known) — it
        // keeps the pre-existing neutral phrasing.
        let u = ConversationUnderstanding(
            communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            failureReason: .known(type: "disk", evidence: "disk quota exceeded"), retryability: .notAllowed
        )
        #expect(DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u) == "That didn't go through.")
    }

    @Test func groundedFailureText_knownConnectivity_unchangedFromBeforeThisPass() {
        let u = ConversationUnderstanding(
            communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            failureReason: .known(type: "network", evidence: "connection refused, service unreachable"), retryability: .allowed
        )
        #expect(DeterministicNaturalResponseRealizer.groundedFailureText(understanding: u) == "I couldn't reach the service that time. Want me to try again?")
    }

    @Test func groundedFailureText_unknown_stillOffersRetryOnlyWhenAllowed() {
        let denied = ConversationUnderstanding(
            communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            failureReason: .unknown, retryability: .notAllowed
        )
        #expect(!DeterministicNaturalResponseRealizer.groundedFailureText(understanding: denied).localizedCaseInsensitiveContains("try again"))
        let allowed = ConversationUnderstanding(
            communicativeIntent: .unknown, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
            userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
            responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
            failureReason: .unknown, retryability: .allowed
        )
        #expect(DeterministicNaturalResponseRealizer.groundedFailureText(understanding: allowed).localizedCaseInsensitiveContains("try again"))
    }

    // MARK: - §7 negative-state pool stays FOCUSED — never celebratory/joking

    @Test func negativeStatePool_neverContainsCelebratoryOrJokingLanguage() {
        let realizer = DeterministicNaturalResponseRealizer()
        var seen: Set<String> = []
        for i in 0..<40 {
            let c = ConversationContext(
                interactionID: "n\(i)", taskID: "n\(i)", outcomeCode: "x", responseFamily: .genericSuccess, wasSuccess: true,
                isVerifiedData: true, needsClarification: false, isRetryable: false, isFollowUpMeaningful: false, failureEvidence: nil
            )
            let u = ConversationUnderstanding(
                communicativeIntent: .statement, topic: nil, continuationOfPreviousTurn: false, clarificationNeeded: false,
                userExplicitPreference: nil, explicitUrgency: false, socialRegisterRecommendation: nil, humorAppropriateness: false,
                responseGoal: nil, recommendedVerbosity: nil, followUpNeeded: false, uncertainty: 0.4,
                dialogueAct: .statement, interactionMode: .conversational, actionExecutionState: .notRequested,
                userReportedState: UserReportedState(polarity: .negative, source: .userReported)
            )
            if let text = realizer.realize(context: c, understanding: u, plan: plan(understanding: u), recentTurns: [], avoiding: nil) { seen.insert(text) }
        }
        #expect(seen.count >= 3)
        let celebratoryPhrases = ["that's good", "great news", "awesome", "amazing", "that's great", "nice!", "good job"]
        for text in seen {
            let lower = text.lowercased()
            #expect(!celebratoryPhrases.contains { lower.contains($0) }, "\"\(text)\" reads as celebratory for a NEGATIVE report")
            #expect(!text.contains("!"), "\"\(text)\" — no exclamation for a negative report")
        }
    }

    // MARK: - §18 prompt-content presence: the new persona guidance actually reached both prompts

    @Test func realizationSystemPolicy_containsSeriousToneGuidance() {
        // P2-M5V8.1-P.1 §20/§21 — this pass's own prompt-compaction pass
        // rewrote the P-pass wording denser (net SMALLER, see
        // `unifiedSystemPolicy_stillFitsWithRealHeadroom`/the realizer's
        // own size regression test below) — these checks target the
        // CURRENT phrasing, not the original P-pass literal.
        let policy = ConversationModelPersona.realizationSystemPolicy
        #expect(policy.contains("I decided not to"))
        #expect(policy.contains("the earlier one"))
        #expect(policy.contains("I can try again"))
        #expect(policy.contains("SINGLE most useful question"))
        #expect(policy.contains("catchphrase"))
        #expect(policy.contains("I hear how difficult that must be"))
    }

    @Test func unifiedSystemPolicy_containsSeriousToneGuidance() {
        let policy = ConversationModelPersona.unifiedSystemPolicy
        #expect(policy.contains("I decided not to"))
        #expect(policy.contains("I can try again"))
        #expect(policy.contains("SINGLE most useful question"))
        #expect(policy.contains("catchphrase"))
    }

    // MARK: - §18 performance: prompt growth stayed modest, ceilings still respected

    @Test func unifiedSystemPolicy_stillFitsWithRealHeadroom() {
        let bytes = ConversationModelPersona.unifiedSystemPolicy.utf8.count
        #expect(bytes < ConversationModelLimits.maxUnifiedSerializedContextBytes)
        // §18 — "modest bounded amount": persona's own addition should be
        // a small fraction of the ceiling, not a large chunk of it.
        let headroomFraction = Double(ConversationModelLimits.maxUnifiedSerializedContextBytes - bytes) / Double(ConversationModelLimits.maxUnifiedSerializedContextBytes)
        #expect(headroomFraction > 0.25, "expected real headroom to remain; got \(bytes) of \(ConversationModelLimits.maxUnifiedSerializedContextBytes)")
    }

    @Test func realizer_realisticRequest_stillEncodesSuccessfully() {
        // The REALISTIC case (a handful of moderate-length recent turns) —
        // not the theoretical worst case (see this pass's own STOP report
        // for the disclosed PRE-EXISTING latent boundary condition at the
        // absolute maximum simultaneously-maxed-out scenario, which this
        // test deliberately does NOT reproduce since it predates and is
        // unrelated to this pass's own changes).
        let fake = FakeConversationModelRequesting()
        fake.behavior = .failure(ConversationModelError.emptyResponse)
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let realizer = ModelNaturalResponseRealizer(client: fake, config: config)
        let realisticTurns = (0..<3).map {
            ConversationTurn(taskID: "r\($0)", transcript: "some prior turn's transcript text", responseFamily: .genericSuccess, responseText: "some prior response text", purpose: .success)
        }
        let u = understanding("I need to email my professor about missing class.", recentTurns: realisticTurns)
        _ = realizer.realize(context: ctx, understanding: u, plan: plan(understanding: u), recentTurns: realisticTurns, avoiding: "some avoided text")
        #expect(fake.sendCallCount == 1, "a realistic (non-worst-case) request must still encode and send successfully")
    }
}
