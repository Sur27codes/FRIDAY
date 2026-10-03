import Foundation

/// P2-M5V9 §31 — a typed description of what a premium provider ACTUALLY
/// supports, queried/configured rather than assumed. An adapter for a
/// provider lacking a given capability must gracefully degrade (§31:
/// "do not silently request unsupported controls") — e.g. a provider
/// with `nativeProsody == false` falls back to the existing rate/pitch/
/// volume-only `VoiceProfile` adjustment instead of a richer style call.
public struct PremiumSpeechCapabilities: Sendable, Equatable {
    public let streaming: Bool
    public let cancellation: Bool
    public let nativeProsody: Bool
    public let speakingStyles: Bool
    public let pronunciationControl: Bool
    public let ssml: Bool
    public let wordTimestamps: Bool
    public let sentenceTimestamps: Bool
    public let sampleRates: [Int]
    public let audioFormats: [String]
    public let voiceSelection: Bool
    public let customVoice: Bool
    public let localeSupport: [String]

    public init(
        streaming: Bool, cancellation: Bool, nativeProsody: Bool, speakingStyles: Bool, pronunciationControl: Bool,
        ssml: Bool, wordTimestamps: Bool, sentenceTimestamps: Bool, sampleRates: [Int], audioFormats: [String],
        voiceSelection: Bool, customVoice: Bool, localeSupport: [String]
    ) {
        self.streaming = streaming
        self.cancellation = cancellation
        self.nativeProsody = nativeProsody
        self.speakingStyles = speakingStyles
        self.pronunciationControl = pronunciationControl
        self.ssml = ssml
        self.wordTimestamps = wordTimestamps
        self.sentenceTimestamps = sentenceTimestamps
        self.sampleRates = sampleRates
        self.audioFormats = audioFormats
        self.voiceSelection = voiceSelection
        self.customVoice = customVoice
        self.localeSupport = localeSupport
    }

    /// The safe, zero-capability default — used whenever no real provider
    /// is configured, so any capability check against it correctly
    /// degrades to "not supported" rather than crashing or guessing.
    public static let none = PremiumSpeechCapabilities(
        streaming: false, cancellation: false, nativeProsody: false, speakingStyles: false, pronunciationControl: false,
        ssml: false, wordTimestamps: false, sentenceTimestamps: false, sampleRates: [], audioFormats: [],
        voiceSelection: false, customVoice: false, localeSupport: []
    )
}

/// P2-M5V9 §72 — a stable, versioned identity for a production voice
/// selection, deliberately NOT a mutable display name ("Ava") — enables
/// rollback/reproducible testing/migration (§72's own explicit rationale).
public struct PremiumVoiceProfile: Sendable, Equatable {
    public let voiceProfileID: String
    public let providerID: String
    public let providerVoiceID: String
    public let profileVersion: String

    public init(voiceProfileID: String, providerID: String, providerVoiceID: String, profileVersion: String) {
        self.voiceProfileID = voiceProfileID
        self.providerID = providerID
        self.providerVoiceID = providerVoiceID
        self.profileVersion = profileVersion
    }
}

/// P2-M5V9 §32 — the typed request contract; provider-specific SDK types
/// stay behind the adapter, never leaking into `WakeCoordinator`/
/// presentation logic (§32's own "keep provider-specific SDK/types
/// outside core FRIDAY presentation logic").
public struct SpeechSynthesisRequest: Sendable, Equatable {
    public let interactionID: String
    public let utteranceID: String
    public let text: String
    public let voiceID: String
    public let language: String
    public let prosody: ProsodyPlan
    public let outputFormatPreference: String?

    public init(interactionID: String, utteranceID: String, text: String, voiceID: String, language: String, prosody: ProsodyPlan, outputFormatPreference: String? = nil) {
        self.interactionID = interactionID
        self.utteranceID = utteranceID
        self.text = text
        self.voiceID = voiceID
        self.language = language
        self.prosody = prosody
        self.outputFormatPreference = outputFormatPreference
    }
}

/// P2-M5V9 §32/§41 — one lifecycle event for one utterance's synthesis.
/// `audioChunk` deliberately carries `Data` (already-decoded/normalized
/// PCM, per §34 — never a provider-specific undecoded blob) plus the
/// SAME `interactionID`/`utteranceID` the request carried, so a consumer
/// can verify freshness on every single chunk (§33), not just once at
/// the start.
public enum SpeechSynthesisEvent: Sendable, Equatable {
    case started(interactionID: String, utteranceID: String)
    case audioChunk(interactionID: String, utteranceID: String, samples: Data, sequence: Int)
    case metadata(interactionID: String, utteranceID: String, description: String)
    case completed(interactionID: String, utteranceID: String)
    case failed(interactionID: String, utteranceID: String, category: SpeechProviderFailureCategory)
    case cancelled(interactionID: String, utteranceID: String)

    public var interactionID: String {
        switch self {
        case .started(let id, _), .audioChunk(let id, _, _, _), .metadata(let id, _, _), .completed(let id, _), .failed(let id, _, _), .cancelled(let id, _): return id
        }
    }

    public var utteranceID: String {
        switch self {
        case .started(_, let id), .audioChunk(_, let id, _, _), .metadata(_, let id, _), .completed(_, let id), .failed(_, let id, _), .cancelled(_, let id): return id
        }
    }
}

/// P2-M5V9 §47 — sanitized failure categories. Normal spoken output NEVER
/// exposes any of these strings (§47: "normal user speech must not
/// expose internal provider jargon") — they exist for diagnostics and
/// for `ProviderCircuitBreaker`'s own classification (auth/config
/// failures are never treated as transient, per §46).
public enum SpeechProviderFailureCategory: Sendable, Equatable {
    case configuration
    case authentication
    case authorization
    case quota
    case rateLimit
    case network
    case timeout
    case server
    case unsupportedVoice
    case unsupportedFormat
    case invalidResponse
    case decodeFailure
    case streamInterrupted
    case cancelled
    case unknown

    /// §46: authentication/authorization/configuration failures are
    /// permanent for this session (retrying won't help until the owner
    /// fixes configuration) — the circuit breaker should open
    /// immediately rather than waiting for repeated failures.
    public var isPermanentUntilReconfigured: Bool {
        switch self {
        case .configuration, .authentication, .authorization: return true
        default: return false
        }
    }
}

/// P2-M5V9 §34 — an explicit description of one PCM audio buffer's
/// shape, so provider audio is never assumed to already match whatever
/// macOS output format happens to be in use. `AudioFormatValidator` (see
/// `PremiumAudioPipeline.swift`) is the one place format checks/rejection
/// happen.
public struct AudioFormatDescriptor: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    /// e.g. "pcm_s16le", "pcm_f32le" — a short, explicit label; never
    /// inferred silently from byte count alone.
    public let sampleFormat: String
    public let interleaved: Bool

    public init(sampleRate: Int, channelCount: Int, sampleFormat: String, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
    }
}
