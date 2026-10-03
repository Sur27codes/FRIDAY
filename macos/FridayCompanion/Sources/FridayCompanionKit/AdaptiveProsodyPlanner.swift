import Foundation

/// P2-M5V5 §13 — the final pipeline stage before `SpeechSynthesizing`:
/// a `ProsodyIntent` (chosen by `ResponseStrategyPlanner`) plus the
/// current production baseline `VoiceProfile` → the actual bounded
/// rate/pitch/volume/delays to speak with. Deliberately a THIN,
/// separately-testable wrapper around `VoiceProfile.adjusted(for:)`
/// (§0: "do not delete or weaken the current production fallback
/// profile" — this type never constructs a profile from scratch, it
/// only ever adjusts the one already-approved baseline it's given).
public protocol AdaptiveProsodyPlanning: Sendable {
    func prosody(for intent: ProsodyIntent, base: VoiceProfile) -> VoiceProfile
}

public struct DeterministicAdaptiveProsodyPlanner: AdaptiveProsodyPlanning {
    public init() {}

    /// All actual deltas live on `VoiceProfile.adjusted(for:)` — kept in
    /// exactly one place so `AdaptiveProsodyPlanner` and
    /// `SpeechSynthesizing` consumers can never compute two different
    /// answers for the same `(intent, base)` pair. `VoiceProfile`'s own
    /// `clampRate`/`clampPitch`/`clampVolume` helpers guarantee every
    /// result stays within `VoiceProfile`'s already-audited safe bounds
    /// (§13: "no cartoon emotional voices — subtle modulation only").
    public func prosody(for intent: ProsodyIntent, base: VoiceProfile) -> VoiceProfile {
        base.adjusted(for: intent)
    }
}

/// P2-M5V6 §20 — the final bounded prosody, one level richer than a bare
/// `VoiceProfile`: adds the small set of additional dimensions §20 asks
/// for (`sentencePause`/`emphasisStrength`/`energy`) without discarding
/// any of `VoiceProfile`'s own already-audited fields.
public struct ProsodyPlan: Sendable, Equatable {
    public let rate: Float
    public let pitchMultiplier: Float
    public let volume: Float
    public let preUtteranceDelay: TimeInterval
    public let postUtteranceDelay: TimeInterval
    /// A restatement of `postUtteranceDelay` under the name §20 uses —
    /// kept equal to it rather than a second, independently-tunable
    /// value, so there is exactly one place pause timing is decided.
    public let sentencePause: TimeInterval
    /// 0...1 — how much delivery emphasis this response calls for
    /// (directness-driven); no engine wiring consumes this yet (no
    /// premium engine exists), but it is real, bounded, and tested.
    public let emphasisStrength: Double
    /// 0...1 — carried straight from `FridayPersona.energy`, the one
    /// stable baseline (§3), never computed independently per response.
    public let energy: Double

    public init(rate: Float, pitchMultiplier: Float, volume: Float, preUtteranceDelay: TimeInterval, postUtteranceDelay: TimeInterval, emphasisStrength: Double, energy: Double) {
        self.rate = VoiceProfile.clampRate(rate)
        self.pitchMultiplier = VoiceProfile.clampPitch(pitchMultiplier)
        self.volume = VoiceProfile.clampVolume(volume)
        self.preUtteranceDelay = min(max(preUtteranceDelay, 0), 2.0)
        self.postUtteranceDelay = min(max(postUtteranceDelay, 0), 2.0)
        self.sentencePause = self.postUtteranceDelay
        self.emphasisStrength = emphasisStrength.isFinite ? min(max(emphasisStrength, 0), 1) : 0
        self.energy = energy.isFinite ? min(max(energy, 0), 1) : 0.5
    }
}

public extension AdaptiveProsodyPlanning {
    /// P2-M5V6 §19/§20 — consumes `NaturalResponsePlan` + safe
    /// `AcousticConversationFeatures` on top of the existing intent-based
    /// adjustment, producing a `ProsodyPlan`. A DEFAULT protocol
    /// extension (not a new required method) so `DeterministicAdaptiveProsodyPlanner`
    /// needs no changes to gain this — every conformer automatically
    /// inherits the same, single implementation, never a second place
    /// prosody rules could drift (§26).
    ///
    /// Acoustic adaptation is deliberately CONSERVATIVE and one-directional
    /// (§19's own examples): quiet input nudges FRIDAY's own volume
    /// slightly softer (never louder in response to loud input — §19
    /// explicitly warns against concluding anger from loudness and
    /// reacting in kind). Every delta is small and only applied when
    /// `acoustics.signalConfidence` indicates real measurement, never a
    /// default/unavailable snapshot.
    func prosodyPlan(persona: FridayPersona, plan: NaturalResponsePlan, acoustics: AcousticConversationFeatures, base: VoiceProfile) -> ProsodyPlan {
        let voiceProfile = prosody(for: plan.prosodyIntent, base: base)
        var volume = voiceProfile.volume
        if acoustics.signalConfidence >= 0.5, let loudness = acoustics.relativeLoudness, loudness < 0.15 {
            // §19: "quiet + slow + late-night output context -> FRIDAY
            // may speak slightly softer" — the conservative, always-safe
            // half of that example (quiet input only; no output-context
            // signal is wired into this call site yet).
            volume = VoiceProfile.clampVolume(volume - 0.03)
        }
        var rate = voiceProfile.rate
        if plan.urgency >= 0.6 {
            // §19: explicit urgency -> shorter/more focused, matching
            // §13's own URGENT delta direction (slightly faster, tighter
            // cadence) — bounded to the same small magnitude as every
            // other `ProsodyIntent` delta.
            rate = VoiceProfile.clampRate(rate + 0.01)
        }
        return ProsodyPlan(
            rate: rate, pitchMultiplier: voiceProfile.pitchMultiplier, volume: volume,
            preUtteranceDelay: voiceProfile.preUtteranceDelay, postUtteranceDelay: voiceProfile.postUtteranceDelay,
            emphasisStrength: plan.directness * 0.3, energy: persona.energy
        )
    }
}
