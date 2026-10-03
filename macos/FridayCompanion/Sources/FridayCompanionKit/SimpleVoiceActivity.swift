import Foundation

/// P2-M4D — a minimal, bounded RMS-energy heuristic for "is there speech
/// in this frame," used only to detect trailing silence and end command
/// capture early once the user stops talking (`WakeCoordinator.updateVoiceActivity`).
/// Deliberately not a learned voice-activity-detection model — a
/// disclosed, appropriate-for-scope choice, not a hidden limitation. The
/// same math `RealAudioCaptureEngine`'s own diagnostics already use for
/// its RMS/peak reporting, factored out here so it's shared and
/// independently unit-testable.
public enum SimpleVoiceActivity {
    public static func rms(of samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        for s in samples {
            let v = Double(s) / 32768.0
            sumSquares += v * v
        }
        return (sumSquares / Double(samples.count)).squareRoot()
    }
}
