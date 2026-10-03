import Foundation

/// P2-M5-FINAL-CLOSURE-R1 §1.3 — the explicit production speech cascade.
///
/// Deliberately NOT two nested `FallbackSpeechSynthesizer`s: nesting
/// works out *mostly* correct given each engine's careful `.interrupted`
/// vs `.failed` discipline, but it double-counts the Samantha-fallback
/// diagnostic, has no single place that knows "how far down the cascade
/// are we / has playback begun / has a terminal result already gone
/// out", and would make any future fourth tier a guessing game. This
/// type is that single explicit state machine.
///
/// The one rule every tier transition obeys, unchanged from the 2-tier
/// `FallbackSpeechSynthesizer` it replaces:
///   - `.failed`  (or a synchronous throw from `speak`) → advance to the
///                 next tier. A tier only ever reports `.failed` when it
///                 could not produce ANY audible output.
///   - `.interrupted` → deliver `.interrupted` and STOP. This covers
///                 both barge-in AND a tier that began audible playback
///                 and then hit trouble (every engine here reports
///                 `.interrupted`, never `.failed`, once audio has
///                 started — see `PremiumNeuralSpeechSynthesizer` §39/§40
///                 and `LocalChatterboxSpeechSynthesizer`'s
///                 `onPlaybackComplete`). So a fallback is NEVER triggered
///                 merely because the user interrupted, and a response is
///                 NEVER replayed through a lower tier once any tier has
///                 started speaking it.
///   - `.finished` → deliver `.finished` and STOP.
///
/// Terminal delivery is exactly-once, lock-guarded, and stale-guarded by
/// a per-utterance id so a late callback from an already-superseded tier
/// can neither double-deliver nor resurrect the cascade.
public final class CascadingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let tiers: [SpeechSynthesizing]
    private let diagnostics: WakeDiagnosticsRecorder?

    private let lock = NSLock()
    private var inFlight: InFlight?

    private final class InFlight {
        let utteranceID: String
        var tierIndex: Int
        var terminalDelivered: Bool
        let onFinished: @Sendable (SpeechSynthesisOutcome) -> Void
        init(utteranceID: String, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) {
            self.utteranceID = utteranceID
            self.tierIndex = 0
            self.terminalDelivered = false
            self.onFinished = onFinished
        }
    }

    /// `tiers` in priority order. Production wiring passes exactly
    /// `[Cartesia, Chatterbox, Samantha]`; the last tier is treated as
    /// the emergency final tier for the Samantha-fallback diagnostic.
    public init(tiers: [SpeechSynthesizing], diagnostics: WakeDiagnosticsRecorder? = nil) {
        precondition(!tiers.isEmpty, "CascadingSpeechSynthesizer needs at least one tier")
        self.tiers = tiers
        self.diagnostics = diagnostics
    }

    public var engineIdentifier: String {
        "cascade[" + tiers.map(\.engineIdentifier).joined(separator: " -> ") + "]"
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        let utteranceID = UUID().uuidString
        let flight = InFlight(utteranceID: utteranceID, onFinished: onFinished)
        lock.lock(); inFlight = flight; lock.unlock()
        attemptTier(from: 0, text: text, category: category, utteranceID: utteranceID)
    }

    private func attemptTier(from index: Int, text: String, category: SpeechResponseCategory, utteranceID: String) {
        // Stale-guard: a callback that scheduled this attempt may have
        // raced a `stop()` / a newer utterance.
        lock.lock()
        guard let flight = inFlight, flight.utteranceID == utteranceID, !flight.terminalDelivered else {
            lock.unlock(); return
        }
        guard index < tiers.count else {
            lock.unlock()
            deliverTerminal(.failed("every speech tier failed to produce audible output"), utteranceID: utteranceID)
            return
        }
        flight.tierIndex = index
        let isEmergencyFinalTier = (index == tiers.count - 1) && tiers.count > 1
        let tier = tiers[index]
        lock.unlock()

        if isEmergencyFinalTier {
            diagnostics?.recordSamanthaFallback()
        }

        do {
            try tier.speak(text, category: category, onFinished: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .finished:
                    self.deliverTerminal(.finished, utteranceID: utteranceID)
                case .interrupted:
                    // Barge-in, OR a tier that had already begun audible
                    // playback and then stopped. Either way: never fall
                    // through, never replay.
                    self.deliverTerminal(.interrupted, utteranceID: utteranceID)
                case .failed:
                    self.attemptTier(from: index + 1, text: text, category: category, utteranceID: utteranceID)
                }
            })
        } catch {
            // Tier could not even begin (e.g. Chatterbox service socket
            // absent → `NotAvailableError`). Advance.
            attemptTier(from: index + 1, text: text, category: category, utteranceID: utteranceID)
        }
    }

    private func deliverTerminal(_ outcome: SpeechSynthesisOutcome, utteranceID: String) {
        lock.lock()
        guard let flight = inFlight, flight.utteranceID == utteranceID, !flight.terminalDelivered else {
            lock.unlock(); return
        }
        flight.terminalDelivered = true
        inFlight = nil
        let handler = flight.onFinished
        lock.unlock()
        handler(outcome)
    }

    public func stop() {
        // Snapshot then invalidate so any tier callback that fires as a
        // result of the `stop()` calls below is treated as stale.
        lock.lock()
        let flight = inFlight
        let utteranceID = flight?.utteranceID
        lock.unlock()

        // Stop every tier defensively — cheap, and guarantees no engine
        // is left with residual audio regardless of which tier was live.
        for tier in tiers { tier.stop() }

        // Guarantee exactly-one terminal `.interrupted` ourselves rather
        // than depending on a tier's own `stop()` to deliver it — the
        // same hardening P2-M5V9-B.2B applied to the Cartesia path.
        if let utteranceID {
            deliverTerminal(.interrupted, utteranceID: utteranceID)
        }
    }
}
