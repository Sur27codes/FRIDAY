import Foundation

/// P2-M5V6 §3 — a BOUNDED set of observable acoustic facts. Every field
/// here is either a genuinely measured quantity (documented as such) or
/// honestly `nil` (not yet computed by any component in this codebase —
/// never a fabricated placeholder value). **This type never contains, and
/// no code anywhere in this file derives, an emotional label** ("angry,"
/// "sad," "stressed," etc.) — §3's own explicit example: "speech became
/// substantially louder and faster" is an allowed acoustic OBSERVATION;
/// "user is angry" is not, and nothing here produces it. An emotional/
/// affective claim may only ever enter `ConversationContext`/`ConversationUnderstanding`
/// via an EXPLICIT user statement (e.g. "I'm really frustrated"), never
/// from these fields alone — see `ConversationUnderstanding.explicitUserStatement`.
public struct AcousticConversationFeatures: Sendable, Equatable {
    /// Not computed this milestone — real speech-rate estimation (a
    /// syllable/word-rate tracker) is a separate, not-yet-built DSP
    /// component. Honestly `nil`, not approximated.
    public let speechRateEstimate: Double?
    /// 0...1 — a genuine measurement: recent-average RMS energy while
    /// speech was present, normalized against a fixed reference ceiling.
    /// `nil` only when no speech has been observed yet.
    public let relativeLoudness: Double?
    /// Not computed this milestone — real pitch tracking (autocorrelation
    /// or cepstral F0 estimation) is a separate, not-yet-built DSP
    /// component. Honestly `nil`, not approximated.
    public let pitchRange: Double?
    /// Same disclosure as `pitchRange` — `nil`, not approximated.
    public let pitchVariation: Double?
    /// 0...1 — a genuine measurement: fraction of the recent rolling
    /// window that was below the voice-activity threshold.
    public let pauseDensity: Double?
    /// A genuine measurement: elapsed time since the current turn's
    /// first detected speech, computed from frame timestamps (never
    /// wall-clock `Date()`, so this stays deterministic/testable).
    public let utteranceDuration: TimeInterval?
    /// True only when `TurnTakingCoordinator` observed SUSTAINED speech
    /// while FRIDAY was speaking (§18: conservative, not a single noisy
    /// frame).
    public let interruptionDetected: Bool
    /// True when brief/not-yet-sustained overlapping speech was observed
    /// while FRIDAY was speaking (below the interruption-confidence bar).
    public let overlapDetected: Bool
    public let speakingContinuously: Bool
    /// 0...1 — how much of this snapshot reflects genuine measurement
    /// versus "no signal observed yet." `0` means treat every other
    /// field as uninformative.
    public let signalConfidence: Double

    public init(
        speechRateEstimate: Double?, relativeLoudness: Double?, pitchRange: Double?, pitchVariation: Double?,
        pauseDensity: Double?, utteranceDuration: TimeInterval?, interruptionDetected: Bool, overlapDetected: Bool,
        speakingContinuously: Bool, signalConfidence: Double
    ) {
        func clampUnit(_ v: Double?) -> Double? {
            guard let v, v.isFinite else { return nil }
            return min(max(v, 0), 1)
        }
        self.speechRateEstimate = speechRateEstimate
        self.relativeLoudness = clampUnit(relativeLoudness)
        self.pitchRange = pitchRange
        self.pitchVariation = pitchVariation
        self.pauseDensity = clampUnit(pauseDensity)
        self.utteranceDuration = utteranceDuration
        self.interruptionDetected = interruptionDetected
        self.overlapDetected = overlapDetected
        self.speakingContinuously = speakingContinuously
        self.signalConfidence = signalConfidence.isFinite ? min(max(signalConfidence, 0), 1) : 0
    }

    /// The safe default when no acoustic pipeline is attached at all —
    /// every field absent/false, zero confidence. `ConversationReasoning`
    /// implementations must treat this identically to "no acoustic
    /// information available," never as "silence was observed."
    public static let unavailable = AcousticConversationFeatures(
        speechRateEstimate: nil, relativeLoudness: nil, pitchRange: nil, pitchVariation: nil,
        pauseDensity: nil, utteranceDuration: nil, interruptionDetected: false, overlapDetected: false,
        speakingContinuously: false, signalConfidence: 0
    )
}
