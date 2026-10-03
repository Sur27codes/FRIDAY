import AVFoundation
import Foundation

/// Shared WAV-fixture loading for anything that needs to feed real audio
/// through a `WakeWordDetecting` conformance outside of live microphone
/// capture — `WakeEvalTool` (the P2-M3C measurement harness) and
/// `SherpaOnnxWakeWordDetectorTests` (the `swift test`-integrated
/// version of the same evaluation) both use this rather than duplicating
/// `AVAudioFile` handling. Not part of the production wake pipeline
/// itself — `RealAudioCaptureEngine` is what production audio actually
/// flows through.
public enum WakeAudioFixture {
    public static func loadMonoInt16PCM(from url: URL) throws -> (samples: [Int16], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SherpaOnnxWakeWordError.modelResourceNotFound("could not allocate PCM buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)

        var samples: [Int16] = []
        let n = Int(buffer.frameLength)
        if let int16Data = buffer.int16ChannelData {
            samples = Array(UnsafeBufferPointer(start: int16Data[0], count: n))
        } else if let floatData = buffer.floatChannelData {
            samples = (0..<n).map { i in Int16(max(-1.0, min(1.0, floatData[0][i])) * 32767.0) }
        }
        return (samples, format.sampleRate)
    }

    /// Feeds `samples` through a fresh detector lifecycle
    /// (`start()`→`process()`×N→`stop()`), appending 1s of trailing
    /// silence first — see `SherpaOnnxWakeWordDetectorTests` for why:
    /// the streaming model only finalizes a trigger after observing
    /// trailing non-speech audio, which continuous live listening
    /// provides for free but a short fixture file does not.
    public static func runDetection(
        samples: [Int16], sampleRate: Double, detector: WakeWordDetecting, frameSize: Int = 1024
    ) throws -> (triggered: Bool, event: WakeEvent?, audioMsAtTrigger: Double?) {
        let padded = samples + [Int16](repeating: 0, count: Int(sampleRate))
        try detector.start()
        defer { detector.stop() }

        var offset = 0
        while offset < padded.count {
            let end = min(offset + frameSize, padded.count)
            let frame = AudioFrame(samples: Array(padded[offset..<end]), sampleRate: sampleRate, channelCount: 1, capturedAt: Date())
            if let event = detector.process(frame, sessionID: "fixture") {
                return (true, event, Double(end) / sampleRate * 1000.0)
            }
            offset = end
        }
        return (false, nil, nil)
    }
}
