import Foundation

/// P2-M5V5 §1 — the first stage of the new pipeline: `RuntimeTextResult`
/// / `CommandRuntimeOutcome` → `ConversationContext`. Classifies which
/// real Go `response.go` template family produced this outcome, and
/// derives the small set of honest boolean facts `ConversationContext`
/// carries — never anything about the user beyond what the runtime
/// itself already decided.
public protocol ConversationContextCompiling: Sendable {
    func compile(outcome: CommandRuntimeOutcome, recentResponseFamilies: [ResponseFamily]) -> ConversationContext
}

public struct DeterministicConversationContextCompiler: ConversationContextCompiling {
    public init() {}

    public func compile(outcome: CommandRuntimeOutcome, recentResponseFamilies: [ResponseFamily]) -> ConversationContext {
        switch outcome {
        case .success(let result):
            let family = Self.classifyFamily(outcomeCode: result.outcome, rawText: result.text)
            let isSuccess = (result.outcome == "SUCCESS")
            return ConversationContext(
                interactionID: result.taskID, taskID: result.taskID, outcomeCode: result.outcome, responseFamily: family,
                wasSuccess: isSuccess, isVerifiedData: isSuccess,
                needsClarification: family == .ambiguousIntent,
                isRetryable: Self.isRetryable(family),
                isFollowUpMeaningful: false, // see ConversationContext's own doc comment
                recentResponseFamilies: recentResponseFamilies,
                noteTitleForRealization: family == .createNoteSuccess
                    ? DeterministicResponseRealizer.extractCreateNoteTitle(from: result.text) : nil,
                ambiguousMissingField: family == .ambiguousIntent
                    ? DeterministicResponseRealizer.extractAmbiguousMissingField(from: result.text) : nil,
                rawRuntimeText: result.text
            )
        case .failure:
            // A transport-level failure never reached a real Go
            // `Response` at all — there is no real `taskID` to report
            // (the request never got far enough to receive one), so a
            // fixed, clearly-synthetic placeholder is used instead of
            // fabricating one. `ResponseRealizer`'s variant selection
            // for this family does not depend on a real per-interaction
            // taskID the way the runtime-reached families do.
            return ConversationContext(
                interactionID: "transport-failure", taskID: "", outcomeCode: "(transport failure)",
                responseFamily: .transportFailure, wasSuccess: false, isVerifiedData: false,
                needsClarification: false, isRetryable: true, isFollowUpMeaningful: false,
                recentResponseFamilies: recentResponseFamilies,
                rawRuntimeText: "I'm having trouble reaching the system right now."
            )
        }
    }

    /// The same classification `ResponsePresenting.swift`'s own
    /// pattern-matching already performs — centralized here so
    /// `ConversationContext.responseFamily` and the actual text
    /// `ResponseRealizer` selects can never disagree about which family
    /// an outcome belongs to.
    static func classifyFamily(outcomeCode: String, rawText: String) -> ResponseFamily {
        if outcomeCode == "SUCCESS" {
            if rawText == "System status retrieved successfully." { return .systemStatusSuccess }
            if DeterministicResponseRealizer.extractCreateNoteTitle(from: rawText) != nil { return .createNoteSuccess }
            return .genericSuccess
        }
        switch outcomeCode {
        case "UNSUPPORTED_INTENT": return .unsupportedIntent
        case "AMBIGUOUS_INTENT": return .ambiguousIntent
        case "INVALID_TEXT_REQUEST": return .invalidRequest
        case "IR_VALIDATION_FAILED": return .irValidationFailed
        case "POLICY_DENIED": return .policyDenied
        case "POLICY_UNAVAILABLE": return .policyUnavailable
        case "CAPABILITY_UNAVAILABLE": return .capabilityUnavailable
        case "EXECUTION_FAILED": return .executionFailed
        case "VERIFICATION_FAILED":
            return rawText.localizedCaseInsensitiveContains("manual review") ? .verificationNeedsReview : .verificationFailed
        case "CANCELLED": return .cancelled
        case "ALREADY_TERMINAL": return .alreadyTerminal
        case "DUPLICATE_REQUEST": return .duplicateRequest
        case "INTERNAL_ERROR": return .internalError
        default: return .other
        }
    }

    /// Retrying the exact same request could plausibly succeed later
    /// only for genuine availability/transient problems — never for
    /// outcomes where the SAME input will always produce the SAME
    /// result (unsupported, denied, already-terminal, a validation
    /// failure needing different input, etc.).
    static func isRetryable(_ family: ResponseFamily) -> Bool {
        switch family {
        case .capabilityUnavailable, .policyUnavailable, .executionFailed:
            return true
        default:
            return false
        }
    }
}
