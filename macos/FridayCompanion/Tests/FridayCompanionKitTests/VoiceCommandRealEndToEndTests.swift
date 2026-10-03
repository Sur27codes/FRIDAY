import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M4 §22/§23 — the required real-process proof that a spoken command
/// actually executes through the EXISTING, unmodified P2-M2 pipeline:
/// real `RuntimeClient`, real `friday-daemon`, real `policyengined`,
/// real `capabilitybusd`, real workspace, real capability execution.
/// Reuses `RuntimeClientIntegrationTests`' own daemon-spinup pattern
/// exactly (`GoBinaryBuilder`, the same `.serialized` real-process
/// discipline) rather than inventing a second one.
///
/// **Disclosed scope boundary (read before trusting these results):**
/// this coding environment discovered a real, reproducible constraint —
/// `SFSpeechRecognizer.requestAuthorization` crashes the calling process
/// with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` when invoked from a
/// bare, non-`.app`-bundled SwiftPM binary (confirmed even with a
/// properly embedded `Info.plist` and an ad-hoc code signature — see
/// `docs/E-traceability-matrix.md`'s P2-M4 section for the full
/// evidence). Speech-Recognition authorization is therefore stuck at
/// `.notDetermined` here and cannot be exercised live. These tests
/// prove the REAL, security-critical half of the pipeline for real
/// (`transcript → RuntimeClient → real daemon → existing runtime →
/// existing policy/capability path → actual result`) using a
/// deterministic stand-in for "what live STT would have produced" in
/// place of the literal `audio fixture → SFSpeechRecognizer` leg — that
/// one specific leg is proven separately via
/// `AppleSpeechTranscriberConversionTests` (the real, unit-testable
/// audio-conversion boundary) and is otherwise owner-hardware-verified,
/// exactly like P2-M3's original real-microphone gap.
@Suite(.serialized)
final class VoiceCommandRealEndToEndTests {
    let repoRoot: URL
    let buildDir: URL
    let config: CompanionConfiguration
    let supervisor: Supervisor
    let client: RuntimeClient

    init() async throws {
        repoRoot = GoBinaryBuilder.repoRoot()
        buildDir = URL(fileURLWithPath: "/tmp/fc-voice-\(Int.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let policyBinary = buildDir.appendingPathComponent("policyengined")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/policy-engine"),
                                  packagePath: "./cmd/policyengined", output: policyBinary)
        let busBinary = buildDir.appendingPathComponent("capabilitybusd")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/capability-bus"),
                                  packagePath: "./cmd/capabilitybusd", output: busBinary)
        let daemonBinary = buildDir.appendingPathComponent("friday-daemon")
        try GoBinaryBuilder.build(moduleDir: repoRoot.appendingPathComponent("services/runtime"),
                                  packagePath: "./cmd/friday-daemon", output: daemonBinary)

        config = CompanionConfiguration(
            runtimeDirectory: buildDir, policyEngineBinary: policyBinary, capabilityBusBinary: busBinary,
            workspaceRoot: buildDir.appendingPathComponent("workspace", isDirectory: true)
        )
        try prepareRuntimeDirectories(config)

        supervisor = Supervisor(services: makeP2M2ServiceConfigs(config, daemonBinary: daemonBinary))
        await supervisor.startAll()
        guard await supervisor.overall == .ready else {
            Issue.record("setup: expected all three real services to reach .ready, got \(await supervisor.snapshot())")
            client = RuntimeClient(socketPath: config.daemonSocketPath)
            return
        }
        client = RuntimeClient(socketPath: config.daemonSocketPath)
    }

    deinit {
        // Same blocking-drain pattern as `RuntimeClientIntegrationTests`
        // — see that file's own deinit comment for the P2-M2-era
        // debugging history behind why this must block, not fire-and-forget.
        let sup = supervisor
        let dir = buildDir
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await sup.stopAll()
            try? FileManager.default.removeItem(at: dir)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    // MARK: - §22: "check system status" via the voice path

    @Test func systemGetStatus_voiceEndToEnd_realDaemon_realRuntime() async throws {
        // Drive the real coordinator cycle (proves wake → command
        // capture → transcript → RuntimeClient wiring is real and
        // correct), then separately confirm the exact same text, sent
        // the exact same way a real transcript would be, produces the
        // exact real success `RuntimeClientIntegrationTests` already
        // proved for typed input — demonstrating the required
        // typed/spoken equivalence (§13).
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        // P2-M5 §37: the automated end-to-end target — real runtime
        // result -> safe response formatter -> production TTS interface
        // (a fake stand-in for the audio hardware itself, but the exact
        // real `DeterministicResponsePresenter` production code path).
        let synthesizer = FakeSpeechSynthesizer()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: client,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.1))
        )

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        for _ in 0..<50 where !transcriber.isSessionActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(transcriber.isSessionActive)
        transcriber.simulateResult(.finalized("check system status"))

        for _ in 0..<300 where await coordinator.state != .wakeOnly {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await coordinator.state == .wakeOnly, "the real runtime round trip must complete and return to wake-only")
        // P2-M5V3 §8: the real daemon assigns its own real taskID, so
        // which deterministic variant gets selected isn't predictable
        // from the test's side — check membership in the known set
        // (natural, refined wording, P2-M5V §6) rather than exact text.
        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(synthesizer.spokenTexts[0]), "the real daemon's own Response Validation Gate outcome must reach the synthesizer as one of the known, refined variants — got '\(synthesizer.spokenTexts[0])'")

        // Independent confirmation via a second, direct real call with
        // the identical text — proves the daemon/runtime actually
        // treats this text as a successful system.get_status request
        // (mirrors `RuntimeClientIntegrationTests.getStatus_realEndToEnd_throughSwiftDaemonBoundary`,
        // now reached via the voice-shaped path above rather than only
        // typed input).
        let direct = try client.submitText("check system status", requestID: "voice-status-1", correlationID: "voice-corr-status-1")
        #expect(direct.outcome == "SUCCESS")
        #expect(direct.text.lowercased().contains("status"))
    }

    // MARK: - P2-M4R: two SEPARATE real voice interactions with identical text must both succeed

    /// Reproduces, through the REAL production `WakeCoordinator` (not a
    /// direct `RuntimeClient` call), the exact real owner bug: saying
    /// "Hey Friday" / "check system status" twice, as two genuinely
    /// separate interactions, must produce two independent SUCCESS
    /// outcomes against the real daemon — never the second one
    /// misclassified as DUPLICATE_REQUEST. Before the P2-M4R fix,
    /// `WakeCoordinator.beginProcessing` hardcoded `correlationID: ""`,
    /// which collapsed the server-side idempotency key for this
    /// zero-argument capability into a single constant — see
    /// `docs/E-traceability-matrix.md`'s P2-M4R section for the full
    /// mechanism a real owner voice interaction surfaced.
    @Test func sameCommandSpokenTwiceAsSeparateInteractions_bothSucceed_realDaemon_realCoordinator() async throws {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let diagnostics = WakeDiagnosticsRecorder()
        // P2-M5 §36: prove adding TTS to this exact pre-existing P2-M4R
        // regression did NOT change correlation_id/idempotency behavior
        // — both real interactions below must still independently
        // succeed AND both must independently produce real, truthful
        // spoken confirmations (never a stale/carried-over one).
        let synthesizer = FakeSpeechSynthesizer()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: client,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.1)),
            diagnostics: diagnostics
        )

        var observedOutcomes: [String] = []
        await coordinator.enable() // starts real capture — must happen once, before the first wake trigger

        for attempt in 1...2 {
            // A fresh, later-than-cooldown timestamp for each attempt's
            // wake trigger — otherwise the SECOND wake within
            // `cooldown` (0.1s) of the first is correctly debounced by
            // design (§20), which would make this test's own timing a
            // false negative, not a real product bug.
            capture.deliver(AudioFixtures.positiveWakePhrase(at: Date().addingTimeInterval(Double(attempt) * 2)))
            for _ in 0..<200 where !transcriber.isSessionActive {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(transcriber.isSessionActive, "attempt \(attempt): expected command capture to start")
            transcriber.simulateResult(.finalized("check system status"))

            for _ in 0..<300 where await coordinator.state != .wakeOnly {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(await coordinator.state == .wakeOnly, "attempt \(attempt): expected the real runtime round trip to complete and return to wake-only")

            // Read the ACTUAL outcome of THIS specific interaction's own
            // internal `submitText` call via diagnostics — `.wakeOnly` is
            // reached on both success AND failure (P2-M4D), so state
            // alone cannot distinguish them; `lastRuntimeOutcome` is the
            // real, un-derived signal.
            let outcome = diagnostics.snapshot().lastRuntimeOutcome ?? "(none)"
            observedOutcomes.append(outcome)
        }

        #expect(observedOutcomes == ["SUCCESS", "SUCCESS"], "both separate voice interactions with identical text must succeed independently — got \(observedOutcomes)")
        #expect(synthesizer.spokenTexts.count == 2, "TTS must speak a real confirmation for EACH independent interaction — never zero, never a stale one reused")
        #expect(synthesizer.spokenTexts.allSatisfy { DeterministicResponsePresenter.getStatusSuccessVariants.contains($0) }, "each spoken confirmation must be one of the known, refined variants — got \(synthesizer.spokenTexts)")
    }

    // MARK: - §22: create-note via the voice path (using the grammar the existing Intent Compiler actually accepts)

    @Test func workspaceCreateNote_voiceEndToEnd_realDaemon_noteActuallyExists_noDirectCapabilityPath() async throws {
        // Disclosed, not hidden: the P2-M4 instruction's own example
        // phrasing ("create a note saying X") does NOT match Phase-1's
        // existing deterministic grammar
        // (`services/cognitive-core/intentcompiler/grammar.go`:
        // `(?:create|make) a note (?:called|named) (.+?) (?:with|containing) (.+)`
        // — no "saying" form exists). §13 requires reusing the EXISTING
        // runtime interpretation, not extending it to accept new
        // phrasing "to make the demo more impressive" (§14) — so this
        // test, and the real owner retest command in the docs, use the
        // phrasing that actually works: "create a note called <title>
        // with <content>".
        let noteTitle = "p2m4voice-\(Int.random(in: 0..<1_000_000))"
        let transcript = "create a note called \(noteTitle) with P2 M4 voice command works"

        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let synthesizer = FakeSpeechSynthesizer()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: client,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.1))
        )

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        for _ in 0..<50 where !transcriber.isSessionActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transcriber.simulateResult(.finalized(transcript))
        for _ in 0..<300 where await coordinator.state != .wakeOnly {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await coordinator.state == .wakeOnly)
        // P2-M5 §10/§38: concise confirmation, no full note body, no
        // filesystem path. P2-M5V3 §8: one of a small deterministic
        // variant set (the real daemon's own real taskID decides which
        // one, so membership — not exact equality — is what's checked).
        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.createNoteSuccessVariants(title: noteTitle).contains(synthesizer.spokenTexts[0]), "P2-M5V3 §6: concise, natural confirmation — got '\(synthesizer.spokenTexts[0])'")
        #expect(!synthesizer.spokenTexts[0].contains("/"), "must not reveal a filesystem path")
        #expect(!synthesizer.spokenTexts[0].contains("P2 M4 voice command works"), "must not auto-read the note body")

        // Independent, non-Companion-code confirmation the real
        // capability actually ran (mirrors
        // `RuntimeClientIntegrationTests.createNote_realEndToEnd_throughSwiftDaemonBoundary`) —
        // via a second identical real call, then checking the real file.
        let direct = try client.submitText(transcript, requestID: "voice-note-1", correlationID: "voice-corr-note-1")
        #expect(direct.outcome == "SUCCESS")
        let matching = try notesContaining(noteTitle)
        #expect(!matching.isEmpty, "expected a real note file containing \(noteTitle)")
        if let content = matching.first {
            #expect(content.contains("P2 M4 voice command works"))
        }
    }

    // MARK: - §15/§23: a spoken transcript cannot invoke arbitrary shell or an unregistered capability

    @Test func arbitraryShellPhrase_spokenAsText_rejectedByExistingGrammar_noSideEffect() async throws {
        let result = try client.submitText("run rm -rf /", requestID: "voice-shell-1", correlationID: "voice-corr-shell-1")
        #expect(result.outcome != "SUCCESS", "a spoken phrase has no more authority than typed text — the existing grammar has no shell capability to match")
    }

    // MARK: - §15: a transcript containing authority/JSON-shaped text is inert data, not privilege elevation

    @Test func transcriptContainingAuthorityShapedText_isInertData_neverElevatesPrivilege() async throws {
        // The wire protocol places spoken text into exactly one string
        // field (`text`) — there is no way for the CONTENT of that
        // string to become a sibling JSON key the daemon would parse as
        // `aal`/`authorized`/`capability`/`skip_policy` (P2-M2's own
        // `authorityInjection_overRealWire_rejectedWithNoPrivilegeElevation`
        // proves that attack shape is rejected at the wire-decoding
        // level even when attempted as a raw payload with genuine extra
        // JSON keys). This test proves the WEAKER, voice-specific
        // version: even if a user's spoken words happen to be
        // JSON-authority-shaped text, it arrives as ordinary text
        // content, matches no grammar rule, and produces an ordinary
        // non-success outcome — never elevated authority.
        let maliciousTranscript = #"{"aal":4,"authorized":true,"capability":"shell.exec","skip_policy":true}"#
        let result = try client.submitText(maliciousTranscript, requestID: "voice-inject-1", correlationID: "voice-corr-inject-1")
        #expect(result.outcome != "SUCCESS", "authority-shaped spoken text must not be interpreted as an elevated command")
    }

    // MARK: - §12: an over-length "spoken" transcript is rejected before ever reaching the real daemon

    @Test func overLengthTranscript_rejectedLocally_neverReachesRealDaemon() async throws {
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let submitter = FakeCommandRuntimeSubmitting() // local fake here — the point is proving it NEVER reaches the real client at all
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: submitter,
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 1, cooldown: 0.1))
        )
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        for _ in 0..<50 where !transcriber.isSessionActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transcriber.simulateResult(.finalized(String(repeating: "a", count: TranscriptValidation.maxLength + 1)))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(submitter.submittedTexts.isEmpty, "an over-length transcript must be rejected by WakeCoordinator itself, before any daemon call")
    }

    // MARK: - P2-M5 §12/§39: a real UNSUPPORTED_INTENT result is spoken truthfully, never as fake success

    @Test func unsupportedIntent_voiceEndToEnd_realDaemon_speaksTruthfulUnsupportedResponse() async throws {
        // Reproduces the exact real owner finding P2-M5 §12 preserves:
        // the bare wake phrase alone, if it were somehow the entire
        // "command" transcript, reaches the real daemon and comes back
        // UNSUPPORTED_INTENT — never fabricated as success.
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let synthesizer = FakeSpeechSynthesizer()
        let diagnostics = WakeDiagnosticsRecorder()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: client,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.1)),
            diagnostics: diagnostics
        )

        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        for _ in 0..<50 where !transcriber.isSessionActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transcriber.simulateResult(.finalized("hey friday"))
        for _ in 0..<300 where await coordinator.state != .wakeOnly {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await coordinator.state == .wakeOnly)
        #expect(diagnostics.snapshot().lastRuntimeOutcome == "UNSUPPORTED_INTENT", "the real daemon must genuinely classify this as unsupported, not a test-only assumption")
        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.unsupportedIntentVariants.contains(synthesizer.spokenTexts[0]), "got '\(synthesizer.spokenTexts[0])'")
        for forbidden in ["Done", "Completed", "Success"] {
            #expect(!synthesizer.spokenTexts[0].contains(forbidden))
        }
    }

    // MARK: - P2-M5 §19/§22/§40: real barge-in through the real daemon — two independent interactions

    @Test func bargeIn_voiceEndToEnd_realDaemon_secondInteractionIndependentlySucceeds_noStaleData() async throws {
        // The exact owner-acceptance script in §40, driven through the
        // real daemon/policy/capability-bus/runtime stack (not fakes):
        // "check system status" -> FRIDAY begins speaking -> genuine
        // barge-in wake -> "check system status" again -> a SECOND,
        // fully independent SUCCESS and spoken confirmation. Also the
        // strongest form of the P2-M4R regression: the same text,
        // reaching the real idempotency-keyed daemon twice, where the
        // second interaction's correlation_id is minted via the
        // barge-in path specifically rather than a normal
        // return-to-wakeOnly-then-rewake cycle.
        let capture = FakeAudioCapturing()
        let detector = FakeWakeWordDetector()
        let permission = FakeMicrophonePermission(status: .authorized)
        let transcriber = FakeSpeechTranscriber()
        let synthesizer = FakeSpeechSynthesizer()
        synthesizer.autoFinish = false // hold response A "in flight" so a real barge-in has something audible to interrupt
        let diagnostics = WakeDiagnosticsRecorder()
        let coordinator = WakeCoordinator(
            capture: capture, detector: detector, permission: permission,
            transcriber: transcriber, runtimeSubmitter: client,
            synthesizer: synthesizer, responsePresenter: DeterministicResponsePresenter(),
            engine: WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 5, cooldown: 0.1)),
            diagnostics: diagnostics
        )
        var wakeEvents: [WakeEvent] = []
        await coordinator.onWakeEvent { wakeEvents.append($0) }

        // --- Interaction A ---
        await coordinator.enable()
        capture.deliver(AudioFixtures.positiveWakePhrase())
        for _ in 0..<50 where !transcriber.isSessionActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transcriber.simulateResult(.finalized("check system status"))
        for _ in 0..<300 where await coordinator.state != .speaking {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await coordinator.state == .speaking, "response A must actually be in the speaking state before the barge-in")
        #expect(diagnostics.snapshot().lastRuntimeOutcome == "SUCCESS")
        #expect(synthesizer.spokenTexts.count == 1)
        #expect(DeterministicResponsePresenter.getStatusSuccessVariants.contains(synthesizer.spokenTexts[0]))

        // --- Genuine barge-in ---
        capture.deliver(AudioFixtures.positiveWakePhrase(at: Date().addingTimeInterval(5)))
        for _ in 0..<100 where !transcriber.isSessionActive || wakeEvents.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(wakeEvents.count == 2, "the barge-in must produce a genuine second WakeEvent")
        #expect(synthesizer.stopCallCount >= 1, "response A's audio must actually be stopped, not merely superseded in state")
        guard case .listening = await coordinator.state else {
            Issue.record("expected fresh command capture immediately after barge-in, got \(await coordinator.state)")
            return
        }

        // --- Interaction B: the identical text, submitted as a
        // genuinely new interaction via the barge-in path --- response B
        // is allowed to complete naturally this time (only response A
        // needed to be held "in flight" for the barge-in itself).
        synthesizer.autoFinish = true
        transcriber.simulateResult(.finalized("check system status"))
        for _ in 0..<300 where await coordinator.state != .wakeOnly {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await coordinator.state == .wakeOnly, "interaction B must independently complete and return to wake-only")
        #expect(diagnostics.snapshot().lastRuntimeOutcome == "SUCCESS", "interaction B must succeed independently against the real daemon — never DUPLICATE_REQUEST (the exact P2-M4R bug, now proven not to regress across a barge-in specifically)")
        #expect(synthesizer.spokenTexts.count == 2, "exactly two spoken responses — response A (interrupted) and response B (completed) — never a merged/stale/duplicated one")
        #expect(synthesizer.spokenTexts.allSatisfy { DeterministicResponsePresenter.getStatusSuccessVariants.contains($0) }, "got \(synthesizer.spokenTexts)")
    }

    private func notesContaining(_ substring: String) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot.path)
        return files.compactMap { filename in
            guard let content = try? String(contentsOfFile: config.workspaceRoot.appendingPathComponent(filename).path, encoding: .utf8) else {
                return nil
            }
            return content.contains(substring) ? content : nil
        }
    }
}
