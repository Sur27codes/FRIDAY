import Foundation

/// P2-M5V9-B.3D.2D — pure, mock-testable preflight gate for the
/// developer-only `friday-v2-local-conditioning` harness. NEVER sends a
/// reference to Chatterbox unless every one of these checks passes.
/// Deliberately takes already-loaded JSON/duration values (not file
/// paths) so the whole decision path is testable with plain dictionary
/// literals, with no file I/O, no real Chatterbox service, and no real
/// performer asset required — exactly what B.3D.2D's mock-testing
/// requirement asks for. The actual file-reading/IPC-sending happens in
/// `VoiceAuditionTool`'s harness, which calls this function first and
/// refuses to proceed past a `.blocked` result under any circumstance.
public enum LocalConditioningPreflightResult: Sendable, Equatable {
    case ready(referenceFilename: String, durationSeconds: Double)
    case blocked(reason: String)
}

/// Per-variant minimum reference-audio duration, from B.3D.0/B.3D.1's
/// own real source-inspection of the installed `chatterbox-tts` package
/// (Turbo's own `prepare_conditionals` asserts `len(wav)/sr > 5.0`;
/// base-english/multilingual enforce no minimum in the installed
/// version, but conservatively still require a positive duration here).
public func minimumReferenceDurationSeconds(forVariant variant: String) -> Double {
    variant == "turbo" ? 5.0 : 0.0
}

/// Evaluates every precondition B.3D.2D requires before a reference
/// asset may be sent to Chatterbox for conditioning:
///   - a reference path was actually provided (never a bundled default)
///   - the reference does not live inside the repository
///   - the reference resolves to a manifest entry
///   - that entry has a non-empty `rights_record_id`
///   - that `rights_record_id` resolves against a loaded provenance record
///   - that entry is `approved == true`
///   - a QC report entry exists for this file and its verdict is `PASS`
///   - the reference's own audio duration exceeds the variant's minimum
public func evaluateLocalConditioningPreflight(
    referencePath: String?,
    repositoryRoot: String,
    manifestJSON: [String: Any]?,
    provenanceRecords: [[String: Any]]?,
    qcReportJSON: [String: Any]?,
    variant: String,
    referenceDurationSeconds: Double?
) -> LocalConditioningPreflightResult {
    guard let referencePath, !referencePath.isEmpty else {
        return .blocked(reason: "no reference provided")
    }
    let normalizedRoot = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
    if referencePath.hasPrefix(normalizedRoot) || referencePath == repositoryRoot {
        return .blocked(reason: "repo-local reference path — references must live outside the repository")
    }

    let filename = (referencePath as NSString).lastPathComponent

    guard let manifestJSON, let assets = manifestJSON["assets"] as? [[String: Any]] else {
        return .blocked(reason: "manifest missing or unreadable")
    }
    guard let asset = assets.first(where: { ($0["filename"] as? String) == filename }) else {
        return .blocked(reason: "reference not found in manifest")
    }
    guard let rightsRecordID = asset["rights_record_id"] as? String, !rightsRecordID.isEmpty else {
        return .blocked(reason: "missing rights_record_id")
    }
    guard let provenanceRecords, provenanceRecords.contains(where: { ($0["rights_record_id"] as? String) == rightsRecordID }) else {
        return .blocked(reason: "missing provenance — rights_record_id does not resolve to a loaded provenance record")
    }
    guard (asset["approved"] as? Bool) == true else {
        return .blocked(reason: "asset is not approved")
    }
    guard let qcReportJSON, let files = qcReportJSON["files"] as? [[String: Any]],
          let fileReport = files.first(where: { ($0["filename"] as? String) == filename }) else {
        return .blocked(reason: "no QC report entry for this reference")
    }
    guard (fileReport["verdict"] as? String) == "PASS" else {
        return .blocked(reason: "QC verdict is not PASS")
    }
    guard let referenceDurationSeconds else {
        return .blocked(reason: "could not determine reference duration")
    }
    let minimum = minimumReferenceDurationSeconds(forVariant: variant)
    guard referenceDurationSeconds > minimum else {
        return .blocked(reason: "reference duration \(referenceDurationSeconds)s does not exceed the \(minimum)s minimum required for variant '\(variant)'")
    }
    return .ready(referenceFilename: filename, durationSeconds: referenceDurationSeconds)
}

/// Builds the exact wire request body for a conditioned local
/// synthesis call — the SAME `{"text","language","variant"}` shape
/// every other local Chatterbox caller in this codebase already sends,
/// with the new, additive `audio_prompt_path` field (B.3D.2D) included
/// ONLY when a preflight-approved reference is supplied. Pure/testable:
/// takes the already-approved reference path directly, never re-checks
/// the gate itself (the caller must have already gotten `.ready` from
/// `evaluateLocalConditioningPreflight` before ever calling this).
public func buildLocalConditioningRequestBody(text: String, language: String, variant: String, approvedReferencePath: String) -> [String: Any] {
    ["text": text, "language": language, "variant": variant, "audio_prompt_path": approvedReferencePath]
}
