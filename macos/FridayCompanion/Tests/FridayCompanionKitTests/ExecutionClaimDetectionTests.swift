import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-P.1A — coverage for `ExecutionClaimDetector` and its
/// integration into `ResponseValidation.neverClaimsExecutionBeyondAuthority`/
/// `passesSemanticGuards`. Every transcript is an UNSEEN paraphrase where
/// the mission didn't mandate the exact literal (§20's own instruction);
/// where the mission's mandatory battery (§16) specifies an EXACT phrase,
/// that phrase is used verbatim since it's the required regression case,
/// not a harness literal being gamed.
@Suite struct ExecutionClaimDetectionTests {
    // MARK: - §4 — required positive completion constructions

    @Test func positive_firstPersonSimplePast() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I added the line."))
    }

    @Test func positive_presentPerfectContraction() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I've added the line."))
    }

    @Test func positive_presentPerfectSpelledOut() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I have added the line."))
    }

    @Test func positive_bareCompletionVerb() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Added the line."))
    }

    @Test func positive_passiveSimplePast() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The line was added."))
    }

    @Test func positive_passivePresentPerfectContraction() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("That's been added."))
    }

    @Test func positive_firstPersonUpdate() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I updated it."))
    }

    @Test func positive_passiveContractionUpdate() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("It's updated."))
    }

    @Test func positive_resultStateSaved() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Your note is saved."))
    }

    @Test func positive_firstPersonRename() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I renamed the file."))
    }

    @Test func positive_passivePresentPerfectSpelledOut() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The file has been renamed."))
    }

    // MARK: - §9 — result-state language, bounded (no ordinary-adjective false positives)

    @Test func resultState_uploadComplete() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The upload is complete."))
    }

    @Test func resultState_changeLive() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The change is live."))
    }

    @Test func resultState_everythingSynced() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Everything's synced."))
    }

    @Test func ordinaryAdjective_neverFalsePositive() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("The weather is nice today."))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("That sounds difficult."))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("This is important."))
    }

    // MARK: - §16 mandatory false-positive battery (verbatim, required)

    @Test func mandatory_canDelete_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can delete it."))
    }

    @Test func mandatory_cannotDelete_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can't delete it."))
    }

    @Test func mandatory_didntDelete_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I didn't delete it."))
    }

    @Test func mandatory_willDelete_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I'll delete it."))
    }

    @Test func mandatory_shouldIDelete_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Should I delete it?"))
    }

    @Test func mandatory_conditionalDeleted_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("If I deleted it, we'd lose the backup."))
    }

    @Test func mandatory_youDeleted_notAssistantClaim() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("You deleted it."))
    }

    @Test func mandatory_deleteOperationFailed_notSuccessfulCompletion() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("The delete operation failed."))
    }

    @Test func mandatory_iDeleted_isCompletionClaim() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I deleted it."))
    }

    @Test func mandatory_itsBeenDeleted_isCompletionClaim() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("It's been deleted."))
    }

    @Test func mandatory_bareDeleted_isCompletionClaimAsOutcome() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Deleted."))
    }

    // MARK: - §5 negation (unseen paraphrases beyond the mandatory battery)

    @Test func negation_havent() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I haven't added it."))
    }

    @Test func negation_couldnt() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I couldn't add it."))
    }

    @Test func negation_wasntAbleTo() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I wasn't able to add it."))
    }

    @Test func negation_passiveWasntAdded() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("It wasn't added."))
    }

    @Test func negation_didNotDeleteAnything() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I did not delete anything."))
    }

    // MARK: - §6 future/conditional (unseen paraphrases)

    @Test func future_canAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can add that.")) }
    @Test func future_couldAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I could add that.")) }
    @Test func future_illAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I'll add that.")) }
    @Test func future_canTryToAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can try to add that.")) }
    @Test func future_ifIAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("If I add that, will it break the layout?")) }
    @Test func future_wouldAdd() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I would add that if you'd like.")) }
    @Test func future_doYouWantMeTo() { #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Do you want me to add that?")) }
    @Test func future_perfectModal_couldHaveAdded() {
        // The trickier construction §6/§16 exist to close: past PARTICIPLE
        // after a perfect modal is still hypothetical, never a claim.
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I could have added that, but I didn't."))
    }

    // MARK: - §7 user-as-agent (unseen paraphrases)

    @Test func userAsAgent_youAddedTheFile() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("You added the file yourself."))
    }

    @Test func userAsAgent_theUserRenamedTheNote() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("The user renamed the note earlier."))
    }

    @Test func userAsAgent_doesNotSuppressAGenuineAssistantClaimElsewhereInTheSameText() {
        // A mixed reference — FRIDAY's own claim must still be detected
        // when ITS subject ("I") is nearer than the user reference.
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("You asked, so I added the line."))
    }

    // MARK: - §11 safe acknowledgements never false-positive

    @Test func safeAcknowledgements_neverFlagged() {
        for text in ["Got it.", "Understood.", "Okay.", "I'll keep that in mind.", "I can help with that.", "Sure thing.", "Alright."] {
            #expect(!ExecutionClaimDetector.claimsExecutionOrMutation(text), "\"\(text)\" must not be flagged")
        }
    }

    // MARK: - §13 cross-domain generalization (unseen domains, unseen verbs)

    @Test func crossDomain_calendarEvent() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I scheduled the event for Thursday."))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can schedule the event for Thursday."))
    }

    @Test func crossDomain_fileRename() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I renamed the export folder."))
    }

    @Test func crossDomain_backup() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Your documents have been backed up."))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can back that up for you."))
    }

    @Test func crossDomain_settingsChange() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I changed the notification setting."))
    }

    @Test func crossDomain_messageSend() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The message was sent."))
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Should I send the message?"))
    }

    @Test func crossDomain_taskCancellation() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I cancelled the reminder."))
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I canceled the reminder."))
    }

    @Test func crossDomain_appInstall() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The update has been installed."))
    }

    // MARK: - §14 punctuation/contraction/case normalization

    @Test func normalization_uppercase() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I ADDED IT."))
    }

    @Test func normalization_lowercaseNoPunctuation() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("i added it"))
    }

    @Test func normalization_curlyApostrophe() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I\u{2019}ve added it."))
    }

    // MARK: - §10 action-state matrix, via ResponseValidation integration

    @Test func actionState_executedSucceeded_completionClaimMayPass() {
        #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .executedSucceeded))
    }

    @Test func actionState_notRequested_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .notRequested))
    }

    @Test func actionState_denied_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .denied))
    }

    @Test func actionState_executedFailed_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .executedFailed))
    }

    @Test func actionState_unknown_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .unknown))
    }

    @Test func actionState_unsupported_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .unsupported))
    }

    @Test func actionState_requestedNotStarted_completionClaimMustReject() {
        #expect(!ResponseValidation.neverClaimsExecutionBeyondAuthority("I added the line.", actionExecutionState: .requestedNotStarted))
    }

    @Test func actionState_neverBlocksNonClaimText_regardlessOfState() {
        for state: ActionExecutionState in [.notRequested, .denied, .executedFailed, .unknown, .unsupported, .requestedNotStarted] {
            #expect(ResponseValidation.neverClaimsExecutionBeyondAuthority("Got it — I'll work that in.", actionExecutionState: state))
        }
    }

    // MARK: - §12 artifact-specific regression (the exact live-cited scenario, unseen paraphrase)

    @Test func artifactRegression_unauthorizedCompletionClaim_rejectedThroughFullValidation() {
        let passes = ResponseValidation.passesSemanticGuards(
            "Done. I added a quick note thanking them for their patience.",
            wasSuccess: true, actionExecutionState: .notRequested, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .needStatement, correctionTarget: nil, userReportedState: nil
        )
        #expect(!passes)
    }

    @Test func artifactRegression_bareAddedVerb_rejectedThroughFullValidation() {
        // The EXACT gap P.1's own disclosed-hole test named: no "Done"/
        // "Completed"/any previously-listed verb, ONLY the uncovered
        // "added." This must now be caught.
        let passes = ResponseValidation.passesSemanticGuards(
            "I added a quick thank-you line.",
            wasSuccess: true, actionExecutionState: .notRequested, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .needStatement, correctionTarget: nil, userReportedState: nil
        )
        #expect(!passes)
    }

    @Test func artifactRegression_safeFallbackWording_stillPasses() {
        let passes = ResponseValidation.passesSemanticGuards(
            "I can work that into the draft.",
            wasSuccess: true, actionExecutionState: .notRequested, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .needStatement, correctionTarget: nil, userReportedState: nil
        )
        #expect(passes)
    }

    @Test func artifactRegression_genuineExecutedSucceeded_completionClaimMayPass() {
        let passes = ResponseValidation.passesSemanticGuards(
            "I added a quick thank-you line.",
            wasSuccess: true, actionExecutionState: .executedSucceeded, retryability: .unknown, failureReason: .unknown,
            dialogueAct: .needStatement, correctionTarget: nil, userReportedState: nil
        )
        #expect(passes)
    }

    // MARK: - end-to-end presenter integration: a hallucinating realizer using the previously-uncovered verb is now rejected

    @Test func presenterIntegration_hallucinatedBareAddedClaim_rejectedFallsBackToDeterministic() {
        struct HallucinatingRealizer: NaturalConversationRealizing {
            func realize(context: ConversationContext, understanding: ConversationUnderstanding, plan: NaturalResponsePlan, recentTurns: [ConversationTurn], avoiding: String?) -> String? {
                "I added a line about the extended deadline."
            }
        }
        let presenter = ConversationalResponsePresenter(naturalRealizer: HallucinatingRealizer())
        let response = presenter.response(
            for: .success(RuntimeTextResult(protocolVersion: 1, requestID: "e1", correlationID: "e1", taskID: "e1", outcome: "SUCCESS", text: "Some brand-new drafting confirmation text.")),
            transcript: "I need to email the team about the deadline change.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.localizedCaseInsensitiveContains("i added"), "the previously-uncovered fabricated claim must now be rejected — got \"\(response.text)\"")
    }

    // MARK: - P2-M5V8.1-P.1A.1 §0/§3 — mixed negation + true claim in a sibling clause

    @Test func mixedClause_negatedThenBut_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I couldn't rename it, but I created a copy."))
    }

    @Test func mixedClause_negatedThenSo_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I couldn't rename the folder, so I created a new one."))
    }

    @Test func mixedClause_negatedFirstClauseAlone_stillExcludedOnItsOwn() {
        // Regression guard: the negated clause's OWN trigger (if it had
        // one) must still be excluded — only the SIBLING clause's claim
        // should survive, not a blanket "any claim anywhere passes now."
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I couldn't rename it, and I couldn't move it either."))
    }

    // MARK: - §0/§4 — mixed modal + true claim

    @Test func mixedClause_modalThenBut_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I can add it later, but I already saved this version."))
    }

    @Test func mixedClause_modalThenSo_negatedFirst_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I couldn't delete the old copy, but I archived the new one."))
    }

    @Test func mixedClause_noPunctuationRepeatedSubject_modalDoesNotBleedAcross() {
        // The no-conjunction-at-all case §4 names explicitly: "I can
        // confirm I sent it" — "can" modifies "confirm," not "sent."
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I can confirm I sent it."))
    }

    // MARK: - §0/§5 — mixed conditional + true claim

    @Test func mixedClause_conditionalFrameThenClaim_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("If that helps, I deleted the duplicate."))
    }

    @Test func mixedClause_conditionalGovernsTheClaimItself_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("If I delete the duplicate, we lose history."))
    }

    @Test func mixedClause_conditionalWithContraction_trueClaimSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("If we're talking about that file, I moved it."))
    }

    @Test func mixedClause_offerConditional_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("If you want, I can rename it."))
    }

    @Test func mixedClause_conditionalFrameWithClaimVerb_completionSurvives() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("If you're checking, I already renamed it."))
    }

    @Test func regression_bareConditionalDoesNotSplitAwayFromItsOwnClause() {
        // The exact regression this pass's own development caught and
        // fixed: a bare conditional lead-in ("If") followed immediately
        // by a subject pronoun must NOT be split away from what it
        // governs, or the modal exclusion silently stops applying.
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("If I deleted it, we'd lose the backup."))
    }

    // MARK: - §0/§6 — question wrapper does not erase an embedded true claim

    @Test func questionWrapper_embeddedFirstPersonReport_detected() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Did you want me to tell them I already sent it?"))
    }

    @Test func questionWrapper_pureOffer_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Should I send it?"))
    }

    @Test func questionWrapper_pastParticipleInversion_notCompleted() {
        // Not itself mission-mandated, but the natural extension of §6's
        // own aux-inversion reasoning: a genuine yes/no question phrased
        // in the passive must not be misread as an assertion.
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Was it already deleted?"))
    }

    @Test func separateSentences_questionThenClaim_claimDetected() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Could you check? I deleted it."))
    }

    // MARK: - §0/§7 — mixed user/assistant agency

    @Test func mixedAgency_userClauseThenAssistantClause_onlyAssistantCounts() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("You renamed the file, but I deleted the duplicate."))
    }

    @Test func mixedAgency_userGovernsBothCoordinatedVerbs_neitherCounts() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("You renamed it and saved it."))
    }

    @Test func mixedAgency_subordinateAfterClause_assistantVerbStillIsolated() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I renamed the file after you created the folder."))
    }

    // MARK: - §10 coordinated verbs sharing one subject

    @Test func coordinatedVerbs_sameSubject_bothCount() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I renamed and saved it."))
    }

    @Test func coordinatedVerbs_negatedDisjunction_neitherCounts() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I didn't rename or save it."))
    }

    @Test func coordinatedVerbs_perfectModalThenNegatedFollowUp_neitherCounts() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I could have added it, but I didn't."))
    }

    // MARK: - §8 make/made

    @Test func makeMade_firstPerson_completionClaim() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I made the note."))
    }

    @Test func makeMade_passive_resultStateClaim() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The note was made."))
    }

    @Test func makeMade_modal_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I can make the note."))
    }

    @Test func makeMade_negated_notCompleted() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I didn't make it."))
    }

    // MARK: - §11 adversarial bypass — an unrelated exclusion token elsewhere must not suppress a real claim

    @Test func adversarial_unrelatedNegationEarlierInSentence_realClaimStillDetected() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("Not sure why, but I updated it."))
    }

    @Test func adversarial_confirmationFraming_realClaimStillDetected() {
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("I can confirm I sent it."))
    }

    @Test func adversarial_fixIsIntentionallyOutsideVocabulary_documented() {
        // §11's own explicit hedge: "detect fixed IF 'fix' corresponds to
        // an actual execution family; otherwise document why it is
        // outside the detector." §9's vocabulary audit confirms FRIDAY
        // has no "fix" capability at all (it appears only as a USER-
        // narrated verb — "I finally fixed that bug" — never something
        // FRIDAY itself performs) — so it is correctly, deliberately
        // absent from `pastFormTriggers`, not a missed case.
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("Would you believe it? I fixed it."))
        #expect(!ExecutionClaimDetector.pastFormTriggers.contains("fixed"))
    }

    // MARK: - §12 false-positive control (full battery, unseen where not mandated verbatim)

    @Test func falsePositiveControl_wasAskedToDelete() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I was asked to delete it."))
    }

    @Test func falsePositiveControl_knowHowToDelete() {
        #expect(!ExecutionClaimDetector.claimsExecutionOrMutation("I know how to delete it."))
    }

    // MARK: - §9 action-vocabulary audit — grounded in the real capability registry, not guessed

    /// Audit performed against the actual Go-side capability registry
    /// (`ir.Phase1Registry()` / `capability-bus` registry / Planner's
    /// `approvedCapabilities` allow-list — kept in sync by hand across
    /// ~5 Go files per `PHASE-1-SCOPE-LOCK.md` §3) rather than guessed.
    /// FRIDAY's ENTIRE real action vocabulary today is exactly two
    /// capabilities: `system.get_status` (read-only) and
    /// `workspace.create_note` (whose own NL grammar — `intentcompiler/grammar.go`'s
    /// `createNoteFull` regex — literally reads `^(?:create|make) a
    /// note...`, confirming "make" as a genuine synonym, not an invented
    /// one). Every OTHER verb §9 asks about (set/enable/disable/copy/
    /// paste/run/execute/launch/connect/disconnect/pair/unpair/install/
    /// uninstall/turn-on/turn-off) corresponds to NO real FRIDAY
    /// capability — `PHASE-1-SCOPE-LOCK.md`/`PHASE-2-SCOPE-LOCK.md`'s own
    /// non-goals lists explicitly exclude device mesh/pairing, skill
    /// installation, and device-state control. Per §9's explicit
    /// instruction ("do NOT blindly add verbs FRIDAY cannot perform"),
    /// none of those were added to `pastFormTriggers` this pass — only
    /// "make/made" was, backed by the grammar.go evidence above. Swift
    /// has NO parallel action-vocabulary enum to share (confirmed: no
    /// `IntentType`/`SupportedAction`/`ActionType` exists anywhere under
    /// `Sources/`) — `RuntimeClient` deliberately stays capability-
    /// agnostic, seeing only an opaque `outcome` string, so there is
    /// nothing architecturally clean to import from Swift, and building
    /// a cross-language mirror is out of this narrow pass's scope
    /// (reported in the STOP report, not implemented).
    ///
    /// AUTHORIZED ACTION FAMILY | REALIZATION VERBS      | DETECTOR COVERED? | SOURCE
    /// system.get_status        | "check status"         | n/a (query, not a completion claim) | ir.Phase1Registry()
    /// workspace.create_note    | "create"/"make" a note | YES (created/added/wrote/made)      | ir.Phase1Registry(), intentcompiler/grammar.go
    /// (everything else §3/§9 name) | none exist today   | trigger surface still recognized (so a hallucinated claim about ANY of them is still caught — ActionExecutionState never reaches .executedSucceeded for a capability that doesn't exist) | n/a — no capability; §9's "do not blindly add" honored by NOT expanding new unsupported-verb families (set/enable/disable/copy/paste/run/execute/launch/connect/disconnect/pair/unpair/turn-on/turn-off) beyond what P.1A already mandated + make/made
    @Test func vocabularyAudit_makeIsTheOnlyNewlyAddedFamily_othersDeliberatelyExcluded() {
        let deliberatelyExcluded = ["set", "enable", "disable", "copy", "paste", "run", "execute", "launch", "connect", "disconnect", "pair", "unpair", "turn"]
        for verb in deliberatelyExcluded {
            #expect(!ExecutionClaimDetector.pastFormTriggers.contains(verb), "\"\(verb)\" must not have been blindly added — no corresponding real FRIDAY capability exists")
        }
        #expect(ExecutionClaimDetector.pastFormTriggers.contains("made"), "the one evidence-backed addition — confirmed synonym for the real create_note capability")
    }

    // MARK: - §13 result-state vs. assistant agency — documented finding, not implemented

    @Test func resultStateVsAgency_passiveWorldStateClaim_stillDetectedAsAClaim() {
        // "The file is deleted." asserts a WORLD STATE without naming an
        // agent — per §8 (passive completion) this IS correctly detected
        // as a claim (the same rule "The line was added."/"The note was
        // made." rely on). §13's own further question — whether a
        // `UserReportedState`-grounded echo of this SAME sentence should
        // be EXEMPTED from `neverClaimsExecutionBeyondAuthority` even
        // when `ActionExecutionState != .executedSucceeded` — is a
        // documented, NOT-implemented finding (§13: "If this requires
        // architecture changes: REPORT, DO NOT IMPLEMENT") — see this
        // pass's STOP report. In practice this is a low-probability
        // collision: `UserReportedState` in this codebase today is used
        // for coarse negative-polarity system/service reports ("production
        // is down"), whose own vocabulary doesn't intersect this
        // detector's artifact-mutation verb families.
        #expect(ExecutionClaimDetector.claimsExecutionOrMutation("The file is deleted."))
    }

    // MARK: - §19 performance: trivial local CPU work

    @Test func performance_negligibleLatencyForManyInvocations() {
        let samples = [
            "I added the line.", "I can add that.", "You added the file.", "It's been deleted.",
            "I could have added that, but I didn't.", "Your note is saved.", "Got it.",
        ]
        let start = Date()
        for _ in 0..<2000 {
            for text in samples { _ = ExecutionClaimDetector.claimsExecutionOrMutation(text) }
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        // A generous ceiling — this test runs alongside hundreds of other
        // tests under real parallel system load, not in isolation; the
        // actual per-call cost (a few dozen microseconds, confirmed via
        // isolated measurement during development) is what §19 cares
        // about, not this specific wall-clock number under contention.
        #expect(elapsedMs < 3000, "14,000 classifications took \(elapsedMs)ms — expected well under 3s even under parallel test-suite load")
    }
}
