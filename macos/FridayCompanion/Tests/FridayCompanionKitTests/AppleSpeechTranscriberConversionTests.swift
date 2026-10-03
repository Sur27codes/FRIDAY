import Testing
@testable import FridayCompanionKit
import AVFoundation

/// P2-M4 §9 — the exact real `AudioFrame → AVAudioPCMBuffer` conversion
/// boundary `AppleSpeechTranscriber.append(_:)` uses, tested directly
/// (mirrors `RealAudioCaptureEngineConversionTests`' own reasoning: a
/// hand-built fixture bypassing the real conversion function is not
/// sufficient evidence). Requires no Speech-Recognition permission and
/// no live recognizer — this is pure data transformation.
@Suite struct AppleSpeechTranscriberConversionTests {

    @Test func convertsInt16SamplesToNormalizedFloat32Buffer() {
        let frame = AudioFrame(samples: [0, 16384, -16384, 32767, -32768], sampleRate: 48000, channelCount: 1)
        let buffer = AppleSpeechTranscriber.makeFloat32Buffer(from: frame)

        #expect(buffer != nil)
        #expect(buffer?.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer?.format.sampleRate == 48000)
        #expect(buffer?.frameLength == 5)

        let channel = buffer!.floatChannelData![0]
        #expect(channel[0] == 0.0)
        #expect(abs(channel[1] - 0.5) < 0.001)
        #expect(abs(channel[2] - (-0.5)) < 0.001)
        #expect(abs(channel[3] - 0.999969) < 0.001) // 32767/32768
        #expect(channel[4] == -1.0)
    }

    @Test func preservesRealHardwareSampleRate_48kHz() {
        // The exact rate confirmed on the owner's own Mac
        // (RealAudioCaptureEngine, post-P2-M3D) — the conversion must
        // not silently resample or assume 16kHz; that's sherpa-onnx's
        // job for KWS and the Speech framework's own internal job for
        // STT, not this function's.
        let frame = AudioFrame(samples: [1, 2, 3], sampleRate: 48000, channelCount: 1)
        let buffer = AppleSpeechTranscriber.makeFloat32Buffer(from: frame)
        #expect(buffer?.format.sampleRate == 48000)
    }

    @Test func emptyFrame_returnsNil() {
        let frame = AudioFrame(samples: [], sampleRate: 48000, channelCount: 1)
        #expect(AppleSpeechTranscriber.makeFloat32Buffer(from: frame) == nil)
    }

    @Test func nonInterleavedMono_singleChannel() {
        let frame = AudioFrame(samples: [Int16](repeating: 100, count: 1024), sampleRate: 48000, channelCount: 1)
        let buffer = AppleSpeechTranscriber.makeFloat32Buffer(from: frame)
        #expect(buffer?.format.channelCount == 1)
        #expect(buffer?.format.isInterleaved == false)
    }

    /// P2-M4D §8 — the owner's real hardware retest used AirPods Pro
    /// (24000 Hz, mono), not the 48kHz MacBook microphone P2-M4's
    /// original tests covered. The conversion function makes no
    /// hardcoded rate assumption, but this is proven directly rather
    /// than assumed, per the explicit instruction: "Do not assume
    /// Apple Speech receives a valid buffer... Add/confirm coverage for
    /// at least 48kHz mono Float32 and 24kHz mono Float32."
    @Test func preservesRealHardwareSampleRate_24kHzAirPods() {
        let frame = AudioFrame(samples: [1, 2, 3, 4], sampleRate: 24000, channelCount: 1)
        let buffer = AppleSpeechTranscriber.makeFloat32Buffer(from: frame)
        #expect(buffer?.format.sampleRate == 24000)
        #expect(buffer?.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer?.frameLength == 4)
    }
}
