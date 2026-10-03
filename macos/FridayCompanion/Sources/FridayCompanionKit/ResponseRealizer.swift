import Foundation

/// P2-M5V5 §1/§11 — the "WHAT FRIDAY SHOULD SAY" pipeline stage:
/// `ConversationContext` + `ResponseStrategy` → spoken text (pre-
/// validation — `ResponseValidation` runs afterward). This is where
/// every phrase bank and the deterministic-variant-selection mechanism
/// (originally introduced directly inside `DeterministicResponsePresenter`
/// at P2-M5V3 §8) now live, as their own separately-testable component
/// (§1: "do not put all behavior inside one giant presenter switch
/// statement"). `DeterministicResponsePresenter` keeps thin, `static`
/// backward-compatible forwarding members to everything below, so every
/// pre-P2-M5V5 test that referenced `DeterministicResponsePresenter.<member>`
/// directly keeps compiling and behaving identically.
public protocol ResponseRealizing: Sendable {
    /// - Parameter avoiding: the immediately-previous DISTINCT
    ///   interaction's exact text for this same family, if any (§15) —
    ///   `nil` when there is nothing to avoid (fresh process, first
    ///   interaction in this family, or a replay of the same taskID).
    func realize(context: ConversationContext, strategy: ResponseStrategy, avoiding: String?) -> String
}

public struct DeterministicResponseRealizer: ResponseRealizing {
    public init() {}

    public func realize(context: ConversationContext, strategy: ResponseStrategy, avoiding: String?) -> String {
        if context.responseFamily == .transportFailure {
            // Never reached a real Go `Response` at all — this type's
            // own fixed, truthful fallback (§8 of P2-M5's own
            // authorization: "RUNTIME_UNAVAILABLE/transport failure").
            return "I'm having trouble reaching the system right now."
        }
        // Every other family's text is still keyed on the real Go
        // template text carried inside `outcomeCode`/the original
        // `RuntimeTextResult` — but by this stage `ConversationContext`
        // has already classified WHICH family it is, so realization
        // dispatches on that classification directly, not by
        // re-matching text a second time.
        switch context.responseFamily {
        case .systemStatusSuccess:
            return Self.pick(Self.getStatusSuccessVariants, taskID: context.taskID, avoiding: avoiding)
        case .createNoteSuccess:
            // The title itself is carried in `avoiding`'s sibling data
            // path — see `DeterministicResponsePresenter.response(for:)`,
            // which still has the raw Go text available and passes the
            // ALREADY-EXTRACTED title through `ConversationContext`
            // indirectly via the realizer being invoked with the same
            // outcome text at the orchestrator level. To keep this
            // realizer a pure function of its two typed parameters
            // (no hidden raw-text dependency), title extraction is
            // re-derived here from the one place it's still available:
            // the outcome code carries no title, so the orchestrator
            // pre-resolves this family's variants before calling this
            // function in the one case that needs dynamic content — see
            // `DeterministicResponsePresenter.response(for:)`'s own
            // `createNoteTitle` handling.
            return Self.pick(Self.createNoteSuccessVariants(title: context.noteTitleForRealization ?? "note"), taskID: context.taskID, avoiding: avoiding)
        case .genericSuccess:
            return "Done."
        case .unsupportedIntent:
            return Self.pick(Self.unsupportedIntentVariants, taskID: context.taskID, avoiding: avoiding)
        case .ambiguousIntent:
            return Self.ambiguousIntentText(context: context)
        case .invalidRequest:
            return "I didn't quite catch a usable request."
        case .irValidationFailed:
            return "That didn't pass my checks, so I didn't attempt it."
        case .policyDenied:
            return Self.pick(Self.policyDeniedVariants, taskID: context.taskID, avoiding: avoiding)
        case .policyUnavailable:
            return "I'm having trouble authorizing that right now."
        case .capabilityUnavailable:
            return "I can't do that right now."
        case .executionFailed:
            return Self.pick(Self.executionFailedVariants, taskID: context.taskID, avoiding: avoiding)
        case .verificationFailed:
            return "That ran, but I couldn't confirm the result."
        case .verificationNeedsReview:
            return "A stop was requested after that action may have already taken effect. I can't confirm it was undone, so this needs a manual review."
        case .cancelled:
            return "Done. I've cancelled that."
        case .alreadyTerminal:
            return "That task has already finished, so there's nothing to stop."
        case .duplicateRequest:
            return "That exact request is already in progress."
        case .internalError:
            return Self.pick(Self.internalErrorVariants, taskID: context.taskID, avoiding: avoiding)
        case .transportFailure:
            return "I'm having trouble reaching the system right now." // unreachable (handled above); kept exhaustive and safe
        case .other:
            // §8's own core safety property, carried forward unchanged
            // into this pipeline: an outcome/text shape this file
            // doesn't specifically recognize must relay the runtime's
            // own already-audited, already-safe text UNCHANGED — never
            // guessed at, never silently dropped, and never defaulted to
            // a fixed phrase that could accidentally assert a truth
            // value (success or failure) this layer doesn't actually
            // know. `wasSuccess` (derived independently from the real
            // outcome code, not from this text) still governs the
            // post-realization truth check downstream.
            return context.rawRuntimeText
        }
    }

    private static func ambiguousIntentText(context: ConversationContext) -> String {
        // §10's own example: a title-specific clarification reads more
        // naturally than the generic "(missing: title)" phrasing when
        // that's genuinely what's missing.
        if context.ambiguousMissingField == "title" {
            return "What did you want the note called?"
        }
        if let field = context.ambiguousMissingField {
            return "I need a bit more information to do that (missing: \(field))."
        }
        return "I need a bit more information to do that."
    }

    // MARK: - Phrase banks (moved from `DeterministicResponsePresenter` at P2-M5V5, extended)

    /// Unchanged since P2-M5V4 §6's own evaluated tightening.
    static let getStatusSuccessVariants = [
        "The system check completed successfully.",
        "System check complete.",
        "Everything's set. The system check is complete.",
    ]

    static func createNoteSuccessVariants(title: String) -> [String] {
        [
            "Done. Your note is ready.",
            "Done. I created the note.",
            "It's done. Your note is ready.",
            "Done. I created your \(title) note.",
        ]
    }

    /// P2-M5V5 §6 adds "I can't do that one yet." (the exact phrasing
    /// example given for this milestone), alongside the three carried
    /// from P2-M5V3.
    static let unsupportedIntentVariants = [
        "Sorry, I can't do that just yet.",
        "I can't do that yet.",
        "That's not something I can do yet.",
        "I can't do that one yet.",
    ]

    /// P2-M5V5 §10 new variant set — previously a single fixed string
    /// ("I don't have permission to do that."); now includes the
    /// owner's own "Permission required" example phrasing too. Both say
    /// exactly the same thing (authorization was denied).
    static let policyDeniedVariants = [
        "I don't have permission to do that.",
        "I need your approval before I can continue.",
    ]

    /// P2-M5V5 §10 new variant set — adds "That didn't go through." (the
    /// owner's own retryable-failure example) alongside the original
    /// phrasing. Both say exactly the same thing (the action failed).
    static let executionFailedVariants = [
        "I couldn't complete that request.",
        "That didn't go through.",
    ]

    /// P2-M5V5 §10 new variant set — adds "I'm not sure what caused
    /// that yet." (the owner's own "unknown cause" example, an exact
    /// match for what INTERNAL_ERROR actually is: a failure whose root
    /// cause this layer genuinely does not know).
    static let internalErrorVariants = [
        "Something went wrong on my end, and the action wasn't performed.",
        "I'm not sure what caused that yet.",
    ]

    /// A small, non-cryptographic, ORDER-STABLE string hash (FNV-1a) —
    /// deliberately NOT Swift's built-in `String.hashValue`/`Hasher`,
    /// which reseed randomly per process launch by default and would
    /// make variant selection change between runs.
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037 // FNV-1a 64-bit offset basis
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211 // FNV-1a 64-bit prime
        }
        return hash
    }

    /// Deterministically selects one of `variants` keyed on `taskID`.
    /// P2-M5V5 §15: if the hash-selected candidate exactly matches
    /// `avoiding` (the immediately-previous DISTINCT interaction's
    /// text for this same family) and a different, equally-valid option
    /// exists, deterministically shifts to the next variant in sequence
    /// instead — still a pure function of `(variants, taskID, avoiding)`,
    /// never real randomness, never breaking "same taskID always
    /// produces the same result" (avoidance only ever compares against
    /// a DIFFERENT prior taskID's text, never the current one's own).
    static func pick(_ variants: [String], taskID: String, avoiding: String? = nil) -> String {
        guard !variants.isEmpty else { return "" }
        let index = Int(stableHash(taskID) % UInt64(variants.count))
        let candidate = variants[index]
        if let avoiding, candidate == avoiding, variants.count > 1 {
            return variants[(index + 1) % variants.count]
        }
        return candidate
    }

    /// P2-M5V8.1-S3 §11/§28 — repetition avoidance across MORE than just
    /// the single immediately-previous turn: walks forward through
    /// `variants` (still fully deterministic — no real randomness, still
    /// a pure function of its inputs) until it finds one not in
    /// `recentTexts`, so a short reaction/acknowledgement pool doesn't
    /// settle into repeating the same line for several turns running
    /// (§28's own example: "Got it." "Got it." "Got it."). Falls back to
    /// the plain hash-selected candidate if every variant is already in
    /// `recentTexts` (better to repeat once than return nothing).
    static func pick(_ variants: [String], taskID: String, avoidingAny recentTexts: [String]) -> String {
        guard !variants.isEmpty else { return "" }
        let avoided = Set(recentTexts)
        let startIndex = Int(stableHash(taskID) % UInt64(variants.count))
        for offset in 0..<variants.count {
            let candidate = variants[(startIndex + offset) % variants.count]
            if !avoided.contains(candidate) { return candidate }
        }
        return variants[startIndex]
    }

    /// `CreateNoteSuccess`'s exact Go template is
    /// `fmt.Sprintf("Created and verified note %q.", title)`, which Go's
    /// `%q` renders as `Created and verified note "<title>".` — a fixed
    /// prefix/suffix around one dynamic field, extracted here without a
    /// full regex engine since the shape is this simple and fixed.
    static func extractCreateNoteTitle(from text: String) -> String? {
        let prefix = "Created and verified note \""
        let suffix = "\"."
        guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count >= prefix.count + suffix.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(text[start..<end])
    }

    /// The `AMBIGUOUS_INTENT` "(missing: X)" suffix, if present.
    static func extractAmbiguousMissingField(from text: String) -> String? {
        let prefix = "I need more information to do that (missing: "
        guard text.hasPrefix(prefix), text.hasSuffix(")."), text.count > prefix.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -2) // strip ")."
        guard start < end else { return nil }
        return String(text[start..<end])
    }
}
