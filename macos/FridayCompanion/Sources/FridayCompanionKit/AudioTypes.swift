import Foundation

/// One bounded chunk of PCM audio, in whatever format the capture layer
/// and wake detector have agreed on (§7 of the P2-M3 authorization: "the
/// capture layer should provide bounded PCM frames in the exact format
/// the wake engine requires"). `samples` is always a fixed, small count
/// — never an unbounded/growing buffer (§21).
public struct AudioFrame: Sendable {
    public let samples: [Int16]
    public let sampleRate: Double
    public let channelCount: Int
    public let capturedAt: Date

    public init(samples: [Int16], sampleRate: Double, channelCount: Int, capturedAt: Date = Date()) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capturedAt = capturedAt
    }
}

/// The narrow internal wake event contract (§28) — deliberately excludes
/// anything resembling authorization, an AAL/assurance claim, a
/// capability selection, a Policy decision, raw audio, or arbitrary user
/// command text. A `WakeEvent` means exactly one thing: "the configured
/// phrase was detected at this moment" — nothing more.
public struct WakeEvent: Equatable, Sendable {
    public let eventID: String
    public let sessionID: String
    public let phraseID: String
    public let detectedAt: Date
    public let source: String
    public let engine: String
    public let confidence: Double?

    public init(eventID: String, sessionID: String, phraseID: String, detectedAt: Date, source: String, engine: String, confidence: Double?) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.phraseID = phraseID
        self.detectedAt = detectedAt
        self.source = source
        self.engine = engine
        self.confidence = confidence
    }
}

/// The Phase-2-wide audio privacy state set
/// (`docs/PERSISTENT-AMBIENT-AND-CINEMATIC-INTERACTION-ARCHITECTURE.md`
/// §11), scoped to what P2-M3 actually drives. `.processing`/`.speaking`
/// are declared now so the state type doesn't need to change shape when
/// P2-M4/P2-M5 add real behavior for them, but nothing in this milestone
/// ever produces them (§8: "do not mark PROCESSING/SPEAKING operational
/// before their later milestones").
public enum AudioState: Equatable, Sendable {
    case microphoneOff
    case wakeOnly
    case listening(sessionID: String)
    case processing
    case speaking
    case unavailable
    /// P2-PROD-BOOTSTRAP-R2.8 — a bounded, wake-word-free continuation of
    /// an already-open conversation, entered ONLY after real audible
    /// playback of the previous response has finished (never merely
    /// after provider/synthesis completion — see
    /// `WakeCoordinatorEngine.transition`'s `.speechFinished` case).
    /// Behaves identically to `.listening` for frame routing/STT capture
    /// (same transcriber session, same VAD/trailing-silence rules) — the
    /// separate case exists so the menu bar can truthfully distinguish
    /// "listening because you just said the wake word" from "listening
    /// because we're mid-conversation and no wake word is needed" (§16),
    /// and so a dedicated, speech-aware inactivity window (distinct from
    /// `.listening`'s own absolute backstop) can end the session if the
    /// user says nothing at all.
    case awaitingFollowUp(sessionID: String)
}

extension AudioState {
    /// True for any state where frames are actively routed to the STT
    /// transcriber rather than the wake detector — `.listening` (a fresh
    /// wake-triggered command) and `.awaitingFollowUp` (a follow-up turn
    /// inside an already-open session) are behaviorally identical here;
    /// only their provenance/UI label differs.
    public var isActivelyCapturingSpeech: Bool {
        switch self {
        case .listening, .awaitingFollowUp: return true
        default: return false
        }
    }
}
