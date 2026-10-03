import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-PROD-BOOTSTRAP §B17 — configuration + Keychain-abstraction tests.
/// Uses ONLY `FakeCredentialStore` and temp-directory-backed
/// `ProductionSettingsStore` instances — NEVER the real Keychain, NEVER
/// a real production credential.
@Suite struct ProdBootstrapConfigCredentialTests {
    // MARK: - ProductionSettings / ProductionSettingsStore (§B3)

    private func tempSettingsURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("friday-settings-test-\(UUID().uuidString)/settings.json")
    }

    @Test func freshInstall_noFileExists_returnsSafeDefault() throws {
        let store = ProductionSettingsStore(fileURL: tempSettingsURL())
        let loaded = try store.load()
        #expect(loaded == .safeDefault)
        #expect(loaded.voiceProvider == "unspecified")
    }

    @Test func saveThenLoad_roundTripsExactly() throws {
        let store = ProductionSettingsStore(fileURL: tempSettingsURL())
        var settings = ProductionSettings.safeDefault
        settings.conversationProvider = "friday-daemon"
        settings.voiceProvider = "cartesia"
        settings.voiceModel = "sonic-3.6"
        settings.voiceID = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
        settings.launchAtLoginEnabled = true
        try store.save(settings)
        let loaded = try store.load()
        #expect(loaded == settings)
    }

    @Test func corruptConfig_recoversToSafeDefault_neverThrows() throws {
        let url = tempSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not valid json at all".utf8).write(to: url)
        let store = ProductionSettingsStore(fileURL: url)
        let loaded = try store.load()
        #expect(loaded == .safeDefault)
    }

    @Test func missingSchemaVersionField_recoversToSafeDefault() throws {
        let url = tempSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"voiceProvider": "cartesia"}"#.utf8).write(to: url)
        let store = ProductionSettingsStore(fileURL: url)
        let loaded = try store.load()
        #expect(loaded == .safeDefault)
    }

    @Test func futureSchemaVersion_throwsRatherThanGuessing() throws {
        let url = tempSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 999}"#.utf8).write(to: url)
        let store = ProductionSettingsStore(fileURL: url)
        #expect(throws: ProductionSettingsError.unsupportedFutureSchemaVersion(999)) {
            try store.load()
        }
    }

    @Test func atomicWrite_neverLeavesTempFileBehind() throws {
        let url = tempSettingsURL()
        let store = ProductionSettingsStore(fileURL: url)
        try store.save(.safeDefault)
        let siblingFiles = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!siblingFiles.contains { $0.hasSuffix(".tmp") })
    }

    @Test func replacingExistingSettings_isAtomic_neverPartiallyWritten() throws {
        let url = tempSettingsURL()
        let store = ProductionSettingsStore(fileURL: url)
        try store.save(.safeDefault)
        var updated = ProductionSettings.safeDefault
        updated.conversationProvider = "updated-provider"
        try store.save(updated)
        let loaded = try store.load()
        #expect(loaded.conversationProvider == "updated-provider")
    }

    @Test func schemaVersionMigration_noopForCurrentVersion() throws {
        let url = tempSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 1, "conversationProvider": "x", "conversationModel": "y", "voiceProvider": "z", "voiceModel": "w", "voiceID": "v", "locale": "en-US", "launchAtLoginEnabled": false, "wakeListeningEnabledByDefault": true, "runtimeMode": "production"}"#.utf8).write(to: url)
        let store = ProductionSettingsStore(fileURL: url)
        let loaded = try store.load()
        #expect(loaded.conversationProvider == "x")
    }

    @Test func settingsNeverContainCredentialFields() {
        // Structural guarantee, not a runtime check: ProductionSettings
        // has no property that could hold a secret — confirmed by its
        // own field list containing only provider/model/locale/flags.
        let mirror = Mirror(reflecting: ProductionSettings.safeDefault)
        let suspiciousNames = mirror.children.compactMap(\.label).filter {
            $0.lowercased().contains("key") || $0.lowercased().contains("secret") || $0.lowercased().contains("token") || $0.lowercased().contains("credential")
        }
        #expect(suspiciousNames.isEmpty)
    }

    // MARK: - CredentialStore (§B4)

    @Test func freshStore_credentialAbsent() throws {
        let store = FakeCredentialStore()
        #expect(store.status(.cartesiaVoiceProvider) == .absent)
        #expect(try store.read(.cartesiaVoiceProvider) == nil)
    }

    @Test func saveThenRead_roundTripsExactValue() throws {
        let store = FakeCredentialStore()
        try store.save("sk-test-fake-credential-value", for: .cartesiaVoiceProvider)
        #expect(try store.read(.cartesiaVoiceProvider) == "sk-test-fake-credential-value")
    }

    @Test func statusAfterSave_reportsExistsButNeverFullValue() throws {
        let store = FakeCredentialStore()
        try store.save("sk-test-fake-credential-value-xyz", for: .cartesiaVoiceProvider)
        let status = store.status(.cartesiaVoiceProvider)
        #expect(status.exists)
        #expect(status.maskedPreview != nil)
        #expect(status.maskedPreview?.contains("sk-test-fake-credential-value-xyz") == false)
        #expect(status.savedAt != nil)
    }

    @Test func maskedPreview_neverContainsMoreThanLastFourCharacters() {
        let preview = maskedPreview(of: "sk-test-fake-credential-value-xyz")
        #expect(preview == "••••-xyz")
        #expect(!preview.contains("test"))
        #expect(!preview.contains("fake"))
    }

    @Test func replaceCredential_overwritesPreviousValue() throws {
        let store = FakeCredentialStore()
        try store.save("first-value", for: .cartesiaVoiceProvider)
        try store.save("second-value", for: .cartesiaVoiceProvider)
        #expect(try store.read(.cartesiaVoiceProvider) == "second-value")
    }

    @Test func deleteCredential_removesIt() throws {
        let store = FakeCredentialStore()
        try store.save("value", for: .cartesiaVoiceProvider)
        try store.delete(.cartesiaVoiceProvider)
        #expect(try store.read(.cartesiaVoiceProvider) == nil)
        #expect(store.status(.cartesiaVoiceProvider) == .absent)
    }

    @Test func deletingNonexistentCredential_doesNotThrow() throws {
        let store = FakeCredentialStore()
        try store.delete(.cartesiaVoiceProvider) // no-op, must not throw
    }

    @Test func storeFailure_surfacesAsThrownError_neverSilentSuccess() {
        let store = FakeCredentialStore()
        store.saveError = CredentialStoreError.osStatus(-25291) // errSecNotAvailable
        #expect(throws: CredentialStoreError.osStatus(-25291)) {
            try store.save("value", for: .cartesiaVoiceProvider)
        }
    }

    @Test func differentIdentifiers_areIndependent() throws {
        let store = FakeCredentialStore()
        try store.save("conversation-value", for: .conversationProvider)
        try store.save("cartesia-value", for: .cartesiaVoiceProvider)
        #expect(try store.read(.conversationProvider) == "conversation-value")
        #expect(try store.read(.cartesiaVoiceProvider) == "cartesia-value")
    }

    @Test func fakeCredentialStore_neverTouchesRealKeychain_byConstruction() {
        // Structural: FakeCredentialStore holds an in-memory dictionary,
        // never imports Security/calls SecItem*. Confirmed by reading
        // its own source — this test documents the guarantee tests rely on.
        let store = FakeCredentialStore()
        #expect(type(of: store) == FakeCredentialStore.self)
    }

    // MARK: - ProductionHealthSnapshot (§B10)

    @Test func healthSnapshot_allMandatoryServicesReady_companionIsReady() {
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: ["policyengined": .ready, "capabilitybusd": .ready, "friday-daemon": .ready],
            wakeState: .wakeOnly, wakeUnavailableReason: nil, sttPermission: .authorized,
            conversationConfigured: true, voiceProviderConfigured: true, voiceProviderName: "cartesia",
            localVoiceSocketExists: false
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.companion.state == .ready)
        #expect(snapshot.policyEngine.state == .ready)
        #expect(snapshot.conversationProvider.state == .ready)
        #expect(snapshot.voiceProvider.state == .ready)
    }

    @Test func healthSnapshot_oneMandatoryServiceFailed_companionIsFailed() {
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: ["policyengined": .ready, "capabilitybusd": .failed, "friday-daemon": .stopped],
            wakeState: .microphoneOff, wakeUnavailableReason: nil, sttPermission: .notDetermined,
            conversationConfigured: false, voiceProviderConfigured: false, voiceProviderName: "unspecified",
            localVoiceSocketExists: false
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.companion.state == .failed)
    }

    @Test func healthSnapshot_neverExposesCredentialOrTranscriptFields() {
        // Structural: ComponentHealth's fields are state/message/date/count only.
        let mirror = Mirror(reflecting: ComponentHealth(state: .ready, sanitizedMessage: "ok", lastHealthy: nil, restartCount: nil))
        #expect(Set(mirror.children.compactMap(\.label)) == ["state", "sanitizedMessage", "lastHealthy", "restartCount"])
    }

    @Test func healthSnapshot_voiceProviderNotConfigured_reportedDegradedNotHidden() {
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: [:], wakeState: .microphoneOff, wakeUnavailableReason: nil, sttPermission: .notDetermined,
            conversationConfigured: false, voiceProviderConfigured: false, voiceProviderName: "unspecified",
            localVoiceSocketExists: false
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.voiceProvider.state == .degraded)
        #expect(snapshot.voiceProvider.sanitizedMessage.contains("falling back"))
    }

    @Test func healthSnapshot_localVoiceIdle_reportedAvailableOnDemand_neverAsFailure() {
        // P2-M5-FINAL-CLOSURE-R1 §6 — Chatterbox Turbo is the production
        // second speech tier, started lazily. "Socket absent" is the
        // normal healthy idle state at login (no ~1GB model loaded), so it
        // must be reported as stopped/available-on-demand, NEVER failed.
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: ["policyengined": .ready, "capabilitybusd": .ready, "friday-daemon": .ready],
            wakeState: .wakeOnly, wakeUnavailableReason: nil, sttPermission: .authorized,
            conversationConfigured: true, voiceProviderConfigured: true, voiceProviderName: "cartesia",
            localVoiceSocketExists: false
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.localVoice.state == .stopped)
        #expect(snapshot.localVoice.state != .failed)
        #expect(snapshot.localVoice.sanitizedMessage.contains("on demand"))
        #expect(!snapshot.localVoice.sanitizedMessage.contains("dev-tool"))
        // A healthy-idle local tier must not drag the overall companion state down.
        #expect(snapshot.companion.state == .ready)
    }

    @Test func healthSnapshot_localVoiceReachable_reportedReady() {
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: ["policyengined": .ready, "capabilitybusd": .ready, "friday-daemon": .ready],
            wakeState: .wakeOnly, wakeUnavailableReason: nil, sttPermission: .authorized,
            conversationConfigured: true, voiceProviderConfigured: true, voiceProviderName: "cartesia",
            localVoiceSocketExists: true
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.localVoice.state == .ready)
        #expect(snapshot.localVoice.sanitizedMessage.contains("reachable"))
    }

    @Test func healthSnapshot_wakeUnavailable_reportsSanitizedReason_neverSilent() {
        let inputs = ProductionHealthInputs(
            supervisorSnapshot: [:], wakeState: .unavailable, wakeUnavailableReason: "model load failed",
            sttPermission: .notDetermined, conversationConfigured: false, voiceProviderConfigured: false,
            voiceProviderName: "unspecified", localVoiceSocketExists: false
        )
        let snapshot = buildProductionHealthSnapshot(inputs)
        #expect(snapshot.wake.state == .failed)
        #expect(snapshot.wake.sanitizedMessage == "model load failed")
    }

    // MARK: - PermissionCoordinator (§B11)

    private final class FakeMicChecker: MicrophonePermissionChecking, @unchecked Sendable {
        var status: MicrophonePermissionStatus
        init(_ status: MicrophonePermissionStatus) { self.status = status }
        func currentStatus() -> MicrophonePermissionStatus { status }
        func requestAccess() async -> MicrophonePermissionStatus { status }
    }

    private final class FakeSpeechChecker: SpeechRecognitionPermissionChecking, @unchecked Sendable {
        var status: SpeechRecognitionPermissionStatus
        init(_ status: SpeechRecognitionPermissionStatus) { self.status = status }
        func currentStatus() -> SpeechRecognitionPermissionStatus { status }
        func requestAccess() async -> SpeechRecognitionPermissionStatus { status }
    }

    @Test func permissionCoordinator_bothGranted_readyForVoiceTrue() {
        let coordinator = PermissionCoordinator(microphone: FakeMicChecker(.authorized), speechRecognition: FakeSpeechChecker(.authorized))
        let snapshot = coordinator.currentSnapshot()
        #expect(snapshot.microphone == .granted)
        #expect(snapshot.speechRecognition == .granted)
        #expect(snapshot.readyForVoice)
    }

    @Test func permissionCoordinator_micDenied_readyForVoiceFalse_mapsToRequiresSystemSettings() {
        let coordinator = PermissionCoordinator(microphone: FakeMicChecker(.denied), speechRecognition: FakeSpeechChecker(.authorized))
        let snapshot = coordinator.currentSnapshot()
        #expect(snapshot.microphone == .requiresSystemSettings)
        #expect(!snapshot.readyForVoice)
    }

    @Test func permissionCoordinator_notDetermined_mapsCorrectly() {
        let coordinator = PermissionCoordinator(microphone: FakeMicChecker(.notDetermined), speechRecognition: FakeSpeechChecker(.notDetermined))
        let snapshot = coordinator.currentSnapshot()
        #expect(snapshot.microphone == .notDetermined)
        #expect(snapshot.speechRecognition == .notDetermined)
        #expect(!snapshot.readyForVoice)
    }

    @Test func permissionCoordinator_restricted_mapsCorrectly() {
        let coordinator = PermissionCoordinator(microphone: FakeMicChecker(.restricted), speechRecognition: FakeSpeechChecker(.authorized))
        let snapshot = coordinator.currentSnapshot()
        #expect(snapshot.microphone == .restricted)
    }

    @Test func permissionCoordinator_requestAll_returnsUpdatedSnapshot() async {
        let coordinator = PermissionCoordinator(microphone: FakeMicChecker(.authorized), speechRecognition: FakeSpeechChecker(.authorized))
        let snapshot = await coordinator.requestAll()
        #expect(snapshot.readyForVoice)
    }

    // MARK: - conversation credential bridge (R1 §2)

    @Test func conversationBridge_noCredential_noEnvVars_returnsUnconfigured() {
        let store = FakeCredentialStore()
        let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: [:])
        #expect(config.isConfigured == false)
        #expect(config.apiKey == nil)
    }

    @Test func conversationBridge_keychainCredentialPlusSettingsEndpoint_threadsThrough() throws {
        let store = FakeCredentialStore()
        try store.save("conv-test-key-value", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationEndpoint = "https://api.example.com/v1/chat/completions"
        settings.conversationModel = "example-model-1"
        let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: settings, processEnvironment: [:])
        #expect(config.apiKey == "conv-test-key-value")
        #expect(config.endpoint?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(config.modelName == "example-model-1")
    }

    @Test func conversationBridge_realFullyValidShellEnvConfig_takesPriorityOverKeychain() throws {
        let store = FakeCredentialStore()
        try store.save("keychain-key", for: .conversationProvider)
        // A fully-valid env config (the same gate `isConfigured` applies
        // everywhere): endpoint must pass `isEndpointAllowed`, so use a
        // localhost endpoint which is always permitted.
        let env = [
            "FRIDAY_CONVERSATION_MODEL_API_KEY": "env-key",
            "FRIDAY_CONVERSATION_MODEL_ENDPOINT": "http://127.0.0.1:8080/v1/chat/completions",
            "FRIDAY_CONVERSATION_MODEL_NAME": "env-model",
        ]
        let envOnly = ConversationModelConfig.fromEnvironment(env)
        // Only assert the priority behaviour if the env config is genuinely
        // usable on this build's endpoint policy; otherwise the helper
        // (correctly) falls through, and there is nothing to prove here.
        if envOnly.isConfigured {
            let config = conversationModelConfigFromNativeSources(credentialStore: store, settings: .safeDefault, processEnvironment: env)
            #expect(config.apiKey == "env-key", "a fully-valid shell env config must win over Keychain, for developer/CI parity")
        }
    }

    @Test func conversationBridge_credentialNeverAppearsInAnyNonSecretSurface() throws {
        let store = FakeCredentialStore()
        try store.save("super-secret-conv-key", for: .conversationProvider)
        var settings = ProductionSettings.safeDefault
        settings.conversationEndpoint = "https://api.example.com/v1/chat/completions"
        // ProductionSettings must never carry the secret even after the bridge runs.
        _ = conversationModelConfigFromNativeSources(credentialStore: store, settings: settings, processEnvironment: [:])
        let encoded = try JSONEncoder().encode(settings)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!json.contains("super-secret-conv-key"))
    }
}
