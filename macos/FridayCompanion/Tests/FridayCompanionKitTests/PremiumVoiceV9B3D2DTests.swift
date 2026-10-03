import Testing
@testable import FridayCompanionKit

/// P2-M5V9-B.3D.2D — mock-only preflight tests for the developer-only
/// local Chatterbox conditioning harness. NO real performer asset, no
/// real Chatterbox service, no real recording is used anywhere here —
/// every input is a synthetic dictionary literal. These tests exist
/// specifically because no authorized performer asset exists yet; they
/// prove the GATE works correctly, never that a real conditioning run
/// succeeded (no such claim is made anywhere in this suite).
@Suite struct PremiumVoiceV9B3D2DTests {
    private let repoRoot = "/Users/survaghasiya/Documents/FRIDAY"

    private func validManifest(filename: String = "friday_v2_neutral_0001.wav", rightsRecordID: String? = "rights-test-0001", approved: Bool = true) -> [String: Any] {
        var asset: [String: Any] = ["asset_id": "asset-0001", "filename": filename, "approved": approved]
        if let rightsRecordID { asset["rights_record_id"] = rightsRecordID }
        return ["manifest_id": "m-test", "assets": [asset]]
    }

    private func validProvenance(rightsRecordID: String = "rights-test-0001") -> [[String: Any]] {
        [["provenance_id": "prov-0001", "rights_record_id": rightsRecordID]]
    }

    private func validQCReport(filename: String = "friday_v2_neutral_0001.wav", verdict: String = "PASS") -> [String: Any] {
        ["files": [["filename": filename, "verdict": verdict]]]
    }

    // MARK: - the fully-authorized, happy path

    @Test func validAuthorizedSyntheticMetadata_isReady_andRequestBuildsCorrectly() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/friday-voice-assets/friday_v2_neutral_0001.wav",
            repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.5
        )
        guard case .ready(let filename, let duration) = result else {
            Issue.record("expected .ready, got \(result)"); return
        }
        #expect(filename == "friday_v2_neutral_0001.wav")
        #expect(duration == 8.5)

        let body = buildLocalConditioningRequestBody(text: "hello", language: "en", variant: "turbo", approvedReferencePath: "/private/tmp/friday-voice-assets/friday_v2_neutral_0001.wav")
        #expect(body["variant"] as? String == "turbo")
        #expect(body["audio_prompt_path"] as? String == "/private/tmp/friday-voice-assets/friday_v2_neutral_0001.wav")
        #expect(body["text"] as? String == "hello")
    }

    // MARK: - each required blocked case

    @Test func noReferenceProvided_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: nil, repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("no reference"))
    }

    @Test func repoLocalReferencePath_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: repoRoot + "/schemas/voice-v2/examples/valid-manifest.json",
            repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("repo-local"))
    }

    @Test func missingRightsRecordID_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(rightsRecordID: nil), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("rights_record_id"))
    }

    @Test func missingProvenance_isBlocked_whenRightsRecordIDDoesNotResolve() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(rightsRecordID: "rights-that-does-not-exist"),
            provenanceRecords: validProvenance(rightsRecordID: "a-totally-different-id"),
            qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("provenance"))
    }

    @Test func notApproved_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(approved: false), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("approved"))
    }

    @Test func qcNotPass_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(verdict: "REJECT"),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("QC verdict"))
    }

    @Test func qcReportMissingEntryForReference_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(filename: "some-other-file.wav"),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked = result else { Issue.record("expected .blocked, got \(result)"); return }
    }

    @Test func referenceExactlyFiveSeconds_isBlocked_forTurbo_strictGreaterThan() {
        // Turbo's own installed-package assertion is `> 5.0`, not `>= 5.0`.
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 5.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("5.0"))
    }

    @Test func referenceUnderFiveSeconds_isBlocked_forTurbo() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 3.2
        )
        guard case .blocked = result else { Issue.record("expected .blocked, got \(result)"); return }
    }

    @Test func referenceJustOverFiveSeconds_isReady_forTurbo() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 5.01
        )
        guard case .ready = result else { Issue.record("expected .ready, got \(result)"); return }
    }

    @Test func manifestMissing_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/friday_v2_neutral_0001.wav", repositoryRoot: repoRoot,
            manifestJSON: nil, provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("manifest"))
    }

    @Test func referenceNotFoundInManifest_isBlocked() {
        let result = evaluateLocalConditioningPreflight(
            referencePath: "/private/tmp/x/never-recorded.wav", repositoryRoot: repoRoot,
            manifestJSON: validManifest(), provenanceRecords: validProvenance(), qcReportJSON: validQCReport(),
            variant: "turbo", referenceDurationSeconds: 8.0
        )
        guard case .blocked(let reason) = result else { Issue.record("expected .blocked, got \(result)"); return }
        #expect(reason.contains("not found in manifest"))
    }

    @Test func nonTurboVariant_hasZeroMinimumDuration_perInstalledPackageBehavior() {
        #expect(minimumReferenceDurationSeconds(forVariant: "base-english") == 0.0)
        #expect(minimumReferenceDurationSeconds(forVariant: "multilingual") == 0.0)
        #expect(minimumReferenceDurationSeconds(forVariant: "turbo") == 5.0)
    }
}
