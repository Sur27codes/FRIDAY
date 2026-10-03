import AVFoundation
import Foundation

/// Real, local, on-device text-to-speech via `AVSpeechSynthesizer`
/// (ADR-009 in `docs/W-adr-backlog.md`, confirmed with a real
/// implementation during P2-M5 — the same "resolved provisional ->
/// confirmed" progression ADR-008 went through at P2-M4).
///
/// Voice selection (§6/§7): defaults to `AVSpeechSynthesisVoice(language:)`
/// for the given locale rather than a hardcoded voice identifier — this
/// is Apple's own "resolve to whatever default voice is already
/// installed for this language" API. Confirmed on this development
/// machine (`swift -e` probe against the real `AVFoundation` framework,
/// not assumed) to resolve `"en-US"` to
/// `com.apple.voice.compact.en-US.Samantha` — a "compact" quality voice
/// that ships with the OS, requiring no additional voice-asset download
/// (§6: "do not claim offline without verifying actual runtime
/// behavior" — this is the verified claim). If a caller supplies a
/// specific `voiceIdentifier` that is not installed on this machine,
/// this falls back to the language default rather than throwing or
/// silently producing no audio (§6: "fallback behavior when preferred
/// voice unavailable" must be documented and safe).
///
/// P2-M5V: voice/prosody configuration moved into `VoiceProfile` — this
/// adapter now consumes one immutable profile rather than two loose
/// parameters, and applies `SpeechResponseCategory`-specific bounded
/// prosody deltas (`VoiceProfile.adjusted(for:)`) per utterance.
public final class AVSpeechSynthesizerAdapter: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public let engineIdentifier: String

    private let synthesizer = AVSpeechSynthesizer()
    private let profile: VoiceProfile
    private let lock = NSLock()
    private var onFinished: (@Sendable (SpeechSynthesisOutcome) -> Void)?
    private var delivered = false

    /// - Parameter profile: the base voice/prosody configuration
    ///   (§4/§5). Defaults to `.friday` — the P2-M5V starting candidate,
    ///   explicitly NOT a final owner-approved voice (see that static
    ///   property's own doc comment).
    public init(profile: VoiceProfile = .friday) {
        self.profile = profile
        let fallbackDescription: String
        if let id = profile.voiceIdentifier {
            fallbackDescription = id
        } else if profile.preferredGenderFallback != .unspecified {
            let genderLabel = (profile.preferredGenderFallback == .female) ? "female" : "male"
            fallbackDescription = "best-\(genderLabel)-\(profile.language)"
        } else {
            fallbackDescription = "default-\(profile.language)"
        }
        self.engineIdentifier = "avspeechsynthesizer (\(fallbackDescription))"
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished handler: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        lock.lock()
        onFinished = handler
        delivered = false
        lock.unlock()

        let effective = profile.adjusted(for: category)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(identifier: effective.voiceIdentifier, locale: effective.language, preferredGender: effective.preferredGenderFallback)
        utterance.rate = effective.rate
        utterance.pitchMultiplier = effective.pitchMultiplier
        utterance.volume = effective.volume
        utterance.preUtteranceDelay = effective.preUtteranceDelay
        utterance.postUtteranceDelay = effective.postUtteranceDelay
        synthesizer.speak(utterance)
    }

    public func stop() {
        // `stopSpeaking` is a harmless no-op if nothing is currently
        // speaking (Apple's documented behavior — returns `false`,
        // never throws/crashes). `deliverOnce` guarantees whatever
        // utterance WAS in flight gets its exactly-once `.interrupted`
        // callback even if the delegate's own `didCancel` never fires or
        // fires later than this call returns.
        synthesizer.stopSpeaking(at: .immediate)
        deliverOnce(.interrupted)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deliverOnce(.finished)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Normally already suppressed by `stop()` above having delivered
        // `.interrupted` itself first — this exists only as a backstop
        // for a cancellation this adapter didn't initiate itself.
        deliverOnce(.interrupted)
    }

    private func deliverOnce(_ outcome: SpeechSynthesisOutcome) {
        lock.lock()
        guard !delivered, let handler = onFinished else { lock.unlock(); return }
        delivered = true
        onFinished = nil
        lock.unlock()
        handler(outcome)
    }

    /// `public` (P2-M5V): the standalone `VoiceAuditionTool` target needs
    /// this exact resolution logic too, so the audition tool and
    /// production speak the same voice for the same `VoiceProfile`
    /// rather than risking two independent, potentially-diverging
    /// implementations of "how do we pick a voice."
    ///
    /// P2-M5V2 §7 — three-tier fallback, in order: (1) the exact
    /// `identifier` if given and actually installed; (2) if
    /// `preferredGender` is not `.unspecified`, the best-quality
    /// installed voice matching both `locale` and that gender (so
    /// losing a specific voice degrades to "still female, still
    /// en-US, just a different one" rather than jumping straight to
    /// whatever gender the bare language default happens to be); (3)
    /// the plain language default. A real, direct probe against this
    /// machine's framework found `AVSpeechSynthesisVoice(language: nil)`
    /// does NOT reliably return "the" system default (it returned an
    /// unrelated en-IN voice in testing here) — so that API is
    /// deliberately NOT used as a fourth tier; tier (3) has never
    /// returned `nil` for any real BCP-47 language code tried in this
    /// project, and if some future locale genuinely has zero installed
    /// voices, leaving `AVSpeechUtterance.voice` as `nil` lets
    /// `AVSpeechSynthesizer` apply its own OS-level default — still
    /// "never crash," just not a claim this function makes for itself.
    public static func resolveVoice(identifier: String?, locale: String, preferredGender: AVSpeechSynthesisVoiceGender = .unspecified) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        if preferredGender != .unspecified, let genderMatch = bestQualityVoice(language: locale, gender: preferredGender) {
            return genderMatch
        }
        return AVSpeechSynthesisVoice(language: locale)
    }

    /// The highest-`quality` installed voice for an exact `language`
    /// code and `gender` — `nil` if none is installed at all (a real,
    /// possible outcome this sandbox itself hits for some language/
    /// gender combinations; callers must not assume a match always
    /// exists).
    static func bestQualityVoice(language: String, gender: AVSpeechSynthesisVoiceGender) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language && $0.gender == gender }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}
