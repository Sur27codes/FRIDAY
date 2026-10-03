import Testing
@testable import FridayCompanionKit

/// P2-PROD-BOOTSTRAP §B18 — first-run UX logic tests. All synthetic —
/// no real config file, no real Keychain, no real permission API.
@Suite struct FirstRunSetupTests {
    private let grantedPermissions = PermissionSnapshot(microphone: .granted, speechRecognition: .granted)
    private let deniedMicPermissions = PermissionSnapshot(microphone: .requiresSystemSettings, speechRecognition: .granted)
    private let notDeterminedPermissions = PermissionSnapshot(microphone: .notDetermined, speechRecognition: .notDetermined)

    private var configuredSettings: ProductionSettings {
        var s = ProductionSettings.safeDefault
        s.conversationProvider = "friday-daemon"
        s.voiceProvider = "cartesia"
        return s
    }

    @Test func missingConversationCredential_setupShown() {
        let state = determineSetupState(settings: configuredSettings, conversationCredentialExists: false, voiceCredentialExists: true, permissions: grantedPermissions)
        guard case .setupRequired(let missing) = state else { Issue.record("expected setupRequired"); return }
        #expect(missing.contains(.conversationCredential))
    }

    @Test func missingCartesiaCredential_advisoryOnly_notBlocking() {
        // §A3: voice-provider absence degrades gracefully to Samantha —
        // it must NOT force the blocking setup screen.
        let state = determineSetupState(settings: configuredSettings, conversationCredentialExists: true, voiceCredentialExists: false, permissions: grantedPermissions)
        guard case .ready(let gaps) = state else { Issue.record("expected ready (voice credential is advisory, not blocking), got \(state)"); return }
        #expect(gaps.contains(.voiceCredential))
    }

    @Test func validSavedCredentialsAndConfig_setupDoesNotAppearUnnecessarily() {
        let state = determineSetupState(settings: configuredSettings, conversationCredentialExists: true, voiceCredentialExists: true, permissions: grantedPermissions)
        #expect(state == .ready(nonBlockingGaps: []))
    }

    @Test func deniedMicrophone_truthfulActionableState() {
        let state = determineSetupState(settings: configuredSettings, conversationCredentialExists: true, voiceCredentialExists: true, permissions: deniedMicPermissions)
        guard case .setupRequired(let missing) = state else { Issue.record("expected setupRequired"); return }
        #expect(missing.contains(.microphonePermission))
    }

    @Test func deniedSpeechRecognition_truthfulActionableState() {
        let permissions = PermissionSnapshot(microphone: .granted, speechRecognition: .requiresSystemSettings)
        let state = determineSetupState(settings: configuredSettings, conversationCredentialExists: true, voiceCredentialExists: true, permissions: permissions)
        guard case .setupRequired(let missing) = state else { Issue.record("expected setupRequired"); return }
        #expect(missing.contains(.speechRecognitionPermission))
    }

    @Test func freshInstall_everythingMissing_allBlockingItemsReported() {
        let state = determineSetupState(settings: .safeDefault, conversationCredentialExists: false, voiceCredentialExists: false, permissions: notDeterminedPermissions)
        guard case .setupRequired(let missing) = state else { Issue.record("expected setupRequired"); return }
        #expect(missing.contains(.conversationProvider))
        #expect(missing.contains(.conversationCredential))
        #expect(missing.contains(.microphonePermission))
        #expect(missing.contains(.speechRecognitionPermission))
        // Voice items are NEVER reported as part of the BLOCKING list.
        #expect(!missing.contains(.voiceProvider))
        #expect(!missing.contains(.voiceCredential))
    }

    @Test func noSilentLoop_setupStateIsDeterministicPureFunction() {
        // Calling the same inputs twice must yield the identical result
        // — no hidden mutable state, no silent retry loop.
        let state1 = determineSetupState(settings: configuredSettings, conversationCredentialExists: false, voiceCredentialExists: true, permissions: grantedPermissions)
        let state2 = determineSetupState(settings: configuredSettings, conversationCredentialExists: false, voiceCredentialExists: true, permissions: grantedPermissions)
        #expect(state1 == state2)
    }

    @Test func requirementDisplayNames_areHumanReadable_neverEmpty() {
        for requirement in SetupRequirement.allCases {
            #expect(!requirement.displayName.isEmpty)
        }
    }

    @Test func connectivityCheckResult_neverClaimsFullSuccessImplicitly() {
        let result = ConnectivityCheckResult(checkName: "Cartesia reachability", succeeded: true, sanitizedDetail: "HTTP 200")
        // Structural: this type only ever describes ONE named check —
        // it has no "allFeaturesWork" field to accidentally set true.
        let mirror = Mirror(reflecting: result)
        #expect(Set(mirror.children.compactMap(\.label)) == ["checkName", "succeeded", "sanitizedDetail"])
    }
}
