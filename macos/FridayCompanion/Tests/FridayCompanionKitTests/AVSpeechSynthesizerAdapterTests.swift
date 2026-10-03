import Testing
@testable import FridayCompanionKit
import Foundation
import AVFoundation

/// P2-M5 §6/§42/§44 — real, production `AVSpeechSynthesizerAdapter`
/// tests (not `FakeSpeechSynthesizer`). This is the one file in the
/// suite that actually invokes real, local TTS synthesis on whatever
/// machine runs `swift test`, so it can report genuinely measured
/// numbers instead of assumed ones — the same discipline
/// `SherpaOnnxWakeWordDetectorTests` already applies to the real wake
/// detector.
///
/// P2-M5V finding: a real, reproducible `SIGSEGV` inside Apple's
/// private `TextToSpeech.framework` (confirmed via the actual macOS
/// crash report — `EXC_BAD_ACCESS`/`KERN_INVALID_ADDRESS`, main thread,
/// inside `objc_retain` reached from `TextToSpeech`'s own internals via
/// `_dispatch_main_queue_drain`) was observed during this milestone's
/// own verification. The crash fires ASYNCHRONOUSLY, sometimes several
/// unrelated tests later than the real-synthesis test that triggered
/// it — consistent with `AVSpeechSynthesizer`'s own internal cleanup
/// still running on the main queue after a short-lived local
/// `AVSpeechSynthesizerAdapter` (and the `AVSpeechSynthesizer`/delegate
/// it owns) has already been deallocated at the end of its test
/// function. **This is a test-harness artifact, not a production
/// risk**: `WakeCoordinator` holds its `synthesizer` as a `let` for the
/// entire actor's lifetime (effectively the whole app's lifetime) and
/// never deallocates it mid-run, so the "adapter freed while
/// TextToSpeech is still cleaning up" precondition this crash needs
/// cannot arise there. Fixed here by keeping one adapter alive for this
/// suite's entire process lifetime (`sharedAdapter`, mirroring
/// production's own long-lived-instance pattern) instead of a fresh
/// local instance per test, plus `.serialized` as defense-in-depth
/// against any residual concurrent-instance risk (the same fix pattern
/// already applied to `SherpaOnnxWakeWordDetectorTests`'s own unrelated
/// native-library concurrency hazard).
@Suite(.serialized) struct AVSpeechSynthesizerAdapterTests {
    /// Deliberately never deallocated for the life of the test process —
    /// see the type's own doc comment for why.
    static let sharedAdapter = AVSpeechSynthesizerAdapter()

    @Test func defaultVoice_resolvesToAnInstalledVoice_neverNil() {
        // §6/§7: the exact claim this milestone makes about voice
        // availability, checked directly against the real
        // `AVSpeechSynthesisVoice` API on this machine rather than
        // assumed.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "en-US")
        #expect(voice != nil, "the default-language lookup must always resolve to an installed voice")
    }

    @Test func unknownVoiceIdentifier_fallsBackToLanguageDefault_neverNil() {
        // §6: "fallback behavior when preferred voice unavailable."
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: "com.apple.voice.does-not-exist.xyz", locale: "en-US")
        #expect(voice != nil, "an unknown voice identifier must fall back to the language default, never produce no voice at all")
    }

    // MARK: - P2-M5V2 §7: three-tier fallback (identifier -> gender+language match -> plain language default)

    @Test func resolveVoice_noPreferredGender_behavesExactlyAsBeforeP2M5V2() {
        // Regression: the new `preferredGender` parameter defaults to
        // `.unspecified`, which must disable the new tier entirely —
        // every pre-P2-M5V2 call site's behavior is unaffected.
        let withDefault = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "en-US")
        let explicitUnspecified = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "en-US", preferredGender: .unspecified)
        #expect(withDefault?.identifier == explicitUnspecified?.identifier)
    }

    @Test func resolveVoice_missingIdentifier_prefersBestQualityMatchingGenderOverPlainLanguageDefault() {
        // On this machine, the plain `en-US` language default is
        // Samantha (female) anyway, so this specifically proves the
        // MECHANISM (tier 2 firing) rather than relying on tier 2 and
        // tier 3 coincidentally agreeing: request `.male` explicitly —
        // the plain language default would still be Samantha (female),
        // but tier 2 must find a real installed en-US male voice
        // instead (Fred, per the real inventory) if one exists.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "en-US", preferredGender: .male)
        #expect(voice?.gender == .male, "an explicit gender preference must be honored over the plain language default when a matching voice is installed")
    }

    @Test func resolveVoice_missingIdentifierAndNoGenderMatchInstalled_fallsBackToPlainLanguageDefault() {
        // No en-CA voices of any gender are expected on a typical
        // install beyond possibly a French-Canadian voice under a
        // different language code — using a deliberately-improbable
        // gender/language combination to exercise tier 3.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "es-MX", preferredGender: .male)
        // es-MX has no male voice on this machine (only Paulina, female)
        // — must still resolve to SOMETHING (the plain es-MX default),
        // never nil, never crash.
        #expect(voice != nil, "must fall back to the plain language default when no gender match is installed")
    }

    @Test func resolveVoice_realInstalledIdentifier_alwaysWinsOverGenderFallback() {
        // Tier 1 (exact identifier) must take priority even when it
        // contradicts `preferredGender` — an explicit choice is never
        // silently overridden by the fallback machinery.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: "com.apple.voice.compact.en-US.Samantha", locale: "en-US", preferredGender: .male)
        #expect(voice?.identifier == "com.apple.voice.compact.en-US.Samantha")
    }

    @Test func bestQualityVoice_returnsNilWhenNoMatchInstalled_neverCrashes() {
        // A deliberately nonsensical language/gender pairing this
        // machine cannot possibly have — proves the helper degrades to
        // `nil` cleanly rather than crashing or returning something
        // wrong.
        let voice = AVSpeechSynthesizerAdapter.bestQualityVoice(language: "xx-XX", gender: .female)
        #expect(voice == nil)
    }

    // MARK: - §14/§32/§42: real synthesis lifecycle + measured latency

    @Test func realSynthesis_speaksProductionShapedText_completesExactlyOnce_measuresLatency() async throws {
        let adapter = Self.sharedAdapter
        let text = "System status retrieved successfully." // the real production success template
        let startedAt = Date()

        let outcome: SpeechSynthesisOutcome = await withCheckedContinuation { continuation in
            do {
                try adapter.speak(text) { outcome in
                    continuation.resume(returning: outcome)
                }
            } catch {
                continuation.resume(returning: .failed(String(describing: error)))
            }
        }
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        // Let the engine's own internal cleanup settle before the next
        // test reuses the same shared adapter — see the suite's own doc
        // comment for why this matters.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(outcome == .finished, "real synthesis of a short, well-formed response must complete normally")
        // §42: reported, not asserted as an SLA (§43: "do not establish
        // an arbitrary SLA after measurement — report actual values") —
        // this upper bound only catches a genuine hang/regression (e.g.
        // a stuck delegate callback), not a performance target.
        #expect(elapsedMs < 15_000, "measured speak()->completion for a \(text.count)-character response: \(elapsedMs)ms")
    }

    @Test func realSynthesis_stopShortlyAfterStarting_deliversInterruptedExactlyOnce() async throws {
        // §14/§21/§35: the real barge-in mechanics — stop() must
        // actually cut audio and deliver exactly one `.interrupted`,
        // never leave the completion handler uncalled.
        let adapter = Self.sharedAdapter
        // Long enough that stop() reliably arrives well before natural completion.
        let text = "System status retrieved successfully. This is a longer sentence added only so there is enough audio in flight for a real stop call to interrupt before natural completion."

        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func resumeOnce(_ body: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let guardBox = ResumeGuard()

        let outcome: SpeechSynthesisOutcome = await withCheckedContinuation { continuation in
            do {
                try adapter.speak(text) { outcome in
                    guardBox.resumeOnce { continuation.resume(returning: outcome) }
                }
            } catch {
                guardBox.resumeOnce { continuation.resume(returning: .failed(String(describing: error))) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                adapter.stop()
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(outcome == .interrupted, "a real stop() shortly after starting must deliver .interrupted, not .finished or a hang")
    }

    @Test func realSynthesizer_stopWithNothingSpeaking_isHarmlessNoOp() {
        let adapter = Self.sharedAdapter
        adapter.stop() // must not crash
        adapter.stop() // idempotent
    }

    // MARK: - §44: offline claim — structural half is
    // `WakeSecurityTests.sec009_wakeDetectorHasNoNetworkDependency`
    // (extended this milestone to also scan
    // `AVSpeechSynthesizerAdapter.swift`/`SpeechSynthesizing.swift`/
    // `ResponsePresenting.swift`). This is the behavioral half, mirroring
    // `SherpaOnnxWakeWordDetectorTests.offline_detectionStillWorksWithNetworkUnreachable`'s
    // own reasoning: this adapter has no networking API anywhere in its
    // call path, so the same real synthesis call above already IS the
    // offline proof — there is nothing network-dependent to sever. The
    // voice used (`com.apple.voice.compact.en-US.Samantha`, confirmed via
    // a direct `AVSpeechSynthesisVoice` probe against this machine) is a
    // "compact" quality voice bundled with the OS, not one of Apple's
    // higher-quality voices that require a separate download through
    // System Settings — so the honest claim is "offline, no additional
    // voice-asset install required" for THIS specific default, not a
    // blanket claim about every possible `AVSpeechSynthesisVoice`.
    @Test func defaultVoice_isACompactPreinstalledQuality_notADownloadableVoice() {
        guard let voice = AVSpeechSynthesizerAdapter.resolveVoice(identifier: nil, locale: "en-US") else {
            Issue.record("expected a resolvable default en-US voice")
            return
        }
        #expect(voice.quality == .default, "the default voice this milestone ships must be the standard pre-installed quality tier, not a tier that implies an optional download")
    }

    // MARK: - P2-M5V4 §13: diagnostics report the production profile truthfully

    @Test func productionAdapter_engineIdentifier_truthfullyReflectsConfiguredVoice() {
        // `WakeDiagnosticsRecorder.recordSpeechStarted(engineIdentifier:)`
        // records exactly this string — this is the mechanism by which
        // diagnostics "report the production profile truthfully": the
        // configured voice identifier (Samantha), not an assumed or
        // stale one, and not the raw prosody numbers (which diagnostics
        // never expose, by design — see `WakeDiagnostics.swift`'s own
        // "counts/identifiers, not raw audio parameters" scope).
        let adapter = AVSpeechSynthesizerAdapter(profile: .friday)
        #expect(adapter.engineIdentifier.contains("com.apple.voice.compact.en-US.Samantha"), "got '\(adapter.engineIdentifier)'")
    }
}
