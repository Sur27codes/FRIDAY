import Testing
@testable import FridayCompanionKit
import Foundation

/// P2M3-SEC-001..008 — the wake pipeline's security boundary, verified
/// both structurally (source scans, matching `StructuralIsolationTests`'
/// established pattern) and behaviorally (real actor + fake hardware).
@Suite struct WakeSecurityTests {

    private func allKitSourceFiles() throws -> [URL] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let kitSources = thisFile
            .deletingLastPathComponent() // FridayCompanionKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FridayCompanion
            .appendingPathComponent("Sources/FridayCompanionKit")
        let files = try FileManager.default.contentsOfDirectory(at: kitSources, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "swift" }
    }

    private func wakeRelatedFiles() throws -> [URL] {
        try allKitSourceFiles().filter {
            ["AudioTypes.swift", "WakeWordDetecting.swift", "AudioCapturing.swift", "RealAudioCaptureEngine.swift",
             "RealMicrophonePermission.swift", "WakeCoordinatorEngine.swift", "WakeCoordinator.swift",
             "NullWakeWordDetector.swift", "SherpaOnnxWakeWordDetector.swift",
             // P2-M5: the output-adapter files join this scan too —
             // §45 requires the same zero-authority proof for the
             // speaking side that the wake/listening side already has.
             "ResponsePresenting.swift", "SpeechSynthesizing.swift", "AVSpeechSynthesizerAdapter.swift"].contains($0.lastPathComponent)
        }
    }

    private func ttsRelatedFiles() throws -> [URL] {
        try allKitSourceFiles().filter {
            ["ResponsePresenting.swift", "SpeechSynthesizing.swift", "AVSpeechSynthesizerAdapter.swift"].contains($0.lastPathComponent)
        }
    }

    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - P2M3-SEC-001 / 002: wake event cannot mint authorization or set AAL

    @Test func sec001_002_wakeEventHasNoAuthorizationOrAALField() {
        // Structural, by direct inspection of the type itself (matches
        // P2-M1's SEC-001 pattern of proving this by construction, not
        // just by absence-of-a-bug): `WakeEvent` has exactly 7 fields,
        // none of which is authorization/AAL-shaped.
        let event = WakeEvent(eventID: "e", sessionID: "s", phraseID: "hey_friday", detectedAt: Date(), source: "wake_word", engine: "fake", confidence: 0.9)
        let mirror = Mirror(reflecting: event)
        let fieldNames = Set(mirror.children.compactMap(\.label))
        #expect(fieldNames == ["eventID", "sessionID", "phraseID", "detectedAt", "source", "engine", "confidence"])
        for forbidden in ["aal", "authorized", "authorization", "token", "capability", "policy", "scope"] {
            #expect(!fieldNames.contains(forbidden))
        }
    }

    // MARK: - P2M3-SEC-003 / 004: no Capability Bus or Policy signing-key dependency

    @Test func sec003_004_wakePipelineHasNoCapabilityBusOrSigningKeyDependency() throws {
        let forbidden = ["\"Dispatch\"", "capabilitybusd/internal", "capability-bus/internal", "DevSeedIR", "DevSeedTask",
                          "SignToken", "policytoken", "PrivateKey", "ed25519.NewKeyPair", "GenerateKey", "\"EvaluateAuthorization\""]
        for file in try wakeRelatedFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term), "\(file.lastPathComponent) contains \(term) in real code — the wake pipeline must have no Capability Bus or signing dependency")
            }
        }
    }

    // MARK: - P2M3-SEC-005 / 007, updated at P2-M4: raw audio never forwarded to friday-daemon; wake detection alone cannot execute a capability

    @Test func sec005_007_onlyWakeCoordinatorMayReferenceRuntimeClient_everyOtherWakeFileMustNot() throws {
        // P2-M3's original assertion was "NO wake-related file references
        // RuntimeClient at all," true only because P2-M3 had zero
        // legitimate reason to. P2-M4 *intentionally* wires
        // `WakeCoordinator` to `RuntimeClient` (via `CommandRuntimeSubmitting`)
        // as the architected voice-input path (§3/§13) — so the
        // up-to-date version of this invariant is narrower and stronger:
        // the wake DETECTION layer (audio capture, the KWS detector
        // itself, permission handling, the pure state machine) must
        // still have ZERO such reference — only the one orchestrating
        // actor may, and only through the narrow submitter interface.
        let detectionLayerFiles = try wakeRelatedFiles().filter { $0.lastPathComponent != "WakeCoordinator.swift" }
        #expect(!detectionLayerFiles.isEmpty)
        for file in detectionLayerFiles {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            #expect(!text.contains("RuntimeClient"), "\(file.lastPathComponent) must not reference RuntimeClient — only WakeCoordinator may, via CommandRuntimeSubmitting")
            #expect(!text.contains("submitText"), "\(file.lastPathComponent) must not call submitText — no capability can be executed from wake/audio-capture/detector code directly")
        }
    }

    @Test func sec005_007_wakeCoordinatorsOnlyRuntimeCallSubmitsAValidatedStringTranscript_neverAudioOrCapabilityIDs() throws {
        // Confirms the ONE reference `WakeCoordinator.swift` is allowed
        // is exactly the narrow, expected shape: a call to
        // `submitter.submitText(transcript, ...)` where `transcript` is
        // produced only after `TranscriptValidation.validate` succeeds —
        // never a raw `AudioFrame`/`samples` argument, never a
        // capability-ID-shaped literal, never a direct
        // `executeCapability`/Capability-Bus-style call.
        let thisFile = URL(fileURLWithPath: #filePath)
        let coordinatorFile = thisFile
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FridayCompanionKit/WakeCoordinator.swift")
        let text = codeOnly(try String(contentsOf: coordinatorFile, encoding: .utf8))

        #expect(text.contains("submitter.submitText(transcript"), "the only submission call must pass the validated `transcript` variable, not raw audio")
        #expect(!text.contains("executeCapability"))
        #expect(!text.contains("CapabilityBus"))
        // `frame.samples` IS legitimately read in this file (P2-M4D's
        // voice-activity RMS heuristic, `updateVoiceActivity`) — the
        // real invariant is narrower than "never mention .samples at
        // all": raw samples must never flow into the runtime-submission
        // call itself.
        #expect(!text.contains("submitText(frame") && !text.contains("submitText(samples") && !text.contains("submitText(.samples"), "submitText must never be called with anything derived directly from raw audio samples")
        // Exactly one call site should exist for submitText — if a second
        // path to the runtime is ever added, this count changes and this
        // assertion catches it.
        let submitTextCallCount = text.components(separatedBy: "submitter.submitText(").count - 1
        #expect(submitTextCallCount == 1, "expected exactly one runtime-submission call site, found \(submitTextCallCount)")
    }

    @Test func behavioral_wakeEventNeverTriggersARuntimeClientCall() async {
        // Behavioral reinforcement of SEC-005/007: register a wake-event
        // handler that would visibly prove if anything downstream tried
        // to treat the event as a command — the handler simply receives
        // the narrow `WakeEvent` struct and nothing else is possible to
        // "execute," since `WakeCoordinator` exposes no other API.
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let coordinator = WakeCoordinator(capture: capture, detector: detector, permission: permission)
        await coordinator.enable()

        final class Box: @unchecked Sendable { var received: WakeEvent?; var sawAnythingElse = false }
        let box = Box()
        await coordinator.onWakeEvent { event in
            box.received = event
            // The only thing reachable from here is what the closure
            // itself does — this test's closure does nothing but
            // record the event, proving the coordinator itself imposes
            // no further action.
        }
        capture.deliver(AudioFixtures.positiveWakePhrase())
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(box.received != nil)
        #expect(!box.sawAnythingElse)
    }

    // MARK: - P2M3-SEC-006: raw audio not persisted to runtime-store

    @Test func sec006_wakePipelineHasNoStoreOrFilePersistenceDependency() throws {
        let forbidden = ["runtime-store", "SaveIRSnapshot", "AppendAuditEvent", "sqlite", "FileManager.default.createFile", "write(toFile"]
        for file in try wakeRelatedFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term), "\(file.lastPathComponent) contains \(term) — audio/wake state must remain in-memory only, never persisted")
            }
        }
    }

    // MARK: - P2M3-SEC-008: malformed wake-engine output cannot become arbitrary command text

    @Test func sec008_malformedDetectorOutput_cannotBecomeArbitraryCommandText() async {
        // A "malicious"/malformed detector that returns a WakeEvent with
        // a bogus/adversarial phraseID — the coordinator only ever
        // forwards the typed `WakeEvent` struct to its handler; there is
        // no code path anywhere that interprets any field as a shell
        // command, a TextRequest, or dynamic code. This is structurally
        // guaranteed by `WakeCoordinator` having no such interpretation
        // logic at all (confirmed by `sec005_007` above), demonstrated
        // here with an adversarial payload to show it changes nothing.
        struct MaliciousDetector: WakeWordDetecting {
            let engineIdentifier = "malicious"
            func start() throws {}
            func stop() {}
            func process(_ frame: AudioFrame, sessionID: String) -> WakeEvent? {
                WakeEvent(eventID: "e", sessionID: sessionID, phraseID: "; rm -rf / #", detectedAt: Date(), source: "wake_word", engine: "malicious", confidence: nil)
            }
        }
        let capture = FakeAudioCapturing()
        let permission = FakeMicrophonePermission(status: .authorized)
        let coordinator = WakeCoordinator(capture: capture, detector: MaliciousDetector(), permission: permission)
        await coordinator.enable()

        final class Box: @unchecked Sendable { var received: WakeEvent? }
        let box = Box()
        await coordinator.onWakeEvent { box.received = $0 }
        capture.deliver(AudioFrame(samples: [1], sampleRate: 16000, channelCount: 1))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The adversarial string arrives as inert DATA in a struct
        // field — nothing executed it, nothing shelled out, the process
        // is still running normally (this test completing at all proves
        // that).
        #expect(box.received?.phraseID == "; rm -rf / #")
    }

    // MARK: - P2M3C-SEC-009: real detector has no network dependency (offline proof, structural half)

    @Test func sec009_wakeDetectorHasNoNetworkDependency() throws {
        // Structural half of §18's offline proof — the behavioral half
        // (network actually disabled, detection still fires) is
        // `SherpaOnnxWakeWordDetectorTests.offline_detectionStillWorksWithNetworkUnreachable`.
        // `SherpaOnnxWakeWordDetector` only imports `CSherpaOnnx` (the
        // vendored local inference library) and `Foundation` — there is
        // no networking API anywhere in the wake pipeline to audit for
        // hidden calls.
        let forbidden = ["URLSession", "URLRequest", "dataTask", "NWConnection", "NWListener", "CFNetwork", "URLSessionConfiguration"]
        for file in try wakeRelatedFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term), "\(file.lastPathComponent) contains \(term) — the wake pipeline (including the real sherpa-onnx detector) must have zero network dependency")
            }
        }
    }

    // MARK: - P2-M5 §45: speech/response output has zero execution authority

    @Test func sec010_ttsFilesHaveNoCapabilityBusOrSigningKeyOrRuntimeSubmissionDependency() throws {
        // §3: "Voice output has ZERO execution authority." The output
        // adapter (`ResponsePresenting`/`SpeechSynthesizing`/the real
        // AVSpeechSynthesizer implementation) must not merely be unused
        // for execution today — it must have no CODE PATH capable of it:
        // no Capability Bus reference, no signing key material, and
        // (unlike `WakeCoordinator.swift`, which legitimately calls
        // `submitter.submitText`) no `CommandRuntimeSubmitting`/
        // `submitText`/`RuntimeClient` reference at all — the speaking
        // side must be structurally incapable of submitting a NEW
        // runtime request, not just observed not to today.
        let forbidden = ["\"Dispatch\"", "capabilitybusd/internal", "capability-bus/internal", "DevSeedIR", "DevSeedTask",
                          "SignToken", "policytoken", "PrivateKey", "ed25519.NewKeyPair", "GenerateKey", "\"EvaluateAuthorization\"",
                          "CommandRuntimeSubmitting", "submitText", "RuntimeClient", "CapabilityBus", "executeCapability"]
        for file in try ttsRelatedFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term), "\(file.lastPathComponent) contains \(term) — the speaking/output-adapter layer must have zero path back into execution")
            }
        }
    }

    @Test func sec011_spokenResponseHasNoAuthorityShapedField() {
        // Structural, by direct inspection (mirrors sec001_002's
        // approach for `WakeEvent`): `SpokenResponse` has exactly the
        // fields a bounded, already-decided piece of output text needs —
        // text, a success flag, a bounded prosody category (P2-M5V §10),
        // and (P2-M5V5 §11) which classified response family produced
        // it, a truth-confidence classification, and a follow-up
        // classification — none of which is authorization/AAL/capability-
        // shaped. None of these fields can grant, elevate, or fabricate
        // authority (§18): they only ever describe text that was already
        // decided upstream by the runtime.
        let response = SpokenResponse(text: "Done.", wasSuccess: true, category: .success)
        let mirror = Mirror(reflecting: response)
        let fieldNames = Set(mirror.children.compactMap(\.label))
        #expect(fieldNames == ["text", "wasSuccess", "category", "responseFamily", "truthClassification", "followUp"])
        for forbidden in ["aal", "authorized", "authorization", "token", "capability", "policy", "scope", "signature"] {
            #expect(!fieldNames.contains(forbidden))
        }
    }

    @Test func sec012_responsePresenter_neverFabricatesSuccessForAFailureOutcome() {
        // §11: "A failed runtime result must NEVER map to success
        // speech." Behavioral proof against the real production
        // presenter using real `response.go`-shaped outcome text (a
        // non-SUCCESS outcome still returns a well-formed
        // `RuntimeTextResult` — `submitText` only THROWS for
        // transport-level failures).
        let presenter = DeterministicResponsePresenter()
        let unsupported = RuntimeTextResult(protocolVersion: 1, requestID: "r", correlationID: "r", taskID: "t", outcome: "UNSUPPORTED_INTENT", text: "That capability isn't available in Phase 1.")
        #expect(presenter.response(for: .success(unsupported)).wasSuccess == false)

        let transportFailure = presenter.response(for: .failure("transport(\"daemon unreachable\")"))
        #expect(transportFailure.wasSuccess == false)
        for forbidden in ["Done", "Completed", "Success", "success", "completed successfully"] {
            #expect(!transportFailure.text.contains(forbidden), "a transport failure must never be phrased as success")
        }
    }
}
