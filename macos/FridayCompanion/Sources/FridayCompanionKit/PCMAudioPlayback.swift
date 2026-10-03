import AVFoundation
import Foundation

/// P2-M5V9-B.3B §1 — the playback layer this whole codebase never had:
/// every prior premium-voice milestone (V9-A through B.3A) delivered
/// PCM bytes into `AudioChunkBuffer` and stopped there — disclosed
/// repeatedly as "no AVAudioEngine consumer of the buffer exists yet."
/// This is that consumer, built once so both the local Chatterbox path
/// (this milestone) and any FUTURE Cartesia/other PCM-emitting provider
/// can reuse the SAME real playback code rather than each inventing its
/// own ad-hoc player (§1: "do not create a completely separate ad-hoc
/// audio player").
public protocol PCMAudioPlaying: Sendable {
    /// Plays raw PCM `data` shaped exactly as `format` describes.
    /// `onPlaybackStarted` fires once playback has been handed to the
    /// audio engine; `onPlaybackComplete(true)` fires when the buffer
    /// finishes playing NATURALLY, `onPlaybackComplete(false)` if it
    /// could not be decoded/played at all or was stopped before
    /// completion. Exactly one completion call per `play`.
    func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void)
    /// Immediately halts whatever is currently playing — a harmless
    /// no-op if nothing is. Any pending `onPlaybackComplete` for the
    /// stopped playback still fires exactly once, with `false`.
    func stop()
}

/// The real, working implementation — `AVAudioEngine` + `AVAudioPlayerNode`,
/// no third-party dependency. Chatterbox delivers ONE complete waveform
/// per utterance (§4: "if Chatterbox cannot provide true incremental
/// audio... report that honestly" — it cannot; this player is honest
/// about that too, see `LocalChatterboxSpeechSynthesizer`'s own timing
/// disclosure), so this type schedules exactly one buffer per `play` call
/// — it is not itself a streaming/chunked player, though nothing here
/// would prevent a FUTURE caller from calling `play` again with
/// additional buffers before the first completes, for a genuinely
/// streaming provider.
public final class AVAudioEnginePCMPlayer: PCMAudioPlaying, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let lock = NSLock()
    /// Regenerated on every `play`/`stop` — the same "supersede the old
    /// generation" pattern `UtteranceIdentityGuard` already uses
    /// elsewhere in this codebase, so a completion callback for a buffer
    /// `stop()` already superseded can never fire twice or fire stale.
    private var currentGeneration = UUID()
    private var pendingCompletion: (@Sendable (Bool) -> Void)?

    public init() {
        engine.attach(playerNode)
    }

    public func play(_ data: Data, format: AudioFormatDescriptor, onPlaybackStarted: @escaping @Sendable () -> Void, onPlaybackComplete: @escaping @Sendable (Bool) -> Void) {
        guard let avFormat = Self.avAudioFormat(for: format) else {
            onPlaybackComplete(false)
            return
        }
        guard let buffer = Self.pcmBuffer(from: data, format: avFormat) else {
            onPlaybackComplete(false)
            return
        }

        let generation = UUID()
        lock.lock()
        currentGeneration = generation
        pendingCompletion = onPlaybackComplete
        lock.unlock()

        do {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
            if !engine.isRunning { try engine.start() }
        } catch {
            lock.lock(); pendingCompletion = nil; lock.unlock()
            onPlaybackComplete(false)
            return
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.deliverCompletion(forGeneration: generation, completedNaturally: true)
        }
        playerNode.play()
        onPlaybackStarted()
    }

    public func stop() {
        lock.lock()
        currentGeneration = UUID() // invalidates any in-flight completion callback
        let completion = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        playerNode.stop()
        completion?(false)
    }

    private func deliverCompletion(forGeneration generation: UUID, completedNaturally: Bool) {
        lock.lock()
        guard currentGeneration == generation, let completion = pendingCompletion else { lock.unlock(); return }
        pendingCompletion = nil
        lock.unlock()
        completion(completedNaturally)
    }

    private static func avAudioFormat(for descriptor: AudioFormatDescriptor) -> AVAudioFormat? {
        let commonFormat: AVAudioCommonFormat
        if descriptor.sampleFormat.contains("f32") {
            commonFormat = .pcmFormatFloat32
        } else if descriptor.sampleFormat.contains("s16") {
            commonFormat = .pcmFormatInt16
        } else {
            return nil // §10 of this milestone: unsupported format rejected safely, never guessed
        }
        guard descriptor.sampleRate > 0, descriptor.channelCount > 0 else { return nil }
        return AVAudioFormat(commonFormat: commonFormat, sampleRate: Double(descriptor.sampleRate), channels: AVAudioChannelCount(descriptor.channelCount), interleaved: descriptor.interleaved)
    }

    private static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, !data.isEmpty, data.count % bytesPerFrame == 0 else { return nil }
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            if let floatChannel = buffer.floatChannelData {
                let source = rawBuffer.bindMemory(to: Float.self)
                floatChannel[0].update(from: source.baseAddress!, count: Int(frameCount))
            } else if let int16Channel = buffer.int16ChannelData {
                let source = rawBuffer.bindMemory(to: Int16.self)
                int16Channel[0].update(from: source.baseAddress!, count: Int(frameCount))
            }
        }
        return buffer
    }
}
