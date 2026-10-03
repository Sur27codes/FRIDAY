import Foundation

/// Pure mapping from real `WakeCoordinator` state to what the menu bar
/// shows (§13/§40 of the P2-M3 authorization) — separated from
/// `MenuBarController` for the same testability reason
/// `MenuBarStateFormatter` already was in P2-M1: no AppKit dependency,
/// so the truthfulness property is unit-testable directly.
public struct WakeStatusDisplay: Equatable {
    public let microphoneLine: String
    public let wakeToggleTitle: String
    public let wakeToggleEnabled: Bool
}

public enum WakeStatusFormatter {
    public static func display(audioState: AudioState, unavailableReason: WakeUnavailableReason?) -> WakeStatusDisplay {
        let microphoneLine: String
        switch audioState {
        case .microphoneOff:
            microphoneLine = "Microphone: Off"
        case .wakeOnly:
            microphoneLine = "Microphone: Wake Listening"
        case .listening:
            // P2-M4 §18: renamed from "Listening (interaction)" now
            // that this state means something concrete — actively
            // capturing the spoken command after "Hey Friday" — rather
            // than P2-M3's placeholder "just wait then time out."
            microphoneLine = "Microphone: Command Listening"
        case .awaitingFollowUp:
            // P2-PROD-BOOTSTRAP-R2.8 §16 — truthfully distinct from both
            // "Wake Listening" (would falsely imply a wake word is
            // needed) and "Command Listening" (would falsely imply this
            // capture began with "Hey Friday"): active STT IS open here,
            // exactly like `.listening`, just without a fresh wake event.
            microphoneLine = "Microphone: Follow-up Listening"
        case .processing:
            microphoneLine = "Microphone: Processing"
        case .speaking:
            microphoneLine = "Microphone: Speaking"
        case .unavailable:
            microphoneLine = "Microphone: Unavailable — \(describe(unavailableReason))"
        }

        let wakeToggleTitle = (audioState == .microphoneOff) ? "Enable Wake (\"Hey Friday\")" : "Disable Wake"
        // Toggling is disabled while genuinely `.unavailable` for a
        // permission reason — re-enabling requires the user to fix the
        // OS permission first (§12: "do not repeatedly hammer permission
        // prompts"); a device error may still be worth retrying.
        let wakeToggleEnabled: Bool
        switch unavailableReason {
        case .microphonePermissionDenied, .microphonePermissionRestricted: wakeToggleEnabled = false
        default: wakeToggleEnabled = true
        }

        return WakeStatusDisplay(microphoneLine: microphoneLine, wakeToggleTitle: wakeToggleTitle, wakeToggleEnabled: wakeToggleEnabled)
    }

    private static func describe(_ reason: WakeUnavailableReason?) -> String {
        switch reason {
        case .none: return "unknown"
        case .microphonePermissionDenied: return "permission denied"
        case .microphonePermissionRestricted: return "permission restricted"
        case .deviceError(let detail): return "device error (\(detail))"
        case .detectorFailedToStart(let detail): return "wake engine unavailable (\(detail))"
        }
    }
}
