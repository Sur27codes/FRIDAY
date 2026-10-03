import Foundation

/// P2-M5V6 §14 — one bounded, structured record of a past interaction:
/// enough to answer "do it again" / "what about the other one" / "why" /
/// "continue" without unrestricted permanent memory. `transcript` is the
/// user's own words for that turn when known (may be `nil` — e.g. for a
/// turn this milestone's synchronous pipeline reasoned about without a
/// live transcript attached); it follows the SAME privacy discipline as
/// `WakeDiagnosticsSnapshot.lastTranscript` — held in process memory
/// here, never persisted to disk by this type, and this type performs no
/// logging of its own.
public struct ConversationTurn: Sendable, Equatable {
    public let taskID: String
    public let transcript: String?
    public let responseFamily: ResponseFamily
    public let responseText: String
    public let purpose: ResponsePurpose
    public let at: Date

    // MARK: - P2-M5V7 §17 Conversation Memory 2.0 (additive; every new field defaults so every pre-P2-M5V7 call site keeps compiling unchanged)

    /// What this turn's utterance actually WAS, per P2-M5V7's real
    /// dialogue-act classification — lets a future turn's reasoner
    /// resolve "again"/"that one"/"why" against a richer record than
    /// just the response family.
    public let dialogueAct: DialogueAct
    /// The social register this turn was actually delivered in — lets a
    /// future reasoner notice "the conversation has been casual" (§14's
    /// conservative user-style-matching idea) without re-deriving it.
    public let previousRegister: SocialRegister?
    /// The `ResponsePurpose` this turn's response strategy resolved to —
    /// kept alongside `purpose` (unchanged, same value) under the name
    /// §17 itself uses, purely for call-site clarity when reading turn
    /// history.
    public var previousResponseGoal: ResponsePurpose { purpose }

    // MARK: - P2-M5V8.1-S3 §4/§5/§10 (additive; every new field defaults so every pre-S3 call site keeps compiling unchanged)

    /// §4 — the CONTINUITY signal this turn actually carried, so a
    /// future turn can tell "the last turn was about the same subject"
    /// without re-deriving it from scratch each time.
    public let activeTopic: ActiveConversationTopic
    /// §5/§8 — the bounded drafting/editing context this turn left
    /// active, if any — `nil` when this turn wasn't about an artifact at
    /// all. Carrying this forward (not re-deriving it fresh from a bare
    /// "make it less formal") is exactly what lets a style refinement
    /// know WHAT it's refining.
    public let artifactContext: ArtifactContext?
    /// §10/§11/§28 — which conversational MOVE this turn's response
    /// actually made, kept for repetition-avoidance purposes (§28: "track
    /// bounded recent response features... avoid sequences like 'Got it.'
    /// 'Got it.' 'Got it.'") — never re-used for authority.
    public let pragmaticResponseAct: PragmaticResponseAct?

    public init(
        taskID: String, transcript: String?, responseFamily: ResponseFamily, responseText: String, purpose: ResponsePurpose,
        at: Date = Date(), dialogueAct: DialogueAct = .unknown, previousRegister: SocialRegister? = nil,
        activeTopic: ActiveConversationTopic = .none, artifactContext: ArtifactContext? = nil, pragmaticResponseAct: PragmaticResponseAct? = nil
    ) {
        self.taskID = taskID
        self.transcript = transcript
        self.responseFamily = responseFamily
        self.responseText = responseText
        self.purpose = purpose
        self.at = at
        self.dialogueAct = dialogueAct
        self.previousRegister = previousRegister
        self.activeTopic = activeTopic
        self.artifactContext = artifactContext
        self.pragmaticResponseAct = pragmaticResponseAct
    }
}

/// P2-M5V6 §14 — bounded conversational working memory. NOT unrestricted
/// permanent memory (§14's own explicit instruction): a fixed maximum
/// turn count, in-process only, reset on process restart, never written
/// to disk by this type.
public protocol ConversationMemoryStoring: Sendable {
    func recentTurns(limit: Int) -> [ConversationTurn]
    func record(_ turn: ConversationTurn)
    func reset()
}

public final class BoundedConversationMemory: ConversationMemoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ConversationTurn] = []
    private let maxTurns: Int

    public init(maxTurns: Int = 8) {
        self.maxTurns = max(1, maxTurns)
    }

    public func recentTurns(limit: Int) -> [ConversationTurn] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(turns.suffix(limit))
    }

    public func record(_ turn: ConversationTurn) {
        lock.lock(); defer { lock.unlock() }
        turns.append(turn)
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        turns.removeAll()
    }
}

/// Null-object counterpart — always empty, records nothing. Matches this
/// codebase's established Null-object convention for optional
/// subsystems.
public struct NullConversationMemory: ConversationMemoryStoring {
    public init() {}
    public func recentTurns(limit: Int) -> [ConversationTurn] { [] }
    public func record(_ turn: ConversationTurn) {}
    public func reset() {}
}
