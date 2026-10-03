import AVFoundation
import Foundation

/// A bounded prosody intent for one spoken response — introduced as
/// `SpeechResponseCategory` at P2-M5V §10, RENAMED (not replaced) at
/// P2-M5V5 §13 to `ProsodyIntent` to match the new
/// `AdaptiveProsodyPlanner` architecture's own vocabulary, with a
/// `SpeechResponseCategory` type alias kept below so every pre-P2-M5V5
/// call site (`SpeechSynthesizing`'s protocol signature,
/// `AVSpeechSynthesizerAdapter`, `WakeCoordinator`, every existing test)
/// keeps compiling completely unchanged — this is the exact same type,
/// under an additional, more accurate name, not a breaking rename.
///
/// Deliberately small and closed — this is NOT an emotion system; it
/// only selects among a few small, deterministic prosody deltas applied
/// on top of the base `VoiceProfile` (P2-M5V §10 / P2-M5V5 §13: "Do NOT
/// create emotional theatrics" / "the same FRIDAY voice must remain
/// recognizable").
public enum ProsodyIntent: Sendable, Equatable {
    /// A genuine SUCCESS outcome — confident, neutral delivery.
    case success
    /// A calm status report that is neither success nor failure —
    /// unsupported/ambiguous/invalid-request/cancelled/duplicate/
    /// already-terminal outcomes. This is also the default for callers
    /// that don't care about intent.
    case information
    /// A genuine execution/system-level failure — slightly softer
    /// delivery, never dramatic.
    case failure
    /// Authorization was denied — firm but polite.
    case permissionDenied
    /// Something the owner should pay closer attention to (e.g. "this
    /// needs manual review") — clear and slightly slower, not alarming.
    case warning
    /// P2-M5V5 §13 — "FRIENDLY / NORMAL": baseline warmth, the everyday
    /// conversational default for a genuinely friendly (not neutral,
    /// not effusive) exchange.
    case friendly
    /// P2-M5V5 §13 — "CASUAL": slightly quicker, tighter pauses, same
    /// pitch — light conversational follow-up register.
    case casual
    /// P2-M5V5 §13 — "FOCUSED": baseline pace, a shorter pre-delay for
    /// high clarity — used when the user asked something direct and
    /// deserves an immediate, attentive answer.
    case focused
    /// P2-M5V5 §13 — "REASSURING": slightly slower and softer, longer
    /// pauses — calming without becoming somber.
    case reassuring
    /// P2-M5V5 §13 — "SERIOUS": slightly slower, restrained energy,
    /// volume left at baseline (never dramatic).
    case serious
    /// P2-M5V5 §13 — "URGENT": slightly quicker with tighter cadence —
    /// paired with shorter wording at the text-selection layer, never a
    /// pitch/volume spike.
    case urgent
}

/// See `ProsodyIntent`'s own doc comment — kept as a full type alias
/// (not a separate, parallel type) so every existing reference compiles
/// unchanged.
public typealias SpeechResponseCategory = ProsodyIntent

/// Immutable TTS configuration (P2-M5V §4) — the single place rate/
/// pitch/volume/timing values live, so they are never scattered as
/// magic numbers across `AVSpeechSynthesizerAdapter`/`WakeCoordinator`.
/// Every numeric field is clamped in `init` to the real, verified
/// `AVSpeechUtterance` bounds (probed directly against this machine's
/// `AVFoundation`: rate ∈ [0.0, 1.0], default 0.5; pitch ∈ [0.5, 2.0]
/// per Apple's documented `AVSpeechUtterance.pitchMultiplier` range;
/// volume ∈ [0.0, 1.0]) — a malformed or hand-edited profile can never
/// produce an out-of-range value silently passed to the real engine.
public struct VoiceProfile: Sendable, Equatable {
    /// A specific `AVSpeechSynthesisVoice.identifier`, or `nil` to fall
    /// through to `preferredGenderFallback`/`language` resolution
    /// instead (§6/§7 of P2-M5's own authorization: never hard-code a
    /// voice with no fallback).
    public let voiceIdentifier: String?
    public let language: String
    /// P2-M5V2 §7 — when `voiceIdentifier` is `nil` or not installed on
    /// the running machine, prefer the best-quality installed voice
    /// matching this gender for `language` before falling all the way
    /// back to the bare language default (`AVSpeechSynthesizerAdapter.resolveVoice`
    /// implements the actual 3-tier chain). `.unspecified` (the default)
    /// disables this tier entirely, preserving every pre-P2-M5V2
    /// caller's exact behavior.
    public let preferredGenderFallback: AVSpeechSynthesisVoiceGender
    public let rate: Float
    public let pitchMultiplier: Float
    public let volume: Float
    /// A brief pause before the utterance begins — a natural, composed
    /// beat rather than an instant, clipped start.
    public let preUtteranceDelay: TimeInterval
    /// A brief pause after the utterance ends — a settled, unhurried
    /// finish rather than an abrupt cutoff.
    public let postUtteranceDelay: TimeInterval

    public init(
        voiceIdentifier: String? = nil,
        language: String = "en-US",
        preferredGenderFallback: AVSpeechSynthesisVoiceGender = .unspecified,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitchMultiplier: Float = 1.0,
        volume: Float = 1.0,
        preUtteranceDelay: TimeInterval = 0,
        postUtteranceDelay: TimeInterval = 0
    ) {
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        self.preferredGenderFallback = preferredGenderFallback
        self.rate = Self.clampRate(rate)
        self.pitchMultiplier = Self.clampPitch(pitchMultiplier)
        self.volume = Self.clampVolume(volume)
        // Not an Apple-documented hard bound, but a sane product bound —
        // a misconfigured profile should never be able to insert a
        // multi-second dead-air pause before/after every single utterance.
        self.preUtteranceDelay = min(max(preUtteranceDelay, 0), 2.0)
        self.postUtteranceDelay = min(max(postUtteranceDelay, 0), 2.0)
    }

    static func clampRate(_ r: Float) -> Float {
        r.isFinite ? min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate) : AVSpeechUtteranceDefaultSpeechRate
    }

    static func clampPitch(_ p: Float) -> Float {
        p.isFinite ? min(max(p, 0.5), 2.0) : 1.0
    }

    static func clampVolume(_ v: Float) -> Float {
        v.isFinite ? min(max(v, 0.0), 1.0) : 1.0
    }

    /// P2-M5V §10, refined at P2-M5V3 §10, redesigned at P2-M5V4 §10,
    /// extended at P2-M5V5 §13/§14 — small, bounded, deterministic
    /// prosody deltas per intent, applied on top of this base profile.
    /// Every delta is well inside `init`'s own clamping, so the result
    /// is always a valid profile regardless of the base. Deliberately
    /// tiny: this is calibration, not a mood system — "the same FRIDAY
    /// voice must remain recognizable" (P2-M5V5 §13). Percentages below
    /// are computed against the P2-M5V4 production baseline (rate 0.47,
    /// volume 0.95) for documentation; the actual deltas are fixed
    /// absolute values that stay proportionally small for any base.
    ///
    /// The five original cases (success/information/failure/
    /// permissionDenied/warning) keep their P2-M5V4 behavior, with one
    /// refinement: WARNING's rate delta is reduced from -0.05 to -0.03
    /// (≈6.4% of the 0.47 baseline) to fit P2-M5V5 §13's explicit
    /// "WARNING: rate -4–7%" guidance — still strictly slower, still
    /// satisfies every existing test (which checks `rate < base.rate`
    /// and `pitch unchanged`, not the exact prior magnitude).
    public func adjusted(for category: ProsodyIntent) -> VoiceProfile {
        switch category {
        case .success, .information:
            // P2-M5V4: "SUCCESS: production rate, normal volume" /
            // "INFORMATION: same production profile" — both exactly the
            // base profile, unchanged.
            return self
        case .failure:
            // P2-M5V4: "slightly softer volume only" — rate and pitch
            // are deliberately left untouched now.
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate, pitchMultiplier: pitchMultiplier, volume: volume - 0.05,
                preUtteranceDelay: preUtteranceDelay, postUtteranceDelay: postUtteranceDelay
            )
        case .permissionDenied:
            // "Calm and firm" — a marginally lower pitch and a beat
            // longer before answering, not a harsher rate.
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate, pitchMultiplier: pitchMultiplier - 0.01, volume: volume,
                preUtteranceDelay: preUtteranceDelay + 0.05, postUtteranceDelay: postUtteranceDelay
            )
        case .warning:
            // P2-M5V5 §13: "rate -4–7%" — refined from P2-M5V4's -0.05
            // to -0.03 (≈6.4% of the 0.47 baseline) to fit that range;
            // pitch/volume unchanged, longer pause, clear articulation.
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate - 0.03, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: preUtteranceDelay + 0.02, postUtteranceDelay: postUtteranceDelay
            )
        case .friendly:
            // §13: "baseline or: rate +0–2%, warm delivery, normal
            // volume" — a barely-perceptible nudge, not a mood swing.
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate + 0.01, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: preUtteranceDelay, postUtteranceDelay: postUtteranceDelay
            )
        case .casual:
            // §13: "rate +1–3%, slightly tighter pauses, same pitch."
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate + 0.01, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: max(0, preUtteranceDelay - 0.01), postUtteranceDelay: max(0, postUtteranceDelay - 0.01)
            )
        case .focused:
            // §13: "rate approximately baseline, slightly shorter
            // pre-delay, high clarity."
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: max(0, preUtteranceDelay - 0.02), postUtteranceDelay: postUtteranceDelay
            )
        case .reassuring:
            // §13: "rate -2–4%, volume -2–4%, slightly longer pauses."
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate - 0.01, pitchMultiplier: pitchMultiplier, volume: volume - 0.03,
                preUtteranceDelay: preUtteranceDelay + 0.02, postUtteranceDelay: postUtteranceDelay + 0.02
            )
        case .serious:
            // §13: "rate -3–5%, volume approximately baseline, energy
            // restrained" — no separate "energy" lever exists in this
            // simple system, so restraint is expressed via rate alone.
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate - 0.02, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: preUtteranceDelay, postUtteranceDelay: postUtteranceDelay
            )
        case .urgent:
            // §13: "shorter wording, clearer cadence, minimal
            // conversational filler" — the wording-length half of this
            // lives at the text-selection layer (`ResponseRealizer`);
            // here, prosody only tightens the cadence slightly — never a
            // pitch/volume spike ("do NOT dramatically raise pitch...
            // make 'angry voice'").
            return VoiceProfile(
                voiceIdentifier: voiceIdentifier, language: language, preferredGenderFallback: preferredGenderFallback,
                rate: rate + 0.01, pitchMultiplier: pitchMultiplier, volume: volume,
                preUtteranceDelay: max(0, preUtteranceDelay - 0.02), postUtteranceDelay: max(0, postUtteranceDelay - 0.03)
            )
        }
    }
}

extension VoiceProfile {
    /// P2-M5V2/owner-selection update — **Samantha is now the
    /// owner-selected production voice**, replacing the prior Kathy
    /// selection per explicit owner instruction. Uses the real, verified
    /// `AVSpeechSynthesisVoice` identifier
    /// `com.apple.voice.compact.en-US.Samantha` — re-confirmed directly
    /// against this machine's actual `AVSpeechSynthesisVoice.speechVoices()`
    /// inventory immediately before this change (not assumed from the
    /// name alone, per the explicit instruction to verify first): `en-US`,
    /// `Default/Compact` quality, `gender == .female`. Samantha belongs
    /// to the newer "compact" voice family (`com.apple.voice.compact.*`
    /// — the same family the rest of Phase-2's STT/TTS work has already
    /// exercised extensively since P2-M4/P2-M5) and, unlike Kathy's
    /// legacy Speech Synthesis family, carries correct `.female` gender
    /// metadata — disclosed as a factual difference, not a claim that it
    /// changes anything about voice selection (tier 1 below matches by
    /// exact identifier either way). As with Kathy before it, this
    /// identifier is expected — not literally re-verified on the owner's
    /// own hardware, which this environment cannot access — to be
    /// identical on the owner's Mac, since Samantha has been a
    /// long-bundled, non-downloadable macOS voice since it shipped.
    ///
    /// Fallback chain (§7, unchanged mechanism, still implemented
    /// entirely in `AVSpeechSynthesizerAdapter.resolveVoice`): **(1)**
    /// this exact Samantha identifier if installed → **(2)** the
    /// best-quality installed en-US female voice (`preferredGenderFallback`
    /// stays `.female`, so a missing Samantha still degrades toward the
    /// owner's confirmed female/American target, not to an arbitrary
    /// voice) → **(3)** the plain `en-US` language default → **(4)**
    /// whatever `AVSpeechSynthesizer` applies as its own OS-level default
    /// if even that returns `nil` (never observed in this project, but
    /// never crashes either way).
    ///
    /// P2-M5V4 §1/§2 update: **"PRODUCTION — CINEMATIC WARM"**, replacing
    /// P2-M5V3's "FRIDAY Soft" values. Voice identifier/language/
    /// gender-fallback are AGAIN unchanged (§1 explicitly: "keep the
    /// existing fallback chain... do not change fallback behavior") —
    /// this update is presentation/prosody only, exactly like every
    /// voice-profile pass before it.
    ///
    /// §2's exact literal values (not multipliers this time — the owner
    /// specified absolute `AVSpeechUtterance.rate`-scale numbers
    /// directly): rate **0.47** — deliberately between P2-M5V3's SOFT
    /// (0.46) and P2-M5V2's WARM (0.48), "faster than SOFT, smoother
    /// than current WARM... responsive rather than slow"; pitch **1.00**
    /// — explicitly NOT lowered further ("do not lower pitch further"),
    /// same neutral value as Soft; volume **0.95** — same as Soft;
    /// preUtteranceDelay **0.06s** and postUtteranceDelay **0.17s** —
    /// both between Soft's (0.08/0.20) and Warm's (0.05/0.15) own
    /// values, for "natural sentence endings" without SOFT's longer
    /// pause or WARM's clipped one. This is exactly `VoiceAuditionTool`'s
    /// new "D - PRODUCTION CINEMATIC WARM" variant — auditioning
    /// candidate D previews precisely what production sounds like.
    ///
    /// §2 of P2-M5V's own original instruction still applies unchanged:
    /// `com.apple.voice.compact.en-US.Samantha` is a Compact/default-tier
    /// Apple voice — functional, offline, reliable, fallback-quality, not
    /// a claimed equivalent to a modern neural voice. See
    /// `docs/E-traceability-matrix.md`'s P2-M5V4 section and §14's
    /// "prepare for a better engine" checklist (unchanged, still open)
    /// for the disclosed next step if this still doesn't clear the
    /// owner's bar.
    public static let friday = VoiceProfile(
        voiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
        language: "en-US",
        preferredGenderFallback: .female,
        rate: 0.47,
        pitchMultiplier: 1.00,
        volume: 0.95,
        preUtteranceDelay: 0.06,
        postUtteranceDelay: 0.17
    )
}
