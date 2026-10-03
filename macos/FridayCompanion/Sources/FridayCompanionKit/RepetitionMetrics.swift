import Foundation

/// P2-M5V8.1-P.1 §26/§28 — DEVELOPER-ONLY, NON-AUTHORITATIVE repetition
/// diagnostics. Deliberately simple deterministic normalization (lowercase
/// + trim + first-N-word opener) — never semantic embeddings, never a
/// second model call (§26/§28's own explicit constraint: "do not use
/// semantic embeddings or another model"). Nothing here gates, filters,
/// or changes what gets spoken; `ConversationalResponsePresenter`'s own
/// existing `avoiding`/`avoidingAny` repetition-AVOIDANCE machinery
/// (unchanged by this pass) already does that. This is purely a
/// measurement the owner/harness can read, matching the same "diagnostic
/// only" discipline `UnifiedDecodeDiagnostic`/`WakeDiagnosticsSnapshot`
/// already established.
public struct RepetitionMetrics: Sendable, Equatable {
    /// How many of the analyzed texts are an EXACT duplicate of another
    /// text earlier in the same window (order-independent count of
    /// "repeat occurrences," not distinct repeated values).
    public let exactRepetitionCount: Int
    /// How many share the same normalized OPENING phrase (first two
    /// words, lowercased) as another text earlier in the window — catches
    /// "Got it... / Got it... / Got it..." even when the rest of the
    /// sentence differs.
    public let openingPhraseRepetitionCount: Int
    /// The most-repeated exact text in the window, if any repeated at all.
    public let mostRepeatedExactText: String?
    /// The most-repeated normalized opening phrase, if any repeated at all.
    public let mostRepeatedOpeningPhrase: String?
    public let sampleCount: Int

    public static let empty = RepetitionMetrics(exactRepetitionCount: 0, openingPhraseRepetitionCount: 0, mostRepeatedExactText: nil, mostRepeatedOpeningPhrase: nil, sampleCount: 0)
}

public enum RepetitionAnalyzer {
    /// P2-M5V8.1-P.1 §26 — normalizes ONLY punctuation-insensitivity and
    /// case (never stemming/embeddings/paraphrase-detection — a
    /// deliberately narrow, fully-deterministic net that catches literal
    /// catchphrase reuse, the actual failure mode §10/§26 name, without
    /// pretending to detect semantic similarity it was never asked to
    /// detect).
    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first two words of a normalized text — a cheap, deterministic
    /// proxy for "opening phrase" (catches "Got it." vs "Got it—the
    /// earlier one." both opening the same way).
    private static func openingPhrase(_ text: String) -> String? {
        let words = normalized(text).split(separator: " ").prefix(2)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// - Parameter recentTexts: a BOUNDED window (the caller decides how
    ///   many recent turns to include — mirrors the same bounded-window
    ///   discipline `avoidingAny:` already uses elsewhere in this
    ///   codebase, never "all history ever spoken").
    public static func analyze(recentTexts: [String]) -> RepetitionMetrics {
        guard !recentTexts.isEmpty else { return .empty }
        var exactCounts: [String: Int] = [:]
        var openingCounts: [String: Int] = [:]
        for text in recentTexts {
            exactCounts[normalized(text), default: 0] += 1
            if let opening = openingPhrase(text) {
                openingCounts[opening, default: 0] += 1
            }
        }
        // "Repetition count" = total occurrences beyond the first for
        // each value that appears more than once (e.g. 3 identical texts
        // contribute 2 "repeats," not 3).
        let exactRepeats = exactCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
        let openingRepeats = openingCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
        let topExact = exactCounts.filter { $0.value > 1 }.max(by: { $0.value < $1.value })?.key
        let topOpening = openingCounts.filter { $0.value > 1 }.max(by: { $0.value < $1.value })?.key
        return RepetitionMetrics(
            exactRepetitionCount: exactRepeats, openingPhraseRepetitionCount: openingRepeats,
            mostRepeatedExactText: topExact, mostRepeatedOpeningPhrase: topOpening, sampleCount: recentTexts.count
        )
    }
}
