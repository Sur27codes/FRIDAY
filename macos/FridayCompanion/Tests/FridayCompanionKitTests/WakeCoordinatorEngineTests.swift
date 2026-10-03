import Testing
@testable import FridayCompanionKit
import Foundation

/// Pure state-machine tests — no real audio, no real time elapses.
/// Covers the P2M3-WAKE-* functional test IDs at the engine level;
/// `WakeCoordinatorTests` covers the same IDs end-to-end through the
/// actor driver with fake capture/detector/permission.
@Suite struct WakeCoordinatorEngineTests {

    // MARK: - P2M3-WAKE-001 / 002 / 003: wake / silence / ordinary speech

    @Test func wake001_wakeDetectedWhileWakeOnly_transitionsToListening_emitsEvent() {
        let engine = WakeCoordinatorEngine(now: { Date() }, makeID: { "fixed-id" })
        let state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)
        let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: 0.9, engine: "fake", at: Date()))
        #expect(next.audioState == .listening(sessionID: "fixed-id"))
        if case .emitWakeEvent(let event) = action {
            #expect(event.phraseID == "hey_friday")
        } else {
            Issue.record("expected .emitWakeEvent, got \(action)")
        }
    }

    @Test func wake002_003_wakeIgnored_whenNotInWakeOnlyState() {
        // `.speaking` is deliberately EXCLUDED from this list as of
        // P2-M5 — a genuine wake word during active speech is the
        // barge-in contract (§19/§20), covered separately below by
        // `wake013_bargeIn_wakeDuringSpeaking_transitionsToListening`.
        let engine = WakeCoordinatorEngine()
        for offState: AudioState in [.microphoneOff, .unavailable, .listening(sessionID: "s"), .processing] {
            let state = WakeCoordinatorRuntimeState(audioState: offState)
            let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: Date()))
            #expect(next.audioState == offState, "state \(offState) must not transition on a wake event")
            #expect(action == .none)
        }
    }

    // MARK: - P2-M5 §19/§20: wake-word barge-in from `.speaking`

    @Test func wake013_bargeIn_wakeDuringSpeaking_transitionsToListening_emitsEvent() {
        let engine = WakeCoordinatorEngine(now: { Date() }, makeID: { "barge-session" })
        let state = WakeCoordinatorRuntimeState(audioState: .speaking)
        let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: 0.95, engine: "fake", at: Date()))
        #expect(next.audioState == .listening(sessionID: "barge-session"), "a genuine wake word during active speech must start a fresh interaction (barge-in)")
        if case .emitWakeEvent(let event) = action {
            #expect(event.phraseID == "hey_friday")
        } else {
            Issue.record("expected .emitWakeEvent for a barge-in wake, got \(action)")
        }
    }

    @Test func wake013_bargeIn_stillRespectsCooldown() {
        let base = Date()
        let engine = WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 8, cooldown: 2), now: { base })
        let state = WakeCoordinatorRuntimeState(audioState: .speaking, lastWakeAt: base)
        let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: base.addingTimeInterval(0.5)))
        #expect(action == .none, "a barge-in attempt within the cooldown window is still debounced, same as from .wakeOnly")
        #expect(next.audioState == .speaking)
    }

    // MARK: - P2M3-WAKE-004: debounce/cooldown

    @Test func wake004_repeatedWakeWithinCooldown_isDebounced() {
        let base = Date()
        let engine = WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 8, cooldown: 2), now: { base })
        var state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)

        let (afterFirst, firstAction) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: base))
        guard case .emitWakeEvent = firstAction else { Issue.record("expected first wake to fire"); return }
        state = afterFirst

        // Immediately return to wakeOnly (simulating a fast timeout) and
        // fire again within the cooldown window.
        state.audioState = .wakeOnly
        let (afterSecond, secondAction) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: base.addingTimeInterval(0.5)))
        #expect(secondAction == .none, "a second wake within the cooldown window must be debounced")
        #expect(afterSecond.audioState == .wakeOnly)
    }

    @Test func wake004_wakeAfterCooldownElapses_isNotDebounced() {
        let base = Date()
        let engine = WakeCoordinatorEngine(config: WakeSessionConfig(listeningTimeout: 8, cooldown: 2), now: { base })
        var state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)
        let (afterFirst, _) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: base))
        state = afterFirst
        state.audioState = .wakeOnly

        let (_, secondAction) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: base.addingTimeInterval(3)))
        guard case .emitWakeEvent = secondAction else {
            Issue.record("expected a wake after the cooldown window to fire normally, got \(secondAction)")
            return
        }
    }

    // MARK: - P2M3-WAKE-005 / 006: wake disabled / re-enabled

    @Test func wake005_disableRequested_stopsCapture_returnsToMicOff() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .wakeOnly, wakeEnabled: true)
        let (next, action) = engine.transition(state: state, event: .disableRequested)
        #expect(next.audioState == .microphoneOff)
        #expect(!next.wakeEnabled)
        #expect(action == .stopCapture)
    }

    @Test func wake006_enableRequested_fromMicOff_startsCapture() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .microphoneOff, wakeEnabled: false)
        let (next, action) = engine.transition(state: state, event: .enableRequested)
        #expect(next.audioState == .wakeOnly)
        #expect(next.wakeEnabled)
        #expect(action == .startCapture)
    }

    // MARK: - P2M3-WAKE-007 / 008: session creation + timeout

    @Test func wake007_wakeEvent_createsSessionID_matchingListeningState() {
        let engine = WakeCoordinatorEngine(makeID: { "session-abc" })
        let state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)
        let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: Date()))
        #expect(next.audioState == .listening(sessionID: "session-abc"))
        if case .emitWakeEvent(let event) = action {
            #expect(event.sessionID == "session-abc")
        }
    }

    @Test func wake008_listeningTimeout_returnsToWakeOnly() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "s1"))
        let (next, action) = engine.transition(state: state, event: .listeningTimedOut)
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func listeningTimeout_whileNotListening_isANoOp() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)
        let (next, _) = engine.transition(state: state, event: .listeningTimedOut)
        #expect(next.audioState == .wakeOnly, "a stale timeout firing after the session already ended must not regress state")
    }

    // MARK: - P2M3-WAKE-009 / 010: device unavailable / recovery

    @Test func wake009_deviceUnavailable_fromAnyActiveState_becomesUnavailable() {
        let engine = WakeCoordinatorEngine()
        for activeState: AudioState in [.wakeOnly, .listening(sessionID: "s")] {
            let state = WakeCoordinatorRuntimeState(audioState: activeState, wakeEnabled: true)
            let (next, action) = engine.transition(state: state, event: .deviceUnavailable)
            #expect(next.audioState == .unavailable)
            #expect(action == .stopCapture)
        }
    }

    @Test func wake010_deviceRecovered_resumesWakeOnly_onlyIfWakeWasEnabled() {
        let engine = WakeCoordinatorEngine()
        let enabledState = WakeCoordinatorRuntimeState(audioState: .unavailable, wakeEnabled: true)
        let (next1, action1) = engine.transition(state: enabledState, event: .deviceRecovered)
        #expect(next1.audioState == .wakeOnly)
        #expect(action1 == .startCapture)

        let disabledState = WakeCoordinatorRuntimeState(audioState: .unavailable, wakeEnabled: false)
        let (next2, action2) = engine.transition(state: disabledState, event: .deviceRecovered)
        #expect(next2.audioState == .microphoneOff)
        #expect(action2 == .none)
    }

    // MARK: - P2M3-WAKE-011: sleep/wake lifecycle reinitializes safely

    @Test func wake011_unavailableThenRecovered_isASafeRoundTrip() {
        let engine = WakeCoordinatorEngine()
        var state = WakeCoordinatorRuntimeState(audioState: .wakeOnly, wakeEnabled: true)
        (state, _) = engine.transition(state: state, event: .deviceUnavailable)
        #expect(state.audioState == .unavailable)
        (state, _) = engine.transition(state: state, event: .deviceRecovered)
        #expect(state.audioState == .wakeOnly, "simulated sleep (unavailable) then wake (recovered) must safely resume wake-only")
    }

    // MARK: - P2M3-WAKE-012: offline does not disable local wake

    @Test func wake012_engineHasNoNetworkConcept_offlineIsNotAWakeEventAtAll() {
        // Structural: `WakeCoordinatorEngine.transition` has no network/
        // connectivity input anywhere in its signature — offline status
        // cannot possibly influence this state machine, which is itself
        // the property under test (local wake is unaffected by
        // connectivity because connectivity was never wired to it).
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .wakeOnly)
        let (next, action) = engine.transition(state: state, event: .rawWakeDetected(phraseID: "hey_friday", confidence: nil, engine: "fake", at: Date()))
        #expect(next.audioState != .wakeOnly) // still transitions to listening exactly as if online
        #expect(action != .none)
    }

    // MARK: - P2-PROD-BOOTSTRAP-R2.8: continuous follow-up conversation session
    //
    // NOTE ON TEST EXECUTION: this environment's Command Line Tools
    // installation ships a corrupted `_Testing_Foundation.framework`
    // (its `Modules/` directory, containing the `.swiftmodule`, is
    // entirely missing from the bundle on disk — confirmed via direct
    // `swiftc` probing down to the missing files, not a cache artifact,
    // not fixable by build flags), which blocks `swift test` from
    // compiling ANY file in this target, including this one. These
    // tests were written and manually traced against
    // `WakeCoordinatorEngine.transition`'s actual logic but could not be
    // executed in this environment — disclosed, not silently assumed
    // passing (P2-PROD-BOOTSTRAP-R2.7's own final report already
    // disclosed this exact same pre-existing, unrelated blocker).

    @Test func r28_naturalSpeechCompletion_opensFollowUpWindow_notWakeOnly() {
        let engine = WakeCoordinatorEngine(makeID: { "follow-up-1" })
        let state = WakeCoordinatorRuntimeState(audioState: .speaking)
        let (next, action) = engine.transition(state: state, event: .speechFinished)
        #expect(next.audioState == .awaitingFollowUp(sessionID: "follow-up-1"))
        #expect(action == .beginFollowUpCapture)
    }

    @Test func r28_bargeInDuringPlayback_supersedesFollowUpWindow_staleFinishedIgnored() {
        // Mirrors the existing barge-in contract this file already
        // relies on: `handleSpeakingFrame` moves state to `.listening`
        // SYNCHRONOUSLY before the old utterance's stale `.speechFinished`
        // can arrive — by the time it does, state is no longer
        // `.speaking`, so the `.speechFinished` guard must reject it
        // (never opening a follow-up window on top of an already-fresh
        // capture).
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "fresh-after-bargein"))
        let (next, action) = engine.transition(state: state, event: .speechFinished)
        #expect(next.audioState == .listening(sessionID: "fresh-after-bargein"), "a stale .speechFinished after a barge-in already re-entered .listening must not regress state")
        #expect(action == .none)
    }

    @Test func r28_followUpTranscriptFinalized_beginsProcessing_sameAsFreshWake() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .awaitingFollowUp(sessionID: "s2"))
        let (next, action) = engine.transition(state: state, event: .commandUtteranceFinalized(transcript: "how is that different from deep learning"))
        #expect(next.audioState == .processing)
        if case .beginProcessing(let transcript) = action {
            #expect(transcript == "how is that different from deep learning")
        } else {
            Issue.record("expected .beginProcessing action")
        }
    }

    @Test func r28_threeConsecutiveFollowUpTurns_allWorkWithoutWakeWord() {
        // PART 9's exact required shape, at the pure state-machine level:
        // .speaking -> .awaitingFollowUp -> (finalize) -> .processing ->
        // (responseReady) -> .speaking -> .awaitingFollowUp, three times,
        // with `.rawWakeDetected` never appearing anywhere in this loop.
        var ids = ["turn1", "turn2", "turn3"].makeIterator()
        let engine = WakeCoordinatorEngine(makeID: { ids.next() ?? "extra" })
        var state = WakeCoordinatorRuntimeState(audioState: .speaking)
        for turnNumber in 1...3 {
            var action: WakeCoordinatorAction
            (state, action) = engine.transition(state: state, event: .speechFinished)
            guard case .awaitingFollowUp = state.audioState else {
                Issue.record("turn \(turnNumber): expected .awaitingFollowUp after .speechFinished")
                return
            }
            #expect(action == .beginFollowUpCapture)
            (state, action) = engine.transition(state: state, event: .commandUtteranceFinalized(transcript: "follow-up question \(turnNumber)"))
            #expect(state.audioState == .processing)
            (state, action) = engine.transition(state: state, event: .responseReady(text: "answer \(turnNumber)"))
            #expect(state.audioState == .speaking)
            #expect(action == .beginSpeaking(text: "answer \(turnNumber)"))
        }
    }

    @Test func r28_followUpInactivityTimeout_closesSession_returnsToWakeOnly() {
        // The follow-up "no speech yet" backstop reuses the existing,
        // previously-dormant `.listeningTimedOut` event — its actor-level
        // caller differs (`scheduleFollowUpInactivityTimeout`, an 8s
        // speech-aware window, vs. the unconditional 12s absolute
        // backstop), but the PURE transition is identical and already
        // covered structurally by `wake008_listeningTimeout_returnsToWakeOnly`.
        // This test just confirms it also fires from `.awaitingFollowUp`,
        // not only `.listening`.
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .awaitingFollowUp(sessionID: "silent"))
        let (next, action) = engine.transition(state: state, event: .listeningTimedOut)
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func r28_explicitSessionEndPhrase_closesFollowUpSession() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .awaitingFollowUp(sessionID: "s3"))
        let (next, action) = engine.transition(state: state, event: .followUpSessionExplicitlyEnded)
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func r28_explicitSessionEndPhrase_outsideFollowUp_isANoOp() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .listening(sessionID: "fresh"))
        let (next, _) = engine.transition(state: state, event: .followUpSessionExplicitlyEnded)
        #expect(next.audioState == .listening(sessionID: "fresh"), "a stray followUpSessionExplicitlyEnded outside an actual follow-up window must not regress a fresh command capture")
    }

    @Test func r28_followUpTranscriptionFailed_closesSession_returnsToWakeOnly() {
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .awaitingFollowUp(sessionID: "s4"))
        let (next, _) = engine.transition(state: state, event: .commandTranscriptionFailed(reason: "no speech"))
        #expect(next.audioState == .wakeOnly)
    }

    @Test func r28_speechFailed_neverOpensFollowUpWindow() {
        // A genuine TTS failure means the user never actually heard a
        // response — must return straight to `.wakeOnly`, never pretend
        // a turn completed by opening a follow-up window.
        let engine = WakeCoordinatorEngine()
        let state = WakeCoordinatorRuntimeState(audioState: .speaking)
        let (next, action) = engine.transition(state: state, event: .speechFailed(reason: "engine error"))
        #expect(next.audioState == .wakeOnly)
        #expect(action == .none)
    }

    @Test func r28_followUpExitPhrases_matchExactPhrasesOnly_notSubstrings() {
        #expect(FollowUpSessionExitPhrases.matches("Stop listening."))
        #expect(FollowUpSessionExitPhrases.matches("that's all"))
        #expect(FollowUpSessionExitPhrases.matches("  We're done!  "))
        #expect(!FollowUpSessionExitPhrases.matches("and that's all I wanted to check on the first point"))
        #expect(!FollowUpSessionExitPhrases.matches("explain machine learning"))
    }

    @Test func r28_defaultFollowUpInactivityWindow_isEightSeconds() {
        #expect(WakeSessionConfig.standard.followUpInactivityWindow == 8.0)
    }
}
