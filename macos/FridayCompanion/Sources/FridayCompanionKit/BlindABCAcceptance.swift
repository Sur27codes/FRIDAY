import Foundation

/// P2-M5V9-B.3D.2F — pure, testable pieces of the blind cross-backend
/// A/B/C acceptance harness. The actual generation/playback/network
/// calls live in `VoiceAuditionTool` (untested orchestration, same
/// precedent as every other audition command in this codebase); this
/// file holds only the deterministic logic that can and must be
/// verified without any real audio, network, or performer asset:
/// blind-label↔side mapping (reproducible from a seed, never revealed
/// early), and evaluation-set validation (all three sides present, same
/// text everywhere). Nothing here ever computes or claims a "same
/// speaker" verdict — that is exclusively the owner's, printed as a
/// blank template by the caller, never derived here.
public enum ABCSide: String, Sendable, Equatable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
}

public enum ABCBlindLabel: String, Sendable, Equatable, CaseIterable {
    case group1 = "Group 1"
    case group2 = "Group 2"
    case group3 = "Group 3"
}

/// A tiny, deterministic PRNG — NOT cryptographically secure, and not
/// meant to be; it exists solely so `blindLabelMapping(seed:)` is
/// reproducible across runs for the SAME seed (Swift's default
/// `.shuffle()` uses the system RNG and is not reproducible).
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Maps the three blind labels to the three real sides, reproducibly
/// for a given `seed` — the SAME seed always yields the SAME mapping;
/// only the TEXT stays un-randomized (identical across all three real
/// sides for every utterance), never the label↔side assignment.
public func blindLabelMapping(seed: UInt64) -> [ABCBlindLabel: ABCSide] {
    var generator = SeededGenerator(seed: seed)
    let shuffledSides = ABCSide.allCases.shuffled(using: &generator)
    var mapping: [ABCBlindLabel: ABCSide] = [:]
    for (label, side) in zip(ABCBlindLabel.allCases, shuffledSides) {
        mapping[label] = side
    }
    return mapping
}

/// Formats a mapping for display — deliberately a SEPARATE function
/// from anything invoked during the main playback loop, so revealing it
/// is always a distinct, explicit, end-of-run step (never interleaved
/// with per-pair blinded playback).
public func revealBlindMapping(_ mapping: [ABCBlindLabel: ABCSide]) -> String {
    ABCBlindLabel.allCases.compactMap { label in mapping[label].map { "\(label.rawValue) = \($0.rawValue)" } }.joined(separator: ", ")
}

/// One side's measured, objective (never identity-claiming) result for
/// one utterance.
public struct ABCSideResult: Sendable, Equatable {
    public let side: ABCSide
    public let text: String
    public let sampleRate: Int?
    public let durationSec: Double?
    public let success: Bool

    public init(side: ABCSide, text: String, sampleRate: Int?, durationSec: Double?, success: Bool) {
        self.side = side
        self.text = text
        self.sampleRate = sampleRate
        self.durationSec = durationSec
        self.success = success
    }
}

public enum ABCEvaluationSetError: Error, Sendable, Equatable {
    case missingSide(ABCSide)
    case textMismatch
}

/// Validates one evaluation pair-set (all three sides, same utterance)
/// before it may be presented to the owner. Fails closed: any missing
/// side, or any side that was generated from DIFFERENT text than the
/// others, invalidates the whole set rather than presenting a
/// misleading partial comparison.
public func validateABCEvaluationSet(a: ABCSideResult?, b: ABCSideResult?, c: ABCSideResult?) -> Result<(a: ABCSideResult, b: ABCSideResult, c: ABCSideResult), ABCEvaluationSetError> {
    guard let a else { return .failure(.missingSide(.a)) }
    guard let b else { return .failure(.missingSide(.b)) }
    guard let c else { return .failure(.missingSide(.c)) }
    guard a.text == b.text, b.text == c.text else { return .failure(.textMismatch) }
    return .success((a, b, c))
}

/// Reports (never enforces/rejects) whether the three sides' sample
/// rates agree — a WAV/PCM-format observation, never used to claim or
/// disprove speaker identity, and never used to silently discard a
/// mismatched side.
public func sampleRatesAgree(_ set: (a: ABCSideResult, b: ABCSideResult, c: ABCSideResult)) -> Bool {
    guard let ra = set.a.sampleRate, let rb = set.b.sampleRate, let rc = set.c.sampleRate else { return false }
    return ra == rb && rb == rc
}
