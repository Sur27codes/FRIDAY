import Foundation

/// P2-PROD-BOOTSTRAP-R2.8 §15 — a small, bounded, disclosed set of exact
/// phrases that explicitly close an already-open follow-up conversation
/// session, checked ONLY against an `.awaitingFollowUp` transcript (see
/// `WakeCoordinator.handleTranscriptionOutcome`). Deliberately not a
/// learned classifier and not a change to `DialogueAct`/the frozen
/// conversational brain — the same "simple, bounded, disclosed heuristic,
/// appropriate for this milestone's scope" shape
/// `WakeSessionConfig.voiceActivityThreshold` already establishes
/// elsewhere in this codebase. Matching is case-insensitive against the
/// transcript with leading/trailing whitespace and a single trailing
/// `.`/`!`/`?` stripped — never a substring/fuzzy match, so an answer
/// that merely CONTAINS one of these phrases mid-sentence (e.g. "and
/// that's all I wanted to check on the first point") is never
/// misclassified as a session-exit request.
public enum FollowUpSessionExitPhrases {
    private static let phrases: Set<String> = [
        "that's all",
        "thats all",
        "that's it",
        "thats it",
        "thanks friday that's all",
        "thanks friday that's it",
        "thank you friday that's all",
        "thank you friday that's it",
        "stop listening",
        "stop listening please",
        "we're done",
        "were done",
        "i'm done",
        "im done",
        "that will be all",
        "that'll be all",
        "no more questions",
        "nothing else",
        "nothing else thanks",
        "end conversation",
        "end session",
    ]

    public static func matches(_ transcript: String) -> Bool {
        var normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let last = normalized.last, ".!?".contains(last) {
            normalized.removeLast()
        }
        return phrases.contains(normalized)
    }
}
