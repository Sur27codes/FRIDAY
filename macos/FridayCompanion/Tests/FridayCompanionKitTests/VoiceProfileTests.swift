import Testing
@testable import FridayCompanionKit
import AVFoundation
import Foundation

/// P2-M5V §4/§14 — `VoiceProfile` construction, clamping, and
/// category-adjustment tests. Every numeric bound checked here is the
/// real, verified `AVSpeechUtterance` range (probed directly against
/// this machine's `AVFoundation`, not assumed): rate ∈ [0.0, 1.0],
/// pitch ∈ [0.5, 2.0], volume ∈ [0.0, 1.0].
@Suite struct VoiceProfileTests {

    // MARK: - Rate bounds

    @Test func rate_withinBounds_isPreservedExactly() {
        let p = VoiceProfile(rate: 0.42)
        #expect(p.rate == 0.42)
    }

    @Test func rate_belowMinimum_isClampedToMinimum() {
        let p = VoiceProfile(rate: -5.0)
        #expect(p.rate == AVSpeechUtteranceMinimumSpeechRate)
    }

    @Test func rate_aboveMaximum_isClampedToMaximum() {
        let p = VoiceProfile(rate: 99.0)
        #expect(p.rate == AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test func rate_nonFinite_fallsBackToDefault() {
        #expect(VoiceProfile(rate: .nan).rate == AVSpeechUtteranceDefaultSpeechRate)
        #expect(VoiceProfile(rate: .infinity).rate == AVSpeechUtteranceDefaultSpeechRate)
    }

    // MARK: - Pitch bounds

    @Test func pitch_withinBounds_isPreservedExactly() {
        let p = VoiceProfile(pitchMultiplier: 1.2)
        #expect(p.pitchMultiplier == 1.2)
    }

    @Test func pitch_belowMinimum_isClampedToDocumentedFloor() {
        let p = VoiceProfile(pitchMultiplier: 0.01)
        #expect(p.pitchMultiplier == 0.5)
    }

    @Test func pitch_aboveMaximum_isClampedToDocumentedCeiling() {
        let p = VoiceProfile(pitchMultiplier: 50.0)
        #expect(p.pitchMultiplier == 2.0)
    }

    @Test func pitch_nonFinite_fallsBackToNeutral() {
        #expect(VoiceProfile(pitchMultiplier: .nan).pitchMultiplier == 1.0)
    }

    // MARK: - Volume bounds

    @Test func volume_withinBounds_isPreservedExactly() {
        #expect(VoiceProfile(volume: 0.75).volume == 0.75)
    }

    @Test func volume_belowMinimum_isClampedToZero() {
        #expect(VoiceProfile(volume: -3.0).volume == 0.0)
    }

    @Test func volume_aboveMaximum_isClampedToOne() {
        #expect(VoiceProfile(volume: 3.0).volume == 1.0)
    }

    // MARK: - Delay bounds (product bound, not an Apple-documented one)

    @Test func delays_negative_areClampedToZero() {
        let p = VoiceProfile(preUtteranceDelay: -1, postUtteranceDelay: -1)
        #expect(p.preUtteranceDelay == 0)
        #expect(p.postUtteranceDelay == 0)
    }

    @Test func delays_excessive_areClampedToASaneCeiling() {
        let p = VoiceProfile(preUtteranceDelay: 100, postUtteranceDelay: 100)
        #expect(p.preUtteranceDelay <= 2.0)
        #expect(p.postUtteranceDelay <= 2.0)
    }

    // MARK: - `.friday` starting default

    @Test func fridayDefault_isWithinBoundsAndTargetsSamantha() {
        // Voice identity unchanged across P2-M5V2/V3/V4 (owner explicitly
        // asked to preserve the exact Samantha selection every time) —
        // only prosody changed, now to the P2-M5V4 "PRODUCTION CINEMATIC
        // WARM" values.
        let p = VoiceProfile.friday
        #expect(p.voiceIdentifier == "com.apple.voice.compact.en-US.Samantha")
        #expect(p.language == "en-US")
        #expect(p.preferredGenderFallback == .female)
        #expect(p.rate > AVSpeechUtteranceMinimumSpeechRate && p.rate < AVSpeechUtteranceMaximumSpeechRate)
        #expect(p.pitchMultiplier >= 0.5 && p.pitchMultiplier <= 2.0)
        // P2-M5V4 §2: "do not lower pitch further" — still neutral.
        #expect(p.pitchMultiplier >= 0.99 && p.pitchMultiplier <= 1.01, "pitch must stay near-neutral per the owner's repeated explicit caution, not aggressively lowered")
        // P2-M5V4 §2's exact literal production values — the owner
        // specified absolute `AVSpeechUtterance.rate`-scale numbers
        // directly this time, not a multiplier of the default.
        #expect(p.rate == 0.47, "rate must be exactly 0.47 — deliberately between P2-M5V3's SOFT (0.46) and P2-M5V2's WARM (0.48)")
        #expect(p.pitchMultiplier == 1.00)
        #expect(p.volume == 0.95)
        #expect(p.preUtteranceDelay == 0.06)
        #expect(p.postUtteranceDelay == 0.17)
        // Sits strictly between the preserved SOFT/WARM audition
        // profiles (§3: "this intentionally sits between the previous
        // SOFT and WARM profiles").
        #expect(p.rate > 0.46 && p.rate < 0.48, "production rate must sit strictly between SOFT (0.46) and WARM (0.48)")
    }

    @Test func fridayDefault_actuallyResolvesOnThisMachine() {
        // Behavioral, not just structural — proves the Samantha
        // identifier isn't just a well-formed string but a real,
        // installed voice (or that the fallback chain correctly engages
        // if not).
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: VoiceProfile.friday.voiceIdentifier, locale: VoiceProfile.friday.language,
            preferredGender: VoiceProfile.friday.preferredGenderFallback
        )
        #expect(voice != nil)
    }

    @Test func fridayDefault_onThisMachine_resolvesToSamanthaExactly() {
        // Tier 1 of the fallback chain (exact identifier) must win
        // outright — proves the resolved voice really is Samantha, not
        // merely "some female voice" that happens to also satisfy the
        // gender-fallback target.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: VoiceProfile.friday.voiceIdentifier, locale: VoiceProfile.friday.language,
            preferredGender: VoiceProfile.friday.preferredGenderFallback
        )
        #expect(voice?.identifier == "com.apple.voice.compact.en-US.Samantha")
        #expect(voice?.gender == .female, "Samantha's own metadata genuinely reports female, unlike Kathy's unspecified metadata before her")
    }

    @Test func fridayDefault_ifSamanthaIdentifierMissing_fallsBackToBestInstalledFemaleVoice() {
        // Requirement #2's fallback chain, tier 2 proven directly:
        // simulating "Samantha not installed" via a bogus identifier but
        // the SAME `preferredGenderFallback`/`language` this profile
        // carries — must degrade toward the confirmed en-US/female
        // target (tier 2: best-quality installed en-US female voice),
        // not an arbitrary voice.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: "com.apple.voice.does-not-exist.Samantha", locale: VoiceProfile.friday.language,
            preferredGender: VoiceProfile.friday.preferredGenderFallback
        )
        #expect(voice?.gender == .female, "losing the specific Samantha identifier must still degrade toward the female/en-US target, not an arbitrary voice")
    }

    @Test func fridayDefault_ifNoGenderFallbackConfigured_stillFallsBackToPlainEnUSDefault() {
        // Tier 3, proven directly: with `preferredGenderFallback` reset
        // to `.unspecified` (simulating that tier being unavailable/
        // disabled) and a missing identifier, resolution must still fall
        // through to the plain `en-US` language default rather than
        // returning nil.
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: "com.apple.voice.does-not-exist.Samantha", locale: VoiceProfile.friday.language,
            preferredGender: .unspecified
        )
        #expect(voice != nil, "tier 3 (plain en-US language default) must still resolve to a real voice")
    }

    @Test func fridayDefault_ifEverythingElseFails_systemDefaultNeverCrashes() {
        // Tier 4, structural: an absurd language code with no installed
        // voice at all and no gender fallback — `resolveVoice` must
        // still return cleanly (nil is an acceptable, safe result here;
        // the real safety net is `AVSpeechSynthesizer` itself applying
        // its own OS-level default when `AVSpeechUtterance.voice` is
        // left `nil` — see `resolveVoice`'s own doc comment). The
        // property under test is "never crashes," not "never nil."
        let voice = AVSpeechSynthesizerAdapter.resolveVoice(
            identifier: "com.apple.voice.does-not-exist.Samantha", locale: "zz-ZZ",
            preferredGender: .unspecified
        )
        _ = voice // no crash reaching this line is the assertion
    }

    // MARK: - P2-M5V §10: category-adjusted profiles stay valid and bounded

    @Test func adjusted_information_isUnchangedFromBase() {
        // P2-M5V3 §10: "INFORMATION: neutral, smooth" — exactly the base
        // profile, unaffected.
        let base = VoiceProfile.friday
        #expect(base.adjusted(for: .information) == base)
    }

    @Test func adjusted_success_isUnchangedFromBase() {
        // P2-M5V4 §10 redesign, superseding P2-M5V3: "SUCCESS: production
        // rate, normal volume" reads identically to "INFORMATION: same
        // production profile" — the owner's own wording for both rows is
        // the same, undoing P2-M5V3's small SUCCESS-specific uplift.
        let base = VoiceProfile.friday
        #expect(base.adjusted(for: .success) == base)
    }

    @Test func adjusted_failure_reducesVolumeOnly_rateAndPitchUnchanged() {
        // P2-M5V4 §10 redesign: "FAILURE: slightly softer volume only" —
        // rate and pitch must now be UNTOUCHED (previously both were
        // reduced under P2-M5V3's design).
        let base = VoiceProfile.friday
        let adjusted = base.adjusted(for: .failure)
        #expect(adjusted.rate == base.rate, "rate must be unaffected — volume only, per the explicit redesign")
        #expect(adjusted.pitchMultiplier == base.pitchMultiplier, "pitch must be unaffected — volume only, per the explicit redesign")
        #expect(adjusted.volume < base.volume, "volume must be slightly softer")
        // "Never dramatic" — the delta itself must be small.
        #expect(base.volume - adjusted.volume <= 0.1)
        #expect(adjusted.voiceIdentifier == base.voiceIdentifier, "category adjustment must never change the voice itself")
    }

    @Test func adjusted_everyCategory_preservesVoiceIdentityAndGenderFallback() {
        // P2-M5V2: category-based prosody must never change WHICH voice
        // (or gender-fallback intent) is used — only how it's paced.
        let base = VoiceProfile.friday
        for category: SpeechResponseCategory in [.success, .information, .failure, .permissionDenied, .warning] {
            let adjusted = base.adjusted(for: category)
            #expect(adjusted.voiceIdentifier == base.voiceIdentifier, "\(category) must not change the voice identifier")
            #expect(adjusted.language == base.language, "\(category) must not change the language")
            #expect(adjusted.preferredGenderFallback == base.preferredGenderFallback, "\(category) must not change the gender-fallback intent")
        }
    }

    @Test func adjusted_permissionDenied_isFirmerNotHarsher() {
        let base = VoiceProfile.friday
        let adjusted = base.adjusted(for: .permissionDenied)
        #expect(adjusted.rate == base.rate, "firm ≠ faster — rate should be unaffected")
        #expect(adjusted.pitchMultiplier < base.pitchMultiplier)
        #expect(adjusted.preUtteranceDelay > base.preUtteranceDelay, "a small considered beat before a firm answer")
    }

    @Test func adjusted_warning_isClearAndSlower_pitchUnchanged() {
        let base = VoiceProfile.friday
        let adjusted = base.adjusted(for: .warning)
        #expect(adjusted.rate < base.rate)
        #expect(adjusted.pitchMultiplier == base.pitchMultiplier)
    }

    @Test func everyCategoryAdjustment_producesAStillValidProfile() {
        let base = VoiceProfile(rate: AVSpeechUtteranceMinimumSpeechRate + 0.02, pitchMultiplier: 0.52, volume: 0.02)
        for category: SpeechResponseCategory in [.success, .information, .failure, .permissionDenied, .warning] {
            let adjusted = base.adjusted(for: category)
            #expect(adjusted.rate >= AVSpeechUtteranceMinimumSpeechRate && adjusted.rate <= AVSpeechUtteranceMaximumSpeechRate, "\(category): rate must stay in bounds even near the floor")
            #expect(adjusted.pitchMultiplier >= 0.5 && adjusted.pitchMultiplier <= 2.0, "\(category): pitch must stay in bounds even near the floor")
            #expect(adjusted.volume >= 0.0 && adjusted.volume <= 1.0, "\(category): volume must stay in bounds even near the floor (FAILURE now specifically adjusts volume)")
        }
    }
}
