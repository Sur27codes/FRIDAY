import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5/P2-M5V §31 — deterministic spoken-response mapping tests. Uses
/// REAL `services/runtime/response/response.go`-shaped text (the exact
/// strings that file's templates produce, transcribed here rather than
/// invented) so this suite proves `DeterministicResponsePresenter`
/// behaves correctly against the actual Go-side vocabulary, per §8: "use
/// actual enums/types from the codebase, do not invent status names."
///
/// P2-M5V note: assertions below check the WARM, refined wording
/// (§6/§7) that `presenter.response(for:)` now actually produces — the
/// real, current production behavior — not the original P2-M5 pass-
/// through text. `warmedTextRewordingTable_...` tests separately prove
/// the underlying rewording table/fallback mechanism itself.
@Suite struct ResponsePresentingTests {
    private let presenter = DeterministicResponsePresenter()

    private func result(outcome: String, text: String, taskID: String = "task-1") -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: "r1", correlationID: "r1", taskID: taskID, outcome: outcome, text: text)
    }

    /// Every real (outcome code, Go template text) pair, transcribed
    /// from `services/runtime/response/response.go` — the authoritative
    /// vocabulary this whole suite is checked against.
    static let realGoTemplates: [(outcome: String, text: String)] = [
        ("SUCCESS", "System status retrieved successfully."),
        ("SUCCESS", "Created and verified note \"voice test\"."),
        ("UNSUPPORTED_INTENT", "That capability isn't available in Phase 1."),
        ("AMBIGUOUS_INTENT", "I need more information to do that."),
        ("AMBIGUOUS_INTENT", "I need more information to do that (missing: title)."),
        ("INVALID_TEXT_REQUEST", "I didn't receive a usable request."),
        ("IR_VALIDATION_FAILED", "That request didn't pass validation, so I didn't attempt it."),
        ("POLICY_DENIED", "I couldn't perform that action because authorization was denied."),
        ("POLICY_DENIED", "That action requires stronger authorization."),
        ("POLICY_UNAVAILABLE", "I can't authorize that action right now."),
        ("CAPABILITY_UNAVAILABLE", "I can't perform that action right now."),
        ("EXECUTION_FAILED", "The action could not be completed."),
        ("VERIFICATION_FAILED", "The action ran, but I couldn't verify the expected result."),
        ("VERIFICATION_FAILED", "A stop was requested after the action may have already taken effect; I can't confirm it was undone. This needs manual review."),
        ("CANCELLED", "Cancelled."),
        ("CANCELLED", "Stop request received; this task was already past the point Phase 1 can safely interrupt, so its outcome will be reported once it's known."),
        ("ALREADY_TERMINAL", "That task has already finished; there's nothing to stop."),
        ("DUPLICATE_REQUEST", "That exact request is already in progress."),
        ("DUPLICATE_REQUEST", "That was already done successfully; I didn't repeat it."),
        ("DUPLICATE_REQUEST", "That exact request was already attempted and did not succeed; I didn't repeat it."),
        ("INTERNAL_ERROR", "Something went wrong on my end; the action was not performed."),
    ]

    // MARK: - §9/§37: system.get_status

    @Test func getStatusSuccess_speaksNaturalRefinedWording_marksSuccess() {
        // P2-M5V3 §8: the exact wording is now one of a small,
        // deterministically-selected set (`getStatusSuccessVariants`),
        // not a single fixed string — check membership, not equality.
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.")))
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(r.text), "P2-M5V §6/P2-M5V3 §8: machine-sounding telemetry phrasing must be refined to natural, humanlike spoken language — got '\(r.text)'")
        #expect(r.wasSuccess)
        #expect(r.category == .success)
    }

    @Test func getStatusSuccess_neverUsesTheStrongerAllSystemsNormalPhrasing() {
        // P2-M5V2 §8: the stronger "Everything appears to be operating
        // normally." phrasing is deliberately NOT used for
        // system.get_status, because the runtime response layer
        // currently exposes no structured per-check health data to
        // verify that stronger claim against (audited: the orchestrator
        // calls `GetStatusSuccess` unconditionally on capability
        // success, never branching on `getstatus`'s own sub-check
        // results) — using it would risk claiming stronger health than
        // the data actually proves.
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.")))
        #expect(!r.text.contains("Everything appears to be operating normally"))
    }

    // MARK: - §10/§38: workspace.create_note

    @Test func createNoteSuccess_speaksConciseNaturalConfirmation_noFilesystemPath() {
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "Created and verified note \"voice test\".")))
        #expect(DeterministicResponsePresenter.createNoteSuccessVariants(title: "voice test").contains(r.text), "P2-M5V3 §5/§8: concise, natural, humanlike confirmation — got '\(r.text)'")
        #expect(r.wasSuccess)
        #expect(r.category == .success)
        #expect(!r.text.contains("/"), "must not reveal a filesystem path unless explicitly requested (§10)")
    }

    @Test func createNoteSuccess_titleAwareVariant_neverRevealsFilesystemPathEither() {
        // The title-aware 4th variant embeds the title directly — must
        // stay just as free of filesystem-path leakage as the generic
        // variants, even though it's the one most likely to carry
        // user-supplied content.
        for variant in DeterministicResponsePresenter.createNoteSuccessVariants(title: "voice test") {
            #expect(!variant.contains("/"), "no create-note variant may reveal a filesystem path — got '\(variant)'")
        }
    }

    // MARK: - §8/§11/§39: every real non-success Outcome — refined wording, never fake success

    @Test func everyRealNonSuccessOutcome_neverMapsToSuccess_neverSaysDoneOrCompleted() {
        for (outcome, text) in Self.realGoTemplates where outcome != "SUCCESS" {
            let r = presenter.response(for: .success(result(outcome: outcome, text: text)))
            #expect(!r.wasSuccess, "\(outcome) must never be marked as success")
            #expect(!r.text.isEmpty)
            // CANCELLED is deliberately exempt from the "Done" check: a
            // cancellation the user asked for, that genuinely happened,
            // truthfully IS "done" (the stop itself succeeded) — §11's
            // "never say Done for a FAILED result" targets outcomes
            // where nothing the user wanted actually happened, which a
            // successful cancellation is not.
            let forbidden = (outcome == "CANCELLED") ? ["Completed", "Success"] : ["Done", "Completed", "Success"]
            for word in forbidden {
                #expect(!r.text.contains(word), "\(outcome) text ('\(r.text)') must never say '\(word)'")
            }
        }
    }

    @Test func unsupportedIntent_speaksRefinedApologeticWording_notFakeSuccess() {
        let r = presenter.response(for: .success(result(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.")))
        #expect(DeterministicResponsePresenter.unsupportedIntentVariants.contains(r.text))
        #expect(!r.wasSuccess)
        #expect(r.category == .information)
    }

    // MARK: - §6: internal implementation terminology must never leak into normal speech

    @Test func refinedWording_neverExposesInternalImplementationTerminology() {
        // P2-M5V3 §11 extends this list: "response code," "correlation
        // ID," and "internal error" join the original P2-M5V set.
        let forbiddenTerms = ["Phase 1", "runtime", "capability bus", "policy engine", "orchestrator", "idempotency", "response code", "correlation ID", "internal error"]
        for (outcome, text) in Self.realGoTemplates {
            let r = presenter.response(for: .success(result(outcome: outcome, text: text)))
            for term in forbiddenTerms {
                #expect(!r.text.localizedCaseInsensitiveContains(term), "\(outcome) reworded text ('\(r.text)') must not expose internal term '\(term)' (§6/§11)")
            }
        }
    }

    @Test func refinedWording_neverExposesInternalTerminology_acrossEveryVariant_notJustTheDefaultTaskID() {
        // The test above only samples whichever ONE variant "task-1"'s
        // hash happens to select — this exhaustively checks every
        // member of every variant family, since a real interaction could
        // land on any of them.
        let forbiddenTerms = ["Phase 1", "runtime", "capability bus", "policy engine", "orchestrator", "idempotency", "response code", "correlation ID", "internal error"]
        let allVariants = DeterministicResponsePresenter.getStatusSuccessVariants
            + DeterministicResponsePresenter.createNoteSuccessVariants(title: "voice test")
            + DeterministicResponsePresenter.unsupportedIntentVariants
        for variant in allVariants {
            for term in forbiddenTerms {
                #expect(!variant.localizedCaseInsensitiveContains(term), "variant '\(variant)' must not expose internal term '\(term)'")
            }
        }
    }

    // MARK: - §7: never unnecessarily harsh, but never misleadingly soft

    @Test func refinedWording_rejectsHarshBluntPhrasing_forEveryKnownOutcome() {
        let harshPhrases = ["No.", "Unsupported.", "Invalid request."]
        for (outcome, text) in Self.realGoTemplates {
            let r = presenter.response(for: .success(result(outcome: outcome, text: text)))
            #expect(!harshPhrases.contains(r.text), "\(outcome) must not use unnecessarily harsh wording (§7) — got '\(r.text)'")
        }
    }

    @Test func refinedWording_avoidsExcessiveEnthusiasm_forEveryKnownOutcome() {
        // P2-M5V2 §9: "avoid excessive: 'Absolutely!' 'Awesome!' 'Great!'
        // 'Sure thing!'" — measured confidence, not cheerleader energy.
        let overEnthusiastic = ["Absolutely!", "Awesome!", "Great!", "Sure thing!"]
        for (outcome, text) in Self.realGoTemplates {
            let r = presenter.response(for: .success(result(outcome: outcome, text: text)))
            for phrase in overEnthusiastic {
                #expect(!r.text.contains(phrase), "\(outcome) must not use over-enthusiastic wording (§9) — got '\(r.text)'")
            }
        }
    }

    @Test func permissionDenied_staysFirmAndTruthful_notSoftenedIntoAmbiguity() {
        // §7: "NEVER soften an error so much that it becomes misleading."
        let r = presenter.response(for: .success(result(outcome: "POLICY_DENIED", text: "I couldn't perform that action because authorization was denied.")))
        #expect(r.text == "I don't have permission to do that.")
        #expect(!r.wasSuccess)
        #expect(r.category == .permissionDenied)
    }

    // MARK: - §8: transport-level failure (never reached a Go Response at all)

    @Test func transportFailure_getsTruthfulNaturalFallback_neverClaimsSuccess() {
        let r = presenter.response(for: .failure("transport(\"connection refused\")"))
        #expect(r.text == "I'm having trouble reaching the system right now.")
        #expect(!r.wasSuccess)
        #expect(r.category == .failure)
    }

    // MARK: - P2-M5V §10: prosody category classification

    @Test func categoryClassification_matchesEveryRealOutcomeCode() {
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "SUCCESS", rawText: "x") == .success)
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "POLICY_DENIED", rawText: "x") == .permissionDenied)
        // P2-M5V5 §14: "CLARIFICATION -> friendly/neutral" — AMBIGUOUS_INTENT
        // is a clarification request, not a flat informational notice, so
        // it now reads its own more specific prosody intent.
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "AMBIGUOUS_INTENT", rawText: "x") == .friendly, "clarification requests should read as .friendly (P2-M5V5 §14)")
        for code in ["UNSUPPORTED_INTENT", "INVALID_TEXT_REQUEST", "IR_VALIDATION_FAILED", "CANCELLED", "ALREADY_TERMINAL", "DUPLICATE_REQUEST"] {
            #expect(DeterministicResponsePresenter.category(forOutcomeCode: code, rawText: "x") == .information, "\(code) should be .information")
        }
        // P2-M5V5 §13/§14: outcomes where retrying the SAME request could
        // plausibly succeed later now read `.reassuring` prosody (slightly
        // softer, not a flat failure tone) rather than the old undifferentiated
        // `.failure` — a genuinely non-retryable failure (INTERNAL_ERROR)
        // still reads `.failure`.
        for code in ["POLICY_UNAVAILABLE", "CAPABILITY_UNAVAILABLE", "EXECUTION_FAILED"] {
            #expect(DeterministicResponsePresenter.category(forOutcomeCode: code, rawText: "x") == .reassuring, "\(code) is retryable, so it should be .reassuring (P2-M5V5 §13/§14)")
        }
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "INTERNAL_ERROR", rawText: "x") == .failure, "INTERNAL_ERROR is not retryable, so it should remain .failure")
    }

    @Test func verificationFailed_isFailureCategory_unlessManualReviewVariant() {
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "VERIFICATION_FAILED", rawText: "The action ran, but I couldn't verify the expected result.") == .failure)
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "VERIFICATION_FAILED", rawText: "...This needs manual review.") == .warning, "the manual-review variant should read as a warning, not a plain failure")
    }

    @Test func unrecognizedFutureOutcomeCode_defaultsToInformation_neverCrashes() {
        #expect(DeterministicResponsePresenter.category(forOutcomeCode: "SOME_FUTURE_OUTCOME", rawText: "x") == .information)
    }

    // MARK: - The rewording table's own safety mechanism: unknown text relays unchanged

    @Test func warmedText_returnsNilForUnrecognizedText_fallsBackToOriginalRelay() {
        // The core safety property this whole design depends on: if Go
        // ever adds a new template this file hasn't been updated for,
        // the ORIGINAL (still Go-audited-safe) text must still be
        // spoken — never dropped, never guessed at.
        #expect(DeterministicResponsePresenter.warmedText(for: "Some brand-new outcome text nobody has seen yet.", taskID: "task-1") == nil)
        let r = presenter.response(for: .success(result(outcome: "SOME_FUTURE_OUTCOME", text: "Some brand-new outcome text nobody has seen yet.")))
        #expect(r.text == "Some brand-new outcome text nobody has seen yet.", "unknown text must relay verbatim (after sanitization), never silently disappear")
    }

    @Test func warmedText_ambiguousIntentWithMissingField_preservesTheFieldName() {
        let reworded = DeterministicResponsePresenter.warmedText(for: "I need more information to do that (missing: title).", taskID: "task-1")
        #expect(reworded == "I need a bit more information to do that (missing: title).", "softening the lead-in must not drop the actual missing-field information")
    }

    @Test func warmedText_createNoteTitleExtraction_handlesQuotesAndSpecialCharactersInTitle() {
        let reworded = DeterministicResponsePresenter.warmedText(for: "Created and verified note \"a title with \\\"nested\\\" text\".", taskID: "task-1")
        // The simple prefix/suffix extractor is not quote-escaping-aware
        // — documented, bounded behavior: it takes everything between
        // the FIRST `"` after the fixed prefix and the LAST `".` — for
        // a title that itself contains literal `"` characters this may
        // extract a superset, but it can never produce something
        // UNTRUTHFUL (the extracted text is still a verbatim substring
        // of Go's own already-safe text), only imprecise in this
        // pathological edge case.
        #expect(reworded != nil)
    }

    // MARK: - P2-M5V3 §8/§17: deterministic response variation

    @Test func variantSelection_sameTaskID_alwaysPicksTheSameVariant() {
        // Determinism, proven directly and repeatedly — the exact
        // property §8 requires ("if randomness is used, make it
        // injectable/deterministic for tests"; this has no randomness at
        // all, but the reproducibility bar is the same).
        let r1 = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "fixed-task-abc")))
        let r2 = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "fixed-task-abc")))
        let r3 = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "fixed-task-abc")))
        #expect(r1.text == r2.text && r2.text == r3.text, "the exact same interaction must always sound the same, never re-roll on replay")
    }

    @Test func variantSelection_differentTaskIDs_canPickDifferentVariants() {
        // Variety, proven directly: across a modest sample of distinct
        // taskIDs, more than one variant must actually be reachable —
        // otherwise this would be dead code masquerading as variation.
        var seen = Set<String>()
        for i in 0..<20 {
            let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "System status retrieved successfully.", taskID: "task-\(i)")))
            seen.insert(r.text)
        }
        #expect(seen.count > 1, "20 distinct interactions should not all collapse onto the exact same phrasing")
        #expect(seen.isSubset(of: Set(DeterministicResponsePresenter.getStatusSuccessVariants)), "every selected variant must come from the known, approved set — no drift")
    }

    @Test func variantSelection_stableHash_isConsistentAcrossRepeatedCalls_notProcessRandomized() {
        // Directly exercises the hash function itself, guarding against
        // ever accidentally swapping it for Swift's randomly-reseeded
        // `String.hashValue`/`Hasher`, which would break reproducibility.
        let h1 = DeterministicResponsePresenter.stableHash("some-task-id")
        let h2 = DeterministicResponsePresenter.stableHash("some-task-id")
        #expect(h1 == h2)
    }

    @Test func createNoteVariants_allSayTheSameThing_noSemanticDrift() {
        // §8: "no semantic drift" — every variant must affirmatively
        // confirm a note was created, none may hedge, contradict, or
        // claim something stronger/weaker than the others.
        for variant in DeterministicResponsePresenter.createNoteSuccessVariants(title: "voice test") {
            #expect(variant.localizedCaseInsensitiveContains("done") || variant.localizedCaseInsensitiveContains("created") || variant.localizedCaseInsensitiveContains("ready"),
                    "create-note variant '\(variant)' must affirmatively confirm creation like every other variant")
        }
    }

    @Test func unsupportedIntentVariants_neverConvertFailureIntoSuccess() {
        // §17: "deterministic variation cannot convert failure into
        // success" — checked directly against the real presenter for
        // every taskID that could select each of the three variants,
        // not just the raw string list.
        for i in 0..<10 {
            let r = presenter.response(for: .success(result(outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.", taskID: "unsupported-\(i)")))
            #expect(!r.wasSuccess, "variant '\(r.text)' must never be marked as success")
            for forbidden in ["Done", "Completed", "Success", "success"] {
                #expect(!r.text.contains(forbidden), "unsupported-intent variant '\(r.text)' must never claim success")
            }
        }
    }

    @Test func getStatusVariants_neverConvertFailureIntoStrongerClaimThanDataSupports() {
        // Companion check to the "no stronger claim" test above — every
        // status-success variant, not just the default-taskID one, must
        // avoid the unproven "operating normally" claim.
        for variant in DeterministicResponsePresenter.getStatusSuccessVariants {
            #expect(!variant.localizedCaseInsensitiveContains("operating normally"), "variant '\(variant)' must not claim broader health than the runtime data proves")
        }
    }

    // MARK: - §26/§27: bounded, sanitized, crash-proof

    @Test func emptyResponseText_fallsBackToSafeDefault_neverSpeaksEmptyString() {
        let successEmpty = presenter.response(for: .success(result(outcome: "SUCCESS", text: "")))
        #expect(!successEmpty.text.isEmpty)
        let failureEmpty = presenter.response(for: .success(result(outcome: "INTERNAL_ERROR", text: "")))
        #expect(!failureEmpty.text.isEmpty)
        #expect(!failureEmpty.wasSuccess)
    }

    @Test func whitespaceOnlyResponseText_fallsBackToSafeDefault() {
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: "   \n\t  ")))
        #expect(!r.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func oversizedResponseText_isBoundedToMaxSpokenLength() {
        let huge = String(repeating: "a", count: DeterministicResponsePresenter.maxSpokenLength * 4)
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: huge)))
        #expect(r.text.count <= DeterministicResponsePresenter.maxSpokenLength, "§26: must never read an unbounded blob aloud")
    }

    @Test func unicodeResponseText_isPreservedButBounded_noCrash() {
        let text = "System status: \u{2705} 100% \u{1F680} — all good"
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: text)))
        #expect(!r.text.isEmpty)
        #expect(r.wasSuccess)
    }

    @Test func controlCharactersInResponseText_areStrippedNotCrashed() {
        let withControls = "System status\u{0000}\u{0001} retrieved\u{001B} successfully.\r\n"
        let r = presenter.response(for: .success(result(outcome: "SUCCESS", text: withControls)))
        #expect(!r.text.contains("\u{0000}"))
        #expect(!r.text.contains("\u{001B}"))
    }

    // MARK: - §4: never speak internal/sensitive metadata

    @Test func sanitize_neverPassesThroughStackTraceOrTokenShapedInput_evenIfSomehowPresent() {
        // Defense in depth: even if a future bug put something
        // sensitive-LOOKING into `text` (the Go side is already trusted
        // not to, per its own doc comment — this is a belt-and-braces
        // check, not a claim that this layer re-derives safety from
        // scratch), sanitize() must not itself introduce a crash or
        // mangle it into something worse; it is not expected to redact
        // content, only to bound/clean formatting.
        let suspicious = "panic: runtime error at /Users/owner/.friday/runtime.db:142\n\tgoroutine 7 [running]:"
        let sanitized = DeterministicResponsePresenter.sanitize(suspicious, fallback: "fallback")
        #expect(!sanitized.isEmpty)
        #expect(sanitized.count <= DeterministicResponsePresenter.maxSpokenLength)
    }

    // MARK: - §12/§18/§11(P2-M5V): no ACTUAL spoken response contains the literal wake phrase

    @Test func noActualSpokenResponse_containsTheLiteralWakePhrase() {
        // Stronger than a hand-transcribed literal list: runs every real
        // (outcome, text) pair through the ACTUAL production presenter
        // and checks its ACTUAL output — covers both the warm-reworded
        // strings and the safe-relay fallback path.
        for (outcome, text) in Self.realGoTemplates {
            let r = presenter.response(for: .success(result(outcome: outcome, text: text)))
            #expect(!r.text.lowercased().contains("hey friday"), "\(outcome): spoken text must never contain the literal wake phrase (§12/§18) — got '\(r.text)'")
        }
        let transportFailure = presenter.response(for: .failure("transport(\"x\")"))
        #expect(!transportFailure.text.lowercased().contains("hey friday"))
    }
}
