import Testing
@testable import FridayCompanionKit
import AVFoundation

/// P2-M3D §6/§7 — the exact real capture/converter boundary that a
/// hand-built `AudioFrame` fixture bypasses entirely. This is the test
/// that would have caught the real P2-M3D root cause: a real Mac's
/// microphone input node negotiates `AVAudioCommonFormat.pcmFormatFloat32`
/// (confirmed on the owner's own hardware: 48kHz, mono, non-interleaved),
/// and the pre-fix implementation only ever read `buffer.int16ChannelData`
/// — `nil` for a Float32 buffer — so every real callback was silently
/// dropped with no error, no crash, and "Microphone: Wake Listening"
/// still shown truthfully about capture/detector *startup* while zero
/// audio ever actually reached the detector.
///
/// These tests construct real `AVAudioPCMBuffer` instances (not fakes)
/// in exactly that Float32 format and drive them through
/// `RealAudioCaptureEngine.extractSamples(from:)` — the same function the
/// production tap callback calls — so a regression here (e.g. someone
/// reintroducing an `int16ChannelData`-only read) fails immediately.
@Suite struct RealAudioCaptureEngineConversionTests {

    private func makeFloat32Buffer(sampleRate: Double = 48000, channelCount: AVAudioChannelCount = 1, samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() { channel[i] = s }
        return buffer
    }

    @Test func float32Buffer_matchingRealHardwareFormat_convertsToCorrectInt16Samples() {
        // This is the exact format observed on the owner's real Mac
        // (`AVAudioEngine.inputNode.inputFormat(forBus: 0)`:
        // commonFormat = .pcmFormatFloat32, 48000Hz, mono,
        // non-interleaved) — the format the pre-fix code silently could
        // not read at all.
        let buffer = makeFloat32Buffer(samples: [0.0, 0.5, -0.5, 1.0, -1.0])
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)

        #expect(samples != nil, "must extract samples from a real hardware-format (Float32) buffer, not just Int16")
        #expect(samples?.count == 5)
        #expect(samples?[0] == 0)
        #expect(samples?[1] == Int16(0.5 * 32767.0))
        #expect(samples?[2] == Int16(-0.5 * 32767.0))
        #expect(samples?[3] == 32767, "full-scale positive must map to Int16.max, not overflow")
        #expect(samples?[4] == -32767)
    }

    @Test func float32Buffer_outOfRangeValues_areClampedNotOverflowed() {
        // Real microphone hardware should never produce out-of-[-1,1]
        // samples, but a defensive conversion must not crash or wrap on
        // a value that somehow exceeds the range (e.g. a
        // format-negotiation edge case) — `Int16(1.5 * 32767)` would
        // trap without clamping.
        let buffer = makeFloat32Buffer(samples: [1.5, -1.5, 2.0, -2.0])
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)
        #expect(samples == [32767, -32767, 32767, -32767])
    }

    @Test func float32Buffer_silence_producesAllZeroSamples() {
        let buffer = makeFloat32Buffer(samples: [Float](repeating: 0, count: 1024))
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)
        #expect(samples?.allSatisfy { $0 == 0 } == true)
        #expect(samples?.count == 1024)
    }

    @Test func emptyBuffer_returnsNil_notEmptyArray() {
        let buffer = makeFloat32Buffer(samples: [])
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)
        #expect(samples == nil, "a zero-length buffer should be treated as no frame, matching the original guard's intent")
    }

    @Test func int16Buffer_stillWorks_defensivePath() {
        // Defensive coverage for the (currently unobserved on any real
        // Mac, but not impossible) case where the negotiated format IS
        // already Int16 — the fixed code must still handle it directly
        // rather than only working by accident via the Float32 path.
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let channel = buffer.int16ChannelData![0]
        channel[0] = 100; channel[1] = -100; channel[2] = 32767; channel[3] = -32768
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)
        #expect(samples == [100, -100, 32767, -32768])
    }

    @Test func multiChannelBuffer_readsOnlyFirstChannel_matchingExistingConvention() {
        // Matches the pre-existing single-channel-extraction convention
        // (`channelData[0]`) already used before P2-M3D — verified
        // explicitly here so a future change to stereo handling is a
        // deliberate decision, not an accident.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for i in 0..<3 { left[i] = 0.5; right[i] = -0.9 }
        let samples = RealAudioCaptureEngine.extractSamples(from: buffer)
        #expect(samples == [Int16(0.5 * 32767.0), Int16(0.5 * 32767.0), Int16(0.5 * 32767.0)], "must read the left/first channel, not the right")
    }
}
