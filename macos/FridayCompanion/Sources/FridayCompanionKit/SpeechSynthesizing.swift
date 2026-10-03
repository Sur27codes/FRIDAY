import Foundation

/// How one synthesized utterance ended (P2-M5 §14: "each utterance
/// terminates exactly once"). `.interrupted` covers both an explicit
/// `stop()` call (barge-in, Stop/disable/shutdown) and the underlying
/// engine reporting its own cancellation — from `WakeCoordinator`'s
/// perspective they mean the same thing: no more audio will play for
/// this utterance, and it is not a failure.
public enum SpeechSynthesisOutcome: Sendable, Equatable {
    case finished
    case interrupted
    case failed(String)
}

/// Replaceable TTS engine abstraction (§5) — the speaking-side mirror of
/// `SpeechTranscribing`. Exactly two operations, because that is all a
/// bounded, single-utterance-at-a-time output adapter needs: start one
/// utterance, and stop whatever is currently playing (barge-in, Stop,
/// disable, shutdown, sleep). There is no `pause`/`resume` — §19's
/// barge-in contract is "stop immediately," never "pause and later
/// continue a half-spoken sentence."
///
/// `WakeCoordinator` never calls `speak` again for a given session until
/// the previous call's `onFinished` has fired (or `stop()` has forced
/// it) — implementations are not required to support two overlapping
/// in-flight utterances.
public protocol SpeechSynthesizing: Sendable {
    /// Speaks `text`, which the caller (`ResponsePresenting`'s output)
    /// has already bounded/sanitized, using bounded, deterministic
    /// prosody adjustments for `category` (P2-M5V §10) on top of
    /// whatever base voice/prosody this engine is configured with.
    /// `onFinished` is invoked exactly once for this call, on an
    /// arbitrary thread/queue, once the utterance finishes, is
    /// interrupted, or fails. Throws only if the engine could not even
    /// begin (e.g. no voice available) — in that case `onFinished` is
    /// never called for this attempt.
    func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws
    /// Immediately stops whatever utterance is currently playing — a
    /// harmless no-op if nothing is speaking. Per §21 this must produce
    /// audible silence, not merely mark internal state as stopped, and
    /// per §14 it must still deliver exactly one `onFinished(.interrupted)`
    /// for whatever utterance was in flight (never zero, never twice).
    func stop()
    /// A short, stable identifier for diagnostics (mirrors
    /// `SpeechTranscribing.engineIdentifier`) — e.g. the TTS engine name
    /// and voice identifier. Never response text.
    var engineIdentifier: String { get }
}

public extension SpeechSynthesizing {
    /// Convenience overload for callers that don't need category-
    /// specific prosody (every pre-P2-M5V call site) — defaults to
    /// `.information`, the calm/measured baseline category.
    func speak(_ text: String, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        try speak(text, category: .information, onFinished: onFinished)
    }
}

/// A synthesizer that never actually speaks — the P2-M5 analogue of
/// `NullSpeechTranscriber`/`NullWakeWordDetector`. Unlike those two,
/// there is no "wait for real hardware" concern for a null output
/// adapter: nothing plays, so nothing can fail or hang asynchronously.
/// `onFinished(.finished)` is delivered synchronously and truthfully —
/// "no TTS engine configured" trivially finishes immediately, rather
/// than requiring a caller-side backstop the way the real STT null
/// object does. Every pre-P2-M5 test, and any `WakeCoordinator`
/// constructed without a real synthesizer, behaves exactly as before:
/// `.speaking` is entered and immediately exited.
public struct NullSpeechSynthesizer: SpeechSynthesizing {
    public let engineIdentifier = "none (no TTS configured)"
    public init() {}
    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        onFinished(.finished)
    }
    public func stop() {}
}
