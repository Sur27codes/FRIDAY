import Foundation

/// P2-M5V8.1-P.2 §11 — a bounded, DETERMINISTIC, NON-AUTHORITATIVE
/// diagnostic: counts distinct information requests in a piece of text.
/// Exists because a bare `"?"` count treats "What caused the delay, and
/// what's the revised timeline?" as ONE information request when it is
/// actually two — silently hiding a real compound-question realization
/// defect from any diagnostic that only counted punctuation. Never used
/// for gating/rejection (§13: "Do NOT reject provider output merely
/// because two information requests are detected" — this is a quality/
/// realization-improvement signal only, never fed into
/// `ResponseValidation`). No model call, no embeddings — a bounded
/// lexical heuristic, same discipline as `RepetitionMetrics`/
/// `ExecutionClaimDetector`.
public enum QuestionDiagnostics {
    private static let whQuestionStarters: Set<String> = ["what", "who", "when", "where", "why", "how", "which", "whose"]

    /// - Returns: the number of distinct information-request clauses in
    ///   `text`. Each `?`-terminated sentence counts as AT LEAST one; a
    ///   sentence containing more than one wh-question word (a compound
    ///   question joined by "and"/a comma, e.g. "What caused the delay,
    ///   and what's the revised timeline?") counts as that many.
    public static func informationRequestCount(_ text: String) -> Int {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!")).filter { !$0.isEmpty }
        var count = 0
        for sentence in sentences where sentence.contains("?") {
            let lower = sentence.lowercased()
            let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
            let whStarterOccurrences = words.filter { whQuestionStarters.contains($0) }.count
            count += max(1, whStarterOccurrences)
        }
        return count
    }

    /// Convenience boolean for harness printing — `true` whenever more
    /// than one distinct information request was detected.
    public static func compoundQuestionDetected(_ text: String) -> Bool {
        informationRequestCount(text) > 1
    }
}
