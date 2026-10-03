import Foundation

/// P2-M5V8.1-P.1 / P.1A / P.1A.1 — a bounded, fully DETERMINISTIC local
/// classifier: given candidate text, does it CLAIM that FRIDAY itself
/// completed some action/mutation? This is classification ONLY — it never
/// decides whether the claim is TRUE (that remains `ActionExecutionState`,
/// computed exclusively from authoritative runtime evidence, untouched by
/// this type) and it never gains any new authority itself.
/// `ResponseValidation` combines this classification with the
/// authoritative truth to decide whether a candidate may be spoken.
///
/// Replaces brittle, closed phrase-list coverage (the previous approach —
/// `ResponseValidation.neverClaimsActionForNotRequested`/`executionSuccessClaimGuard`'s
/// own phrase tables, both PRESERVED unchanged and still consulted
/// alongside this detector, never replaced) with a bounded VERB-FAMILY +
/// CONSTRUCTION approach that generalizes across reasonable grammatical
/// variants without becoming a probabilistic/ML classifier.
///
/// P2-M5V8.1-P.1A.1 §0/§1/§2 — CLAUSE-AWARE. The original (P.1A) design
/// applied negation/modal/question exclusion SENTENCE-wide, which
/// over-suppressed a genuine completion claim sharing a sentence with an
/// unrelated exclusion marker ("I couldn't rename it, so I created a
/// copy." used to suppress "created" too, since "couldn't" was anywhere
/// in the same sentence). Text is now split into CLAUSES — on strong
/// punctuation (`;`, `:`, em/en dash, comma), on the coordinating/
/// contrastive words "but"/"however"/"yet"/"so"/"therefore", and — the
/// key generalization that also closes the trickier no-punctuation cases
/// ("I can confirm I sent it.") — whenever a FRESH subject pronoun ("i"/
/// "you"/"user") appears after a clause has already started, which is a
/// strong, bounded signal that a new proposition has begun even with no
/// punctuation at all. Negation/modal exclusion then applies only WITHIN
/// the clause containing the trigger, never bleeding across a genuine
/// clause boundary. Deliberately still NOT a real parser — no LLM (§15
/// of the mission that introduced this type), no embeddings, no
/// probabilistic model; every rule here is a bounded token/set operation.
public enum ExecutionClaimDetector {
    /// P.1A §3 — the required verb families, keyed by their PAST-TENSE/
    /// PAST-PARTICIPLE surface form(s) (irregulars get both explicitly;
    /// regular verbs' past tense and past participle are identical, so
    /// one entry covers both "I added" and "was added"). Deliberately
    /// does NOT include base/gerund forms — English's own grammar keeps
    /// modal/future constructions ("can add," "I'll add") on the BASE
    /// form, so this trigger choice alone already excludes most of §6's
    /// false-positive risk before any exclusion logic even runs.
    static let pastFormTriggers: Set<String> = [
        "added", "created", "wrote", "written", "sent", "deleted", "removed", "moved", "renamed",
        "saved", "updated", "changed", "edited", "modified", "uploaded", "downloaded", "installed",
        "opened", "closed", "started", "stopped", "restarted", "scheduled", "canceled", "cancelled",
        "booked", "ordered", "submitted", "applied", "synced", "restored", "shared", "archived",
        "trashed", "wiped",
        // P2-M5V8.1-P.1A.1 §8/§9 — "make/made," authorized because FRIDAY
        // genuinely creates artifacts (notes/drafts) this codebase already
        // realizes wording for elsewhere ("Created and verified note...");
        // "made" is a natural, materially-equivalent synonym for that same
        // family, not a new capability being invented. See this file's own
        // §9 vocabulary-audit tests for the full authorized/excluded list
        // and sourcing.
        "made",
    ]
    /// The one required verb family ("backup"/"backed up") that isn't a
    /// single token — matched as an exact bigram instead.
    private static let multiWordTriggers: [[String]] = [["backed", "up"]]

    /// §9 — a SMALL, bounded set of outcome-state adjectives that assert
    /// action state without an explicit verb ("Your note is ready.") —
    /// deliberately narrow so ordinary adjectives are never swept in.
    private static let resultStateAdjectives: Set<String> = ["ready", "complete", "live", "synced"]
    private static let copulas: Set<String> = ["is", "are", "was", "were"]
    /// P2-M5V8.1-R §6 — REAL, forensically-proven fix: a SMALL, deliberately
    /// bounded set of `pastFormTriggers` entries that are also ordinary,
    /// common ADJECTIVES with no verb-claim meaning at all in that sense
    /// ("ordered delivery," "an ordered list" — real evidence found "TCP
    /// ensures ordered, reliable delivery" false-positive rejected as if
    /// FRIDAY claimed to have ordered something; "hand-written rules" —
    /// real evidence, same run, found "written" as part of an ordinary
    /// compound adjective false-positive rejected the same way). Kept as
    /// its own tiny set, checked ONLY alongside
    /// `allowAmbiguousResultStateSubject` (never unconditionally) — every
    /// OTHER `pastFormTriggers` entry (created/deleted/sent/uploaded/etc.)
    /// has no comparable ordinary-adjective sense and keeps its full,
    /// unconditional protection regardless of subject ambiguity, exactly
    /// as before this pass. Disclosed as possibly not exhaustive — this
    /// is a real, evidence-driven list, not a speculative audit of every
    /// entry in `pastFormTriggers` for a theoretical adjective sense.
    private static let ambiguousAdjectiveHomographs: Set<String> = ["ordered", "written"]

    /// P.1A.1 §3/§4 — CLAUSE-LOCAL markers: presence anywhere WITHIN THE
    /// SAME CLAUSE (never the whole sentence — see clause segmentation
    /// below) vetoes every trigger in that clause only.
    private static let negationMarkers: Set<String> = ["not", "never", "unable", "n't"]
    private static let modalOrConditionalMarkers: Set<String> = [
        "can", "could", "will", "would", "should", "may", "might", "if", "try", "going", "want", "like", "supposed",
    ]
    /// §7 — local subject check: the NEAREST of these tokens scanning
    /// backward from a trigger WITHIN THE SAME CLAUSE, if found before
    /// any first-person "i," means the trigger's subject is the USER,
    /// not FRIDAY. Also doubles (§2) as a CLAUSE-BOUNDARY signal: any
    /// occurrence of one of these words after a clause has already begun
    /// starts a fresh clause, since a repeated/fresh subject pronoun is a
    /// strong, bounded signal of a new proposition even with zero
    /// punctuation between it and what came before.
    private static let userSubjectMarkers: Set<String> = ["you", "user"]
    private static let assistantSubjectMarkers: Set<String> = ["i"]
    private static var allSubjectMarkers: Set<String> { userSubjectMarkers.union(assistantSubjectMarkers) }

    /// P.1A.1 §2 — words that always END the current clause (dropped,
    /// never themselves examined as a trigger/exclusion word — a
    /// coordinating conjunction carries no claim content of its own).
    private static let clauseBoundaryWords: Set<String> = ["but", "however", "yet", "so", "therefore"]
    /// The sentinel `normalize(_:)` inserts in place of `;`, `:`, an
    /// em/en dash, or a comma — see that function's own doc comment.
    private static let clauseBreakSentinel = "clausebreak"

    /// §6 — subject-AUX INVERSION ("Was it deleted?", "Did you send it?")
    /// is English's own grammatical marker for a genuine question — a
    /// clause whose FIRST word is one of these or a short offer lead-in
    /// is treated as interrogative, regardless of whether the sentence
    /// happens to end with "?" (deliberately NOT keyed off trailing "?"
    /// at all — that literal-punctuation approach is exactly what let a
    /// genuine embedded declarative claim inside a question-framed
    /// sentence, "Did you want me to tell them I already sent it?", get
    /// silently swallowed in the P.1A design; clause segmentation already
    /// isolates "I already sent it" into its own clause, which never
    /// itself starts with an inversion word).
    private static let questionAuxWords: Set<String> = [
        "do", "does", "did", "was", "is", "are", "were", "can", "could", "will", "would", "should", "have", "has", "may", "might",
    ]
    private static let offerLeadIns: [[String]] = [["want", "me", "to"]]

    /// §14 — meaning-preserving contraction expansion ONLY (never a
    /// stemmer, never anything that could change which claim is being
    /// made).
    private static let contractions: [(String, String)] = [
        ("isn't", "is not"), ("wasn't", "was not"), ("aren't", "are not"), ("weren't", "were not"),
        ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"),
        ("can't", "can not"), ("cannot", "can not"), ("couldn't", "could not"),
        ("won't", "will not"), ("wouldn't", "would not"), ("shouldn't", "should not"),
        ("haven't", "have not"), ("hasn't", "have not"), ("hadn't", "had not"),
        ("i've", "i have"), ("i'm", "i am"), ("i'll", "i will"), ("i'd", "i would"),
        ("it's", "it is"), ("that's", "that is"), ("there's", "there is"), ("here's", "here is"),
        ("you've", "you have"), ("you're", "you are"), ("you'll", "you will"),
        ("we'd", "we would"), ("we've", "we have"), ("we'll", "we will"), ("we're", "we are"),
        ("wasn\u{2019}t", "was not"), ("didn\u{2019}t", "did not"), ("i\u{2019}ve", "i have"), ("it\u{2019}s", "it is"),
    ]

    /// P.1A.1 §2 — clause-boundary PUNCTUATION, injected as a spelled-out
    /// sentinel word BEFORE tokenization (tokenization itself discards
    /// all punctuation, so this is the only way a comma/semicolon/dash's
    /// position survives to influence clause segmentation).
    private static let clauseBreakPunctuation: [String] = [";", ":", "\u{2014}", "\u{2013}", ","]

    private static func normalize(_ text: String) -> String {
        var lower = text.lowercased()
        for (contraction, expansion) in contractions {
            lower = lower.replacingOccurrences(of: contraction, with: expansion)
        }
        for punct in clauseBreakPunctuation {
            lower = lower.replacingOccurrences(of: punct, with: " \(clauseBreakSentinel) ")
        }
        return lower
    }

    private static func sentences(_ text: String) -> [[String]] {
        let normalized = normalize(text)
        var result: [[String]] = []
        var current = ""
        for char in normalized {
            if char == "." || char == "!" || char == "?" {
                let words = current.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                if !words.isEmpty { result.append(words) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trailingWords = current.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        if !trailingWords.isEmpty { result.append(trailingWords) }
        return result
    }

    /// P.1A.1 §2 — splits one sentence's word list into clauses: ends the
    /// current clause at the punctuation sentinel or a coordinating
    /// conjunction (both DROPPED, never examined further), and also ends
    /// it — WITHOUT dropping the word — whenever a subject pronoun
    /// appears after the clause has already accumulated at least one
    /// word (§2's "and when a new explicit subject follows," generalized
    /// to catch the no-conjunction-at-all case too, e.g. "I can confirm
    /// I sent it.").
    private static func clauses(in words: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for word in words {
            if word == clauseBreakSentinel || clauseBoundaryWords.contains(word) {
                if !current.isEmpty { result.append(current) }
                current = []
                continue
            }
            // P.1A.1 §5 fix — do NOT split on a repeated subject when
            // everything accumulated so far is a single BARE conditional/
            // modal lead-in word ("if," "should," ...) with no verb of
            // its own yet: that word is introducing THIS subject, not
            // completing a separate independent clause before it. Fixes
            // a real regression this exact design change introduced:
            // "If I deleted it, we'd lose the backup." was splitting into
            // "If" / "I deleted it" — isolating "if" away from "deleted"
            // and silently un-suppressing a genuine non-claim.
            let isBareLeadIn = current.count == 1 && modalOrConditionalMarkers.contains(current[0])
            if allSubjectMarkers.contains(word), !current.isEmpty, !isBareLeadIn {
                result.append(current)
                current = [word]
                continue
            }
            current.append(word)
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [words] : result
    }

    private static func startsWithQuestionPattern(_ clause: [String]) -> Bool {
        guard let first = clause.first else { return false }
        if questionAuxWords.contains(first), clause.count >= 2 { return true }
        return offerLeadIns.contains { lead in clause.count >= lead.count && Array(clause.prefix(lead.count)) == lead }
    }

    /// - Parameter allowAmbiguousResultStateSubject: P2-M5V8.1-R §6 —
    ///   REAL, forensically-proven fix, default `false` (preserves every
    ///   pre-existing call site's exact behavior byte-for-byte). A
    ///   `resultStateAdjective` trigger ("is ready"/"is complete"/"is
    ///   live"/"is synced") with NO subject marker found nearby at all —
    ///   neither "I" nor "you"/"user" — defaults, per §7's own doc
    ///   comment below, to being treated as an implicit FRIDAY claim
    ///   ("passive voice / bare outcome report"). That default is correct
    ///   for a genuine artifact report ("The file is ready") but real
    ///   evidence found it ALSO firing on ordinary third-person
    ///   educational content with no FRIDAY-relevant subject at all
    ///   ("...the model is ready to make predictions" — describing a
    ///   general ML model, not anything FRIDAY touched). When `true`,
    ///   ONLY that specific ambiguous-subject/resultStateAdjective case is
    ///   no longer treated as a claim; an EXPLICIT assistant subject ("I")
    ///   or user subject ("you"/"user") nearby is completely unaffected —
    ///   still resolved exactly as before — and every `pastFormTriggers`/
    ///   multi-word verb trigger (a much stronger, capability-action-verb-
    ///   shaped signal — "created"/"sent"/"deleted"/etc. — genuinely
    ///   unrelated to what this mission's real evidence found broken) is
    ///   also completely unaffected, at every subject-ambiguity level.
    /// - Returns: `true` if `text` contains at least one CLAUSE where a
    ///   recognized completion trigger survives every clause-local
    ///   exclusion check (negation, modal/conditional, question,
    ///   user-as-subject).
    public static func claimsExecutionOrMutation(_ text: String, allowAmbiguousResultStateSubject: Bool = false) -> Bool {
        for sentence in sentences(text) {
            for clause in clauses(in: sentence) {
                guard !clause.isEmpty else { continue }
                let clauseSet = Set(clause)
                let hasNegation = !negationMarkers.isDisjoint(with: clauseSet)
                let hasModal = !modalOrConditionalMarkers.isDisjoint(with: clauseSet)
                let isQuestion = startsWithQuestionPattern(clause)
                if hasNegation || hasModal || isQuestion { continue }

                for (index, word) in clause.enumerated() {
                    let isResultStateAdjective = copulas.contains(word) && index + 1 < clause.count && resultStateAdjectives.contains(clause[index + 1])
                    let isAmbiguousHomograph = ambiguousAdjectiveHomographs.contains(word)
                    let isTrigger = pastFormTriggers.contains(word) || isResultStateAdjective
                    guard isTrigger else { continue }
                    let subject = nearestSubjectMarker(before: index, in: clause)
                    if subject == .user { continue }
                    if (isResultStateAdjective || isAmbiguousHomograph), allowAmbiguousResultStateSubject, subject == nil { continue }
                    return true
                }
                for bigram in multiWordTriggers {
                    guard let idx = firstIndex(of: bigram, in: clause) else { continue }
                    if nearestSubjectMarker(before: idx, in: clause) == .user { continue }
                    return true
                }
            }
        }
        return false
    }

    private enum SubjectMarkerKind { case user, assistant }

    /// §7 — scans backward from `index`, WITHIN the given clause only,
    /// for the nearest first-person or user-referring subject token.
    /// `nil` means no subject pronoun was found nearby at all (passive
    /// voice / bare outcome report, §8).
    private static func nearestSubjectMarker(before index: Int, in clause: [String]) -> SubjectMarkerKind? {
        var i = index - 1
        while i >= 0 {
            let word = clause[i]
            if assistantSubjectMarkers.contains(word) { return .assistant }
            if userSubjectMarkers.contains(word) { return .user }
            i -= 1
        }
        return nil
    }

    private static func firstIndex(of bigram: [String], in words: [String]) -> Int? {
        guard bigram.count == 2, words.count >= 2 else { return nil }
        for i in 0..<(words.count - 1) where words[i] == bigram[0] && words[i + 1] == bigram[1] { return i + 1 }
        return nil
    }
}
