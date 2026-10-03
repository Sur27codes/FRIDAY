import Foundation

/// P2-M4 §12 — validation applied to every raw STT result before it is
/// allowed anywhere near `RuntimeClient`. Deliberately pure and
/// standalone (no dependency on `WakeCoordinator` or any engine type) so
/// it is trivially unit-testable and auditable on its own: this is the
/// ENTIRE set of transformations ever applied to spoken text before
/// submission — trim whitespace, enforce a maximum length, reject
/// emptiness. Nothing here rewrites wording, corrects grammar, or
/// otherwise changes what the user said (§12: "do not silently rewrite
/// semantic meaning").
public enum TranscriptValidation {
    /// Generous enough for any real spoken command this milestone's
    /// grammar needs ("create a note saying <up to a few sentences>"),
    /// small enough to bound `RuntimeClient`/daemon request size and
    /// reject a runaway/garbage transcript rather than forward it.
    public static let maxLength = 500

    public enum Failure: Error, Equatable, Sendable {
        case empty
        case tooLong(actual: Int, max: Int)
    }

    /// Returns the trimmed, validated transcript, or the specific reason
    /// it was rejected. The only transformation applied on success is
    /// whitespace/newline trimming — the rest of the text is preserved
    /// exactly as the STT engine produced it.
    public static func validate(_ raw: String) -> Result<String, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong(actual: trimmed.count, max: maxLength)) }
        return .success(trimmed)
    }
}
