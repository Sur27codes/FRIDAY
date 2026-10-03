import Testing
@testable import FridayCompanionKit

/// P2M3 §12/§13: the menu bar must show truthful mic/wake status and
/// must not let the user hammer a denied permission prompt.
@Suite struct WakeStatusFormatterTests {

    @Test func microphoneOff_showsOffAndOffersEnable() {
        let display = WakeStatusFormatter.display(audioState: .microphoneOff, unavailableReason: nil)
        #expect(display.microphoneLine == "Microphone: Off")
        #expect(display.wakeToggleTitle.contains("Enable"))
        #expect(display.wakeToggleEnabled)
    }

    @Test func wakeOnly_showsWakeListening_offersDisable() {
        let display = WakeStatusFormatter.display(audioState: .wakeOnly, unavailableReason: nil)
        #expect(display.microphoneLine.contains("Wake Listening"))
        #expect(display.wakeToggleTitle.contains("Disable"))
    }

    @Test func listening_showsInteractionListening_notGenericWakeLabel() {
        let display = WakeStatusFormatter.display(audioState: .listening(sessionID: "s"), unavailableReason: nil)
        #expect(display.microphoneLine.contains("Listening"))
        #expect(!display.microphoneLine.contains("Wake Listening"), "an active interaction session must render distinctly from idle wake-only")
    }

    @Test func permissionDenied_disablesToggle_toAvoidHammeringThePrompt() {
        let display = WakeStatusFormatter.display(audioState: .unavailable, unavailableReason: .microphonePermissionDenied)
        #expect(display.microphoneLine.contains("permission denied"))
        #expect(!display.wakeToggleEnabled, "must not offer to retry a denied OS permission repeatedly")
    }

    @Test func permissionRestricted_disablesToggle() {
        let display = WakeStatusFormatter.display(audioState: .unavailable, unavailableReason: .microphonePermissionRestricted)
        #expect(!display.wakeToggleEnabled)
    }

    @Test func deviceError_keepsToggleEnabled_forRetry() {
        let display = WakeStatusFormatter.display(audioState: .unavailable, unavailableReason: .deviceError("no input"))
        #expect(display.microphoneLine.contains("device error"))
        #expect(display.wakeToggleEnabled, "a transient device error should remain retryable, unlike a denied OS permission")
    }

    /// P2-M3D §10 — a detector that failed to construct (real
    /// `SherpaOnnxWakeWordDetector` unavailable, `AppDelegate` fell back
    /// to `NullWakeWordDetector`) must never render as truthfully
    /// "listening" — this is the exact UI-truthfulness regression the
    /// owner's real hardware test exposed.
    @Test func detectorFailedToStart_neverShowsAsWakeListening_showsTruthfulUnavailableReason() {
        let display = WakeStatusFormatter.display(audioState: .unavailable, unavailableReason: .detectorFailedToStart("sherpa-onnx model resource missing"))
        #expect(!display.microphoneLine.contains("Wake Listening"), "a non-functional fallback detector must never present as operational")
        #expect(display.microphoneLine.contains("wake engine unavailable"))
        #expect(display.microphoneLine.contains("sherpa-onnx model resource missing"), "the actual reason must be visible, not swallowed")
    }

    @Test func neverExposesRawAudioOrWaveformContent() {
        // Structural: the formatter's only inputs are `AudioState`/
        // `WakeUnavailableReason` — neither type can carry a sample
        // array or waveform, so there is no code path through which
        // this formatter could ever render audio content.
        for state: AudioState in [.microphoneOff, .wakeOnly, .listening(sessionID: "s"), .processing, .speaking, .unavailable, .awaitingFollowUp(sessionID: "s")] {
            let display = WakeStatusFormatter.display(audioState: state, unavailableReason: nil)
            #expect(!display.microphoneLine.contains("sample"))
            #expect(!display.microphoneLine.contains("waveform"))
        }
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.8 §16: truthful follow-up state
    //
    // NOTE ON TEST EXECUTION: see the identical disclosure in
    // `WakeCoordinatorEngineTests.swift` — this environment's corrupted
    // `_Testing_Foundation.framework` blocks `swift test` from compiling
    // this file at all. Written and manually traced, not executed.

    @Test func awaitingFollowUp_showsFollowUpListening_neverWakeListening() {
        let display = WakeStatusFormatter.display(audioState: .awaitingFollowUp(sessionID: "s"), unavailableReason: nil)
        #expect(display.microphoneLine == "Microphone: Follow-up Listening")
        #expect(!display.microphoneLine.contains("Wake Listening"), "active STT capturing a follow-up must never present as merely passive wake listening")
    }

    @Test func awaitingFollowUp_isDistinctFromCommandListening() {
        let followUp = WakeStatusFormatter.display(audioState: .awaitingFollowUp(sessionID: "s"), unavailableReason: nil)
        let command = WakeStatusFormatter.display(audioState: .listening(sessionID: "s"), unavailableReason: nil)
        #expect(followUp.microphoneLine != command.microphoneLine, "a follow-up turn must not falsely present as having begun with a fresh \"Hey Friday\"")
    }
}
