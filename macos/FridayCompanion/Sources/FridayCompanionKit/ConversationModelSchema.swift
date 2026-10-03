import Foundation

/// P2-M5V8 §7 — the STRICT, typed wire shape for STAGE A (UNDERSTAND).
/// Deliberately does NOT include `actionExecutionState`/`failureReason`/
/// `retryability` — those remain exclusively local/authoritative
/// (`ConversationalResponsePresenter.authoritative(_:context:)`, built in
/// the prior Final Architectural Invariants pass, already discards any
/// reasoner's opinion on them regardless of source) — the model is never
/// even ASKED for them, closing §5's "do not send authority to the
/// model" at the schema level, not just the validation level.
struct ModelUnderstandingWire: Decodable {
    let dialogueAct: String
    let interactionMode: String
    let userGoal: String?
    let topic: String?
    let continuationReference: Bool?
    let correctionTarget: String?
    let explicitConstraints: [String]?
    let recommendedSocialRegister: String?
    let humorSuitability: Double?
    let followUpNeed: Bool?
    let uncertainty: Double?
}

/// P2-M5V8 §8 — the STRICT, typed wire shape for STAGE B (REALIZE). Only
/// `text` is ever actually used (see `ModelNaturalResponseRealizer`'s own
/// doc comment) — `responseGoal`/`socialRegister`/`humorUsed`/`prosodyIntent`
/// are accepted for diagnostics/logging only, never authoritative (the
/// LOCAL `NaturalResponsePlan`, computed before this stage is even
/// called, already decided all of those).
struct ModelRealizationWire: Decodable {
    let text: String
    let responseGoal: String?
    let socialRegister: String?
    let humorUsed: Bool?
    let prosodyIntent: String?
}

/// P2-M5V8.1-O §1/§3/§11 — the ONE-CALL unified wire shape: BOTH stage
/// products decoded from a SINGLE provider response. Deliberately reuses
/// `ModelUnderstandingWire`/`ModelRealizationWire` UNCHANGED (nested,
/// not flattened) rather than inventing a new, parallel field list — §3:
/// "do not silently drop an existing reasoning field merely to simplify
/// the schema." The strict, fail-closed decoding of each nested wire type
/// is completely unchanged; this adds no new tolerance anywhere (§11:
/// "do not loosen enum validation because one-call output is larger").
struct ModelUnifiedWire: Decodable {
    let reasoning: ModelUnderstandingWire
    let response: ModelRealizationWire
}

/// P2-M5V8 §7 — strict decode + bounds validation, entirely separate from
/// JSON syntax decoding (a syntactically valid JSON object can still be a
/// semantic schema violation — e.g. an illegal enum string, an
/// out-of-range number, an oversized array). Every function here returns
/// `nil` on ANY violation — never partially applies a malformed value,
/// never guesses, never "repairs" (§18: "do NOT repair an unsafe model
/// response with regex substitutions — discard it completely").
enum ConversationModelSchema {
    static let maxStringLength = 200
    static let maxArrayItems = 5

    /// `InteractionMode` has NO `.unknown` case (§7: "every enum must
    /// reject unknown illegal values unless the repository explicitly
    /// models `.unknown`") — an unrecognized string here is STILL a hard
    /// rejection of the WHOLE understanding, not a silent default.
    ///
    /// P2-M5V8.1-S2 §2/§6 — normalizes case/whitespace ONLY, e.g. accepts
    /// "ActionRequest"/" actionRequest "/"action_request" identically to
    /// "actionRequest" — a real, live-observed LLM structured-output
    /// quirk (models frequently vary casing/separators even when told an
    /// exact string), not a semantic weakening: a value that isn't one of
    /// these SIX concepts under any casing/separator is still rejected
    /// exactly as before (§6: "do NOT weaken illegal InteractionMode
    /// rejection merely to make the provider pass").
    static func interactionMode(from raw: String) -> InteractionMode? {
        switch Self.normalize(raw) {
        case "actionrequest": return .actionRequest
        case "informationrequest": return .informationRequest
        case "conversational": return .conversational
        case "correction": return .correction
        case "constraint": return .constraint
        case "clarification": return .clarification
        default: return nil
        }
    }

    /// Lowercases and strips whitespace/underscores/hyphens only — never
    /// touches which distinct CONCEPTS are recognized, only how liberally
    /// their spelling is matched.
    private static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `DialogueAct` DOES model `.unknown` explicitly — an unrecognized
    /// string safely maps there rather than rejecting the response,
    /// matching §7's own carve-out. Same case/whitespace normalization as
    /// `interactionMode(from:)` above, same reasoning.
    ///
    /// P2-M5V8.1-S2 §5 — audited: `needStatement`/`styleRefinement`
    /// (added by P2-M5V8.1-S) were previously ABSENT from this switch.
    /// Because `DialogueAct` already has the `.unknown` safety net, their
    /// absence never poisoned the whole reasoner response (a model
    /// emitting either string would harmlessly become `.unknown`, not a
    /// rejection) — audit CONCLUSION: not the cause of the 100% reasoner
    /// failure (that was `interactionMode`'s zero-tolerance decode,
    /// above). Added anyway for correctness/future value now that the
    /// authoritative layer's local-evidence veto (see
    /// `ConversationalResponsePresenter.authoritative`) makes these two
    /// categories reachable and meaningful even when the MODEL itself is
    /// the one classifying.
    static func dialogueAct(from raw: String) -> DialogueAct {
        switch Self.normalize(raw) {
        case "command": return .command
        case "request": return .request
        case "question": return .question
        case "statement": return .statement
        case "personalupdate": return .personalUpdate
        case "acknowledgement": return .acknowledgement
        case "correction": return .correction
        case "clarification": return .clarification
        case "constraint": return .constraint
        case "prohibition": return .prohibition
        case "permissionresponse": return .permissionResponse
        case "followup": return .followUp
        case "explanationrequest": return .explanationRequest
        case "confirmationrequest": return .confirmationRequest
        case "socialremark": return .socialRemark
        case "jokeorplayfulremark": return .jokeOrPlayfulRemark
        case "greeting": return .greeting
        case "farewell": return .farewell
        case "needstatement": return .needStatement
        case "stylerefinement": return .styleRefinement
        default: return .unknown
        }
    }

    static func socialRegister(from raw: String?) -> SocialRegister? {
        switch raw {
        case "casualFriendly": return .casualFriendly
        case "friendlyNeutral": return .friendlyNeutral
        case "professional": return .professional
        case "focused": return .focused
        case "reassuring": return .reassuring
        case "serious": return .serious
        case "warning": return .warning
        case "urgent": return .urgent
        default: return nil // absent/unrecognized -> no recommendation, never a hard failure (this field is advisory)
        }
    }

    private static func boundedString(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(maxStringLength))
    }

    private static func explicitConstraints(from raw: [String]?) -> [ExplicitConstraint] {
        guard let raw else { return [] }
        let table: [String: ExplicitConstraint] = [
            "doNotAct": .doNotAct, "doNotModify": .doNotModify, "waitForConfirmation": .waitForConfirmation,
            "keepExistingState": .keepExistingState, "answerOnly": .answerOnly, "explainOnly": .explainOnly,
        ]
        return raw.prefix(maxArrayItems).compactMap { table[$0] }
    }

    /// Returns `nil` on ANY schema violation (§7/§18) — the caller must
    /// treat that identically to "provider unavailable": discard and
    /// fall back, never partially trust the result.
    static func understanding(from wire: ModelUnderstandingWire) -> ConversationUnderstanding? {
        guard let interactionMode = interactionMode(from: wire.interactionMode) else { return nil }
        let dialogueAct = dialogueAct(from: wire.dialogueAct)
        let uncertainty = (wire.uncertainty ?? 0.5).isFinite ? min(max(wire.uncertainty ?? 0.5, 0), 1) : 0.5
        let humorSuitability = (wire.humorSuitability ?? 0).isFinite ? min(max(wire.humorSuitability ?? 0, 0), 1) : 0
        return ConversationUnderstanding(
            communicativeIntent: .unknown, // legacy P2-M5V6 field — the model speaks the richer DialogueAct instead
            topic: boundedString(wire.topic), continuationOfPreviousTurn: wire.continuationReference ?? false,
            clarificationNeeded: interactionMode == .clarification, userExplicitPreference: nil,
            explicitUrgency: false, // never model-derived (§19 of P2-M5V6: explicit language only, and urgency detection stays local/deterministic for safety)
            socialRegisterRecommendation: socialRegister(from: wire.recommendedSocialRegister),
            humorAppropriateness: humorSuitability > 0, responseGoal: nil, recommendedVerbosity: nil,
            followUpNeeded: wire.followUpNeed ?? false, uncertainty: uncertainty,
            dialogueAct: dialogueAct, interactionMode: interactionMode,
            // actionExecutionState/failureReason/retryability: NEVER set
            // from the model — left at their safe `ConversationUnderstanding.init`
            // defaults here (.unknown/.unknown/.unknown) since
            // `ConversationalResponsePresenter.authoritative(_:context:)`
            // recomputes them unconditionally anyway.
            explicitConstraints: explicitConstraints(from: wire.explicitConstraints),
            userGoal: boundedString(wire.userGoal), correctionTarget: boundedString(wire.correctionTarget),
            explanationRequested: dialogueAct == .explanationRequest, humorSuitability: humorSuitability
        )
    }

    /// `text` must be non-empty and bounded — everything else in the
    /// wire payload is advisory/diagnostic only (see `ModelRealizationWire`'s
    /// own doc comment).
    static func realizedText(from wire: ModelRealizationWire) -> String? {
        let trimmed = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= DeterministicResponsePresenter.maxSpokenLength else { return nil }
        return trimmed
    }

    /// P2-M5V8.1-O §3/§24 — validates BOTH halves of a unified response by
    /// reusing `understanding(from:)`/`realizedText(from:)` UNCHANGED, and
    /// returns `nil` if EITHER is invalid. §24: "provider output invalid
    /// -> deterministic full fallback... no partial fake success" — a
    /// reasoning proposal that decodes fine alongside unusable candidate
    /// text (or vice versa) is not a "half-good" result to salvage; the
    /// caller falls back to full local computation for the whole turn.
    static func unified(from wire: ModelUnifiedWire) -> (understanding: ConversationUnderstanding, candidateText: String)? {
        guard let understanding = understanding(from: wire.reasoning), let text = realizedText(from: wire.response) else { return nil }
        return (understanding, text)
    }
}
