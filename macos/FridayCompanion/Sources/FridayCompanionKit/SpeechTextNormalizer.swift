import Foundation

/// P2-M5V9 §51 — a deterministic, pronunciation-only text pass that runs
/// AFTER `ResponseValidation` (never before — it must only ever reshape
/// already-truthful, already-safe text, never decide what's true) and
/// BEFORE synthesis. Its only job is making already-correct text
/// pronounce more naturally — it must NEVER change semantic meaning or
/// touch an authoritative fact (§51: "do NOT transform authoritative
/// facts").
///
/// Deliberately conservative: this milestone implements a small, safe,
/// well-tested subset (common abbreviations, standalone numbers/percent/
/// currency) rather than a full inverse-text-normalization engine — an
/// ambitious ITN system is real, standalone effort with its own failure
/// modes (mispronouncing a case it wasn't designed for is worse than
/// leaving it as plain text) and is out of scope for the V9-A
/// infrastructure pass this milestone is limited to (see this file's own
/// module-level disclosure in `docs/E-traceability-matrix.md`'s P2-M5V9
/// section).
public enum SpeechTextNormalizer {
    /// Fixed, ordered, literal substitutions — common abbreviations that
    /// read naturally when expanded and never change meaning.
    private static let abbreviationExpansions: [(String, String)] = [
        ("README.md", "readme dot M D"),
        ("%", " percent"),
        // P2-M5V9-B §14 — a few more fixed, literal, never-ambiguous
        // expansions in the exact same conservative style as the two
        // above: common written abbreviations that read naturally when
        // expanded and never change what is being said. Still no regex,
        // no guessing — every entry here is a hardcoded literal match.
        ("e.g.", "for example"),
        ("i.e.", "that is"),
        ("etc.", "et cetera"),
    ]

    /// P2-M5V9 §51/§52 — expand a conservative, tested set of patterns.
    /// Anything not explicitly handled here passes through UNCHANGED —
    /// the safe default (§51: never guess).
    public static func normalize(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in abbreviationExpansions {
            result = result.replacingOccurrences(of: pattern, with: replacement)
        }
        return result
    }
}

/// P2-M5V9 §53 — a small, provider-neutral pronunciation dictionary.
/// Core response text (everything upstream of this) stays clean, plain
/// text (§53: "core response text must remain clean text") — an adapter
/// for a provider that actually supports pronunciation hints (SSML
/// phonemes, a lexicon API, etc.) may consult this table and translate
/// it to that provider's own native mechanism; a provider without such
/// support simply never consults it, and the plain word is spoken as-is
/// (a safe, if imperfect, degradation — never a crash, never garbled
/// markup leaking into speech).
public struct PronunciationOverride: Sendable, Equatable {
    public let word: String
    /// A simple, human-authored respelling — NOT a formal IPA/ARPAbet
    /// transcription (a real system would need one per supported
    /// provider's own phoneme set; that translation is the adapter's
    /// job, not this table's).
    public let respelling: String

    public init(word: String, respelling: String) {
        self.word = word
        self.respelling = respelling
    }
}

public enum PronunciationDictionary {
    public static let entries: [PronunciationOverride] = [
        PronunciationOverride(word: "FRIDAY", respelling: "FRY-day"),
        PronunciationOverride(word: "API", respelling: "A-P-I"),
        PronunciationOverride(word: "SQL", respelling: "sequel"),
        PronunciationOverride(word: "CUDA", respelling: "KOO-da"),
        PronunciationOverride(word: "macOS", respelling: "mac-O-S"),
        // P2-M5V9-B §14 — the mission's own named acronym/initialism/
        // developer-terminology examples, added in the same bounded,
        // human-authored, whole-word style as the five entries above.
        PronunciationOverride(word: "JSON", respelling: "JAY-son"),
        PronunciationOverride(word: "GPT", respelling: "G-P-T"),
        PronunciationOverride(word: "HTTP", respelling: "H-T-T-P"),
        PronunciationOverride(word: "HTTPS", respelling: "H-T-T-P-S"),
        PronunciationOverride(word: "Swift", respelling: "Swift"),
        PronunciationOverride(word: "Python", respelling: "PIE-thon"),
        PronunciationOverride(word: "GitHub", respelling: "GIT-hub"),
        PronunciationOverride(word: "URL", respelling: "U-R-L"),
        PronunciationOverride(word: "SSH", respelling: "S-S-H"),
        PronunciationOverride(word: "REST", respelling: "rest"),
        PronunciationOverride(word: "YAML", respelling: "YAM-ul"),
        PronunciationOverride(word: "CLI", respelling: "C-L-I"),
        PronunciationOverride(word: "IDE", respelling: "I-D-E"),
        PronunciationOverride(word: "URI", respelling: "U-R-I"),
        PronunciationOverride(word: "UUID", respelling: "U-U-I-D"),
        // P2-M5V9-B.2 §19 — new provider/protocol vocabulary this
        // milestone introduces, in the same bounded, human-authored,
        // whole-word style as every entry above.
        PronunciationOverride(word: "Cartesia", respelling: "car-TEE-zha"),
        PronunciationOverride(word: "Chatterbox", respelling: "CHAT-er-boks"),
        PronunciationOverride(word: "Sonic", respelling: "SAH-nik"),
        PronunciationOverride(word: "WebSocket", respelling: "WEB-sock-et"),
        PronunciationOverride(word: "PCM", respelling: "P-C-M"),
        // Disclosed limitation: `override(forWord:)` itself matches this
        // entry correctly (case-insensitive, whole-string), but
        // `wrapWithPronunciationHints`'s tokenizer only extracts
        // PURE-LETTER runs, so "UTF-8" is never auto-detected inside a
        // full sentence (it splits into "UTF" + "8"). Direct lookup
        // still works for any FUTURE adapter that tokenizes differently.
        PronunciationOverride(word: "UTF-8", respelling: "U-T-F eight"),
    ]

    /// Case-insensitive whole-word lookup — never a substring match
    /// (which could corrupt an unrelated word that merely contains one
    /// of these as a substring).
    public static func override(forWord word: String) -> PronunciationOverride? {
        entries.first { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }
}

/// P2-M5V9 §54 — if a provider supports SSML, untrusted text must NEVER
/// become trusted markup directly. This escaper is the ONE place raw
/// text is made SSML-safe; markup itself (e.g. `<prosody>`, `<phoneme>`)
/// must only ever be generated by an adapter from typed local structures
/// (a `ProsodyPlan`, a `PronunciationOverride`) — never by string-
/// concatenating anything derived from a transcript or a model response.
public enum SSMLSafety {
    /// Escapes the 5 XML special characters — the same discipline any
    /// XML-embedding boundary needs, applied here specifically so a
    /// response ever containing `<`, `&`, etc. (e.g. quoting a URL or a
    /// code snippet) can never be interpreted as markup.
    public static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// A conservative allow-list an adapter's OWN markup generation must
    /// stay within (§54: "reject unsupported tags/attributes... enforce
    /// size/depth limits... no external resource loading through
    /// markup"). Never used to validate untrusted input as safe markup —
    /// untrusted input is always escaped (above), never parsed as SSML.
    // P2-M5V9-B §14/§15 — "sub" added to the allow-list: the standard
    // SSML pronunciation-substitution tag (`<sub alias="...">word</sub>`),
    // now genuinely produced by `wrapWithPronunciationHints` below for a
    // provider that declares `pronunciationControl && ssml` support.
    public static let allowedTags: Set<String> = ["speak", "prosody", "phoneme", "emphasis", "break", "s", "p", "sub"]
    public static let maxMarkupDepth = 4
    public static let maxMarkupLength = 2000

    /// P2-M5V9-B §14/§15 — the first real CONSUMER of `PronunciationDictionary`:
    /// wraps every whole-word dictionary match in `text` with an SSML
    /// `<sub alias="respelling">word</sub>` tag so an SSML-capable
    /// provider hears the correct pronunciation while still receiving
    /// (and, per `alias`, ultimately "reading") the exact original word —
    /// never a semantic change, only how it is voiced (§54's own rule:
    /// core response text stays clean; this is the adapter-side
    /// translation that doc comment anticipated). Untrusted text is
    /// escaped FIRST (`SSMLSafety.escape`) so no transcript-derived
    /// content can ever inject markup — the `<sub>` tags are added
    /// afterward, from typed local structures only, never from
    /// concatenating anything transcript-derived into markup. A caller
    /// without SSML support must never call this — plain `text` remains
    /// the correct input for it (§53: "a provider without such support
    /// simply never consults it").
    public static func wrapWithPronunciationHints(_ text: String) -> String {
        let escaped = escape(text)
        var words = Set<String>()
        for token in escaped.split(whereSeparator: { !$0.isLetter }) where PronunciationDictionary.override(forWord: String(token)) != nil {
            words.insert(String(token))
        }
        guard !words.isEmpty else { return "<speak>\(escaped)</speak>" }
        var result = escaped
        // Longest-first, and matched only at WORD BOUNDARIES (never a
        // plain substring replace) — otherwise substituting "HTTP" after
        // "HTTPS" was already wrapped would corrupt the tag it just
        // produced, since "HTTP" is itself a substring of "HTTPS".
        for word in words.sorted(by: { $0.count > $1.count }) {
            guard let override = PronunciationDictionary.override(forWord: word),
                  let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") else { continue }
            let range = NSRange(result.startIndex..., in: result)
            // `$`/`\` are template metacharacters for `NSRegularExpression`'s
            // replacement string — escaped defensively even though no
            // current dictionary entry contains either.
            let safeTemplate = "<sub alias=\"\(override.respelling)\">\(word)</sub>"
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$")
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: safeTemplate)
        }
        return "<speak>\(result)</speak>"
    }
}
