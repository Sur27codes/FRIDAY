import AVFoundation
import Foundation

/// Real microphone capture via `AVAudioEngine`.
///
/// **P2-M3D root-cause note (real owner hardware test, 2026-08-24):** the
/// tap installed at `installTapAndStart()` uses `inputNode.inputFormat(forBus: 0)`
/// — the hardware's own native format — and on every real Mac checked so
/// far (confirmed on the owner's machine: `commonFormat = .pcmFormatFloat32`,
/// 48kHz, mono, non-interleaved) that format is **Float32, never Int16**.
/// The original version of this file only ever read
/// `buffer.int16ChannelData`, which is `nil` for a Float32-format buffer —
/// so the tap's `guard let channelData = buffer.int16ChannelData else {
/// return }` silently discarded **every real callback**, with no error, no
/// crash, and no visible symptom other than "Hey Friday" never being
/// detected. `capture.start()`/`detector.start()` both returned
/// successfully (nothing about starting the engine or the detector was
/// wrong), so the menu bar's "Wake Listening" status was truthful about
/// *those* two things while still being materially misleading about
/// whether any audio was actually reaching the detector — exactly the gap
/// `WakeDiagnostics` now closes. Fixed by `extractSamples(from:)` below,
/// which reads whichever channel-data accessor the buffer's actual format
/// supports and converts Float32 → the existing `AudioFrame.samples:
/// [Int16]` contract, so no downstream type changes.
public final class RealAudioCaptureEngine: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private var configChangeObserver: NSObjectProtocol?
    private let lock = NSLock()
    private let diagnostics: WakeDiagnosticsRecorder?

    public init(diagnostics: WakeDiagnosticsRecorder? = nil) {
        self.diagnostics = diagnostics
    }

    public func start(onFrame: @escaping @Sendable (AudioFrame) -> Void) throws {
        lock.lock()
        self.onFrame = onFrame
        lock.unlock()

        try installTapAndStart()

        // React to device changes (§23: AirPods/external mic
        // appearing/disappearing, default input changing) by tearing
        // down and re-installing the tap against whatever the new
        // default input node is — rather than crashing or silently
        // capturing from a now-invalid node.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.diagnostics?.recordDeviceChange()
            self.lock.lock()
            let callback = self.onFrame
            self.lock.unlock()
            guard let callback else { return }
            // Reconfiguration must not run on the notification's own
            // (potentially real-time-adjacent) thread; hop off it.
            DispatchQueue.global(qos: .utility).async {
                try? self.restartAfterConfigurationChange(onFrame: callback)
            }
        }
    }

    public func stop() {
        lock.lock()
        onFrame = nil
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        diagnostics?.recordEngineStopped()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = nil
    }

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDeviceAvailable
        }

        // Bounded buffer size — a fixed frame duration, never an
        // unbounded/accumulating buffer (§21). 1024 samples at a typical
        // 44.1/48kHz input is ~21-23ms per frame, a common, safe choice
        // for real-time audio taps.
        let bufferSize: AVAudioFrameCount = 1024

        let deviceName = Self.currentInputDeviceName()
        diagnostics?.recordEngineStarted(
            deviceName: deviceName, sampleRate: inputFormat.sampleRate, channelCount: Int(inputFormat.channelCount)
        )

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            // Real-time audio thread: keep this minimal (§22) — copy the
            // samples into a plain Swift array and hand off immediately.
            // The RMS/peak computation below is a single O(n) pass over
            // the already-copied array (no I/O, no allocation beyond the
            // array itself, no blocking) — the same real-time-safety bar
            // this file already held itself to before P2-M3D.
            guard let self else { return }
            self.lock.lock()
            let callback = self.onFrame
            self.lock.unlock()
            guard let callback, let samples = Self.extractSamples(from: buffer) else { return }

            if let diagnostics = self.diagnostics {
                var sumSquares: Double = 0
                var peak: Double = 0
                for s in samples {
                    let v = Double(s) / 32768.0
                    sumSquares += v * v
                    peak = max(peak, abs(v))
                }
                let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
                diagnostics.recordAudioCallback(sampleCount: samples.count, rms: rms, peak: peak)
            }

            callback(AudioFrame(
                samples: samples, sampleRate: inputFormat.sampleRate,
                channelCount: Int(inputFormat.channelCount), capturedAt: Date()
            ))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(String(describing: error))
        }
    }

    private func restartAfterConfigurationChange(onFrame: @escaping @Sendable (AudioFrame) -> Void) throws {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try installTapAndStart()
    }

    /// P2-M3D §6/§7 — the exact real capture/converter boundary, factored
    /// out as a pure, unit-testable function so a test can construct a
    /// real `AVAudioPCMBuffer` in the hardware's actual (Float32,
    /// non-interleaved) format and prove the conversion is correct,
    /// rather than only testing against a hand-built `AudioFrame` fixture
    /// that bypasses this boundary entirely (see
    /// `RealAudioCaptureEngineConversionTests`).
    ///
    /// Prefers `int16ChannelData` if the buffer's format happens to
    /// already be Int16 (defensive — costs nothing, some input devices
    /// or future macOS versions could in principle negotiate it), falls
    /// back to `floatChannelData` (the actual observed real-hardware
    /// format on every Mac checked so far), and returns `nil` only if
    /// neither accessor is available for the buffer's format — which
    /// should not happen for any PCM format AVAudioEngine actually
    /// negotiates for a microphone input node.
    static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Int16]? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        if let int16Data = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: int16Data[0], count: frameLength))
        }
        if let floatData = buffer.floatChannelData {
            let channel = floatData[0]
            var samples = [Int16]()
            samples.reserveCapacity(frameLength)
            for i in 0..<frameLength {
                let clamped = max(-1.0, min(1.0, channel[i]))
                samples.append(Int16(clamped * 32767.0))
            }
            return samples
        }
        return nil
    }

    /// Best-effort device name for diagnostics only (§15) — never used
    /// for any behavioral decision, only surfaced in
    /// `WakeDiagnosticsSnapshot`/printed developer-mode output.
    static func currentInputDeviceName() -> String {
        #if os(macOS)
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        #else
        "unknown"
        #endif
    }
}
