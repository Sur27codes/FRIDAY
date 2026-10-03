import AppKit
import FridayCompanionKit

/// Wires `FridayCompanionKit`'s Supervisor to a real menu bar app. This
/// is the ONLY file in the executable target that constructs a
/// `Supervisor` for production use — everything it depends on
/// (`CompanionConfiguration`, `makeP2M2ServiceConfigs`, `Supervisor`,
/// `RuntimeClient` itself) is fully covered by `FridayCompanionKitTests`
/// without needing this app shell at all.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var supervisor: Supervisor?
    private var wakeCoordinator: WakeCoordinator?
    private var diagnosticsPrinterTask: Task<Void, Never>?
    private var setupWindow: SetupWindowController?

    // P2-PROD-BOOTSTRAP §B4/§B6 — native, non-Terminal credential/config
    // sources. Real `Security`-framework Keychain + a versioned JSON
    // settings file, both under this app's own Application Support
    // directory — never env-var-only in production mode. Env vars
    // (below) still take priority when set, so developer/CI launches are
    // completely unaffected.
    private let credentialStore: CredentialStoring = KeychainCredentialStore()
    private let settingsStore = ProductionSettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only presence — no Dock icon, no app window
        // (`docs/PHASE-2-ARCHITECTURE.md` §3's "Ambient Mode" default).
        NSApp.setActivationPolicy(.accessory)

        guard let (config, daemonBinary) = Self.resolveBinaryConfiguration() else {
            // Neither developer env vars NOR a real `.app` bundle's
            // Resources directory (see `Scripts/build-and-install-app.sh`,
            // P2-PROD-BOOTSTRAP §B21) could locate the three supervised
            // binaries. This is a genuine installation problem, not a
            // credential/setup problem — the native setup window (below)
            // has nothing to offer here, since it can't conjure a missing
            // binary. Guessing a path would be exactly the kind of
            // silent, undocumented behavior this project avoids.
            let alert = NSAlert()
            alert.messageText = "FRIDAY Companion — installation incomplete"
            alert.informativeText =
                "FRIDAY's supporting binaries were not found. If you're developing, set " +
                "FRIDAY_POLICYENGINED_PATH, FRIDAY_CAPABILITYBUSD_PATH, and FRIDAY_DAEMON_PATH. " +
                "For a real install, run Scripts/build-and-install-app.sh once, then launch the " +
                "installed FRIDAY.app instead of this developer binary."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        do {
            try prepareRuntimeDirectories(config)
        } catch {
            NSLog("FRIDAY Companion: failed to prepare runtime directories: \(error)")
            NSApp.terminate(nil)
            return
        }

        // P2-PROD-BOOTSTRAP §B6 — native first-run gate. Only a BLOCKING
        // gap (conversation credential, or a real permission denial)
        // stops normal startup; a missing voice credential is advisory
        // only (the existing, frozen `FallbackSpeechSynthesizer` already
        // degrades gracefully to on-device Samantha speech — see
        // `docs/phase2/P2-PRODUCTION-RUNTIME-ARCHITECTURE.md` §3).
        let permissionCoordinator = PermissionCoordinator(microphone: RealMicrophonePermission(), speechRecognition: RealSpeechRecognitionPermission())
        let settings = (try? settingsStore.load()) ?? .safeDefault
        let envVoiceConfigured = PremiumVoiceProviderConfig.fromEnvironment().isConfigured
        let setupState = determineSetupState(
            settings: settings,
            conversationCredentialExists: credentialStore.status(.conversationProvider).exists,
            voiceCredentialExists: envVoiceConfigured || credentialStore.status(.cartesiaVoiceProvider).exists,
            permissions: permissionCoordinator.currentSnapshot()
        )
        if case .setupRequired = setupState {
            let loginItemManager: LoginItemManaging = {
                if #available(macOS 13.0, *) { return SMAppServiceLoginItemManager() }
                return FakeLoginItemManager() // pre-13 fallback: no real login-item mechanism exists to back this
            }()
            let window = SetupWindowController(
                credentialStore: credentialStore, settingsStore: settingsStore, permissionCoordinator: permissionCoordinator,
                loginItemManager: loginItemManager,
                onSetupComplete: { [weak self] in self?.continueLaunching(config: config, daemonBinary: daemonBinary) }
            )
            self.setupWindow = window
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return // startup resumes in `continueLaunching`, once setup completes
        }

        continueLaunching(config: config, daemonBinary: daemonBinary)
    }

    /// The rest of P2-M1 through P2-M5's startup sequence — unchanged
    /// logic, merely moved out of `applicationDidFinishLaunching` so it
    /// can run either immediately (setup already complete) or after the
    /// owner finishes the native setup window (§B6).
    private func continueLaunching(config: CompanionConfiguration, daemonBinary: URL) {

        // Overall Companion readiness now includes friday-daemon, purely
        // as a consequence of it being a third mandatory entry in this
        // list — `Supervisor.overall`'s logic is unchanged since P2-M1
        // (`docs/PHASE-2-...` P2-M2 §12: "The Companion must not show
        // overall READY if friday-daemon cannot serve requests").
        let supervisor = Supervisor(services: makeP2M2ServiceConfigs(config, daemonBinary: daemonBinary))
        self.supervisor = supervisor

        // P2-M3D §3: a developer-only diagnostic mode, enabled only by
        // explicit env var, never on by default — recorder allocation
        // itself is cheap and harmless either way (it just never gets
        // read/printed if the mode is off).
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["FRIDAY_WAKE_DIAGNOSTICS"] == "1"
        let diagnostics = WakeDiagnosticsRecorder()

        // ADR-007 (local wake-word engine) is RESOLVED FOR LOCAL
        // DEVELOPMENT — see `docs/W-adr-backlog.md` (P2-M3C). The
        // shipped default is now the real, local, offline sherpa-onnx
        // keyword spotter targeting the literal phrase "Hey Friday" —
        // `NullWakeWordDetector` is kept only for tests, explicitly
        // disabled-wake configuration, and as the fallback here if the
        // vendored model resource genuinely cannot be loaded.
        //
        // P2-M3D §10: that fallback must never *look* operational — a
        // non-nil `detectorUnavailableReason` tells `WakeCoordinator` to
        // refuse `.wakeOnly` and truthfully report `.unavailable`
        // instead of silently running a detector that can never fire.
        let detector: WakeWordDetecting
        var detectorUnavailableReason: String?
        do {
            let sherpaConfig = try SherpaOnnxWakeWordConfig.bundledDefault()
            detector = SherpaOnnxWakeWordDetector(config: sherpaConfig, diagnostics: diagnostics)
        } catch {
            let reason = String(describing: error)
            NSLog("FRIDAY Companion: sherpa-onnx wake model unavailable (\(reason)) — falling back to NullWakeWordDetector; \"Hey Friday\" will not be detected until this is fixed.")
            diagnostics.recordDetectorConstructionFailure(reason)
            detectorUnavailableReason = reason
            detector = NullWakeWordDetector()
        }
        // P2-M4: ADR-008 (updated during this milestone) — real, on-device
        // command transcription via Apple's Speech framework, and
        // submission through the exact existing, unmodified
        // `RuntimeClient` (§3/§13: voice is only another input adapter,
        // never a privileged path). `AppleSpeechTranscriber`/
        // `RealSpeechRecognitionPermission` never construct/request
        // anything beyond what the same-named microphone types already
        // do for wake detection.
        let runtimeClient = RuntimeClient(socketPath: config.daemonSocketPath)
        let transcriber = AppleSpeechTranscriber(diagnostics: diagnostics)
        // P2-M5: ADR-009 (updated during this milestone) — real, local,
        // on-device speech synthesis via AVSpeechSynthesizer, and a
        // response presenter that primarily relays the runtime's own
        // already-safe `Response.Text` (§3/§8: voice output is only
        // another adapter, never a second place response phrasing is
        // decided).
        //
        // P2-M5V9-B §13: Samantha (`AVSpeechSynthesizerAdapter`) is no
        // longer the normal output voice — it is now wired as the
        // `FallbackSpeechSynthesizer` SECONDARY engine only, engaged
        // exclusively on genuine premium-provider unavailability/timeout/
        // failure. `PremiumVoiceProviderConfig.fromEnvironment()` is
        // absent by default (no `FRIDAY_VOICE_PROVIDER_*` env vars set)
        // in every environment this code has actually run in so far, so
        // `premiumProvider` stays `nil` and `PremiumNeuralSpeechSynthesizer`
        // throws its disclosed `NotConfiguredError` immediately on every
        // utterance — `FallbackSpeechSynthesizer` catches that
        // synchronously and Samantha still speaks every response today,
        // identical to pre-V9-B behavior from the user's perspective.
        // Setting real credentials via environment variables is the ONLY
        // change required to activate a real premium engine — no code
        // change anywhere else (§2: provider-neutral, config-driven).
        // P2-M5V9-B.2 §2/§7: Cartesia Sonic-3.6 ("Skylar") is FRIDAY's
        // named V1 rendering voice. `isCartesia` is the ONE place a
        // provider name is ever branched on — every other line here
        // stays byte-identical regardless of which concrete adapter gets
        // selected (§7/§17: "no provider-specific branching scattered
        // through presenter code"). Any OTHER `providerName` still uses
        // the generic, provider-neutral HTTP streaming adapter.
        let voiceProviderConfig = Self.resolveVoiceProviderConfig(credentialStore: credentialStore)
        var premiumProvider: PremiumSpeechStreamProviding?
        if voiceProviderConfig.isConfigured {
            premiumProvider = voiceProviderConfig.isCartesia
                ? CartesiaSpeechStreamProvider(config: voiceProviderConfig)
                : URLSessionPremiumSpeechStreamProvider(config: voiceProviderConfig)
        }
        let premiumVoiceProfile = PremiumVoiceProfile(
            voiceProfileID: "friday-original-01", providerID: voiceProviderConfig.providerName,
            providerVoiceID: voiceProviderConfig.voiceID, profileVersion: "1"
        )
        // P2-M5V9-B.3C §2: real audible playback for the premium/Cartesia
        // path — previously accumulated into AudioChunkBuffer and never
        // played (the same disclosed gap Chatterbox had before P2-M5V9-B.3B).
        // Reuses the identical AVAudioEnginePCMPlayer, never a second
        // ad-hoc player.
        // P2-M5-FINAL-CLOSURE-R1 §1 — the production speech path is now an
        // explicit THREE-tier cascade: Cartesia Skylar → Chatterbox Turbo
        // (local, lazy) → Samantha (emergency final). `CascadingSpeechSynthesizer`
        // is the single explicit state machine that owns "how far down are
        // we / has playback begun / has a terminal result gone out",
        // preserving the exact no-replay-after-playback and
        // no-fallback-after-interruption rules `FallbackSpeechSynthesizer`
        // established. Skylar is untouched; Turbo is NEVER labelled Skylar.
        let cartesiaTier = PremiumNeuralSpeechSynthesizer(provider: premiumProvider, voiceProfile: premiumVoiceProfile, diagnostics: diagnostics, player: AVAudioEnginePCMPlayer())
        let chatterboxSocketPath = ProcessInfo.processInfo.environment["FRIDAY_CHATTERBOX_SOCKET_PATH"] ?? "/tmp/friday-chatterbox.sock"
        // §1.2 lazy lifecycle: this tier is completely inert until the
        // cascade actually reaches it — no service process, no model load
        // at login. `makeChatterboxServiceLauncher` starts the local
        // service on first genuine need (or fails cleanly → Samantha).
        let chatterboxTier = LazyLocalVoiceTier(
            underlying: LocalChatterboxSpeechSynthesizer(socketPath: chatterboxSocketPath, variant: "turbo", diagnostics: diagnostics),
            socketPath: chatterboxSocketPath,
            ensureServiceRunning: makeChatterboxServiceLauncher(socketPath: chatterboxSocketPath)
        )
        let samanthaTier = AVSpeechSynthesizerAdapter(profile: .friday)
        let synthesizer = CascadingSpeechSynthesizer(tiers: [cartesiaTier, chatterboxTier, samanthaTier], diagnostics: diagnostics)

        // P2-PROD-BOOTSTRAP-R2 §2 — the production response path. When a
        // conversation model is configured natively (Keychain credential +
        // `ProductionSettings` endpoint/model — NO shell exports), FRIDAY
        // routes normal conversation through the already-frozen ONE-CALL
        // conversational brain (`ConversationalResponsePresenter.withUnifiedModelProvider`).
        // Its `authoritative(...)` recomputation still overrides every
        // safety-critical field locally ("the LLM proposes; FRIDAY decides
        // what is true and allowed" — §2.2), and `ResponseValidation`
        // still gates every candidate, with a fail-closed deterministic
        // fallback and NO second provider call (§2.3). When it is NOT
        // configured, the path stays the fully-deterministic
        // `DeterministicResponsePresenter`, exactly as before — fail-closed.
        let conversationConfig = conversationModelConfigFromNativeSources(
            credentialStore: credentialStore,
            settings: (try? settingsStore.load()) ?? .safeDefault
        )
        let responsePresenter: ResponsePresenting = conversationConfig.isConfigured
            ? ConversationalResponsePresenter.withUnifiedModelProvider(config: conversationConfig, diagnostics: diagnostics)
            : DeterministicResponsePresenter()
        NSLog("FRIDAY Companion: conversation path = \(conversationConfig.isConfigured ? "one-call model brain (provider configured)" : "deterministic (no conversation model configured)")")

        let wakeCoordinator = WakeCoordinator(
            capture: RealAudioCaptureEngine(diagnostics: diagnostics), detector: detector, permission: RealMicrophonePermission(),
            transcriber: transcriber, runtimeSubmitter: runtimeClient, speechPermission: RealSpeechRecognitionPermission(),
            synthesizer: synthesizer, responsePresenter: responsePresenter,
            detectorUnavailableReason: detectorUnavailableReason, diagnostics: diagnostics
        )
        self.wakeCoordinator = wakeCoordinator

        self.menuBar = MenuBarController(supervisor: supervisor, wakeCoordinator: wakeCoordinator)
        Task { await supervisor.startAll() }

        if diagnosticsEnabled {
            // P2-M4 §19: transcript text is a SECOND, separate opt-in —
            // the base diagnostics mode alone never shows it.
            let includeTranscript = ProcessInfo.processInfo.environment["FRIDAY_WAKE_DIAGNOSTICS_INCLUDE_TRANSCRIPT"] == "1"
            NSLog("FRIDAY Companion: wake diagnostics ENABLED (FRIDAY_WAKE_DIAGNOSTICS=1) — printing a snapshot every 2s to stdout." + (includeTranscript ? " Transcript text INCLUDED (FRIDAY_WAKE_DIAGNOSTICS_INCLUDE_TRANSCRIPT=1)." : ""))
            diagnosticsPrinterTask = Task { [diagnostics] in
                while !Task.isCancelled {
                    let snapshot = diagnostics.snapshot()
                    print("---- FRIDAY wake diagnostics ----")
                    print(WakeDiagnosticsFormatter.render(snapshot, includeTranscript: includeTranscript))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticsPrinterTask?.cancel()
        guard let supervisor else { return }
        // Best-effort synchronous-ish drain: request shutdown and give
        // it a moment — AppKit does not let us block indefinitely in
        // this callback, but the supervised processes' own SIGTERM
        // handlers exit quickly (see policyengined/capabilitybusd/
        // friday-daemon `main.go`), so this is normally sufficient.
        //
        // P2-PROD-BOOTSTRAP-R2.6 §8 root-cause fix — a REAL, 100%-
        // reproducible deadlock, found via the real installed app (never
        // caught by any test, since `AppDelegate` itself has none): this
        // method runs on `@MainActor` (this whole class is), so the
        // PREVIOUS plain `Task { ... }` here silently inherited MainActor
        // isolation from its captured `self`-adjacent properties — its
        // body could only ever run ON the main thread. But the very next
        // line blocked that SAME main thread on `semaphore.wait(...)`,
        // so the Task could never be scheduled at all: `stopAll()` never
        // even started, every launch orphaned all three real child
        // processes, and the 5-second wait below always ran out doing
        // nothing before AppKit tore the process down anyway. `Task
        // .detached` fixes this the minimal way: it does NOT inherit the
        // caller's actor context, so it runs on the concurrent executor
        // (any thread but this blocked one) and can actually reach
        // `wakeCoordinator`/`supervisor` (both independent actors) and
        // signal the semaphore for real. `wakeCoordinator`/`supervisor`
        // are captured as local, already-`Sendable` (actor) references
        // BEFORE crossing into the detached task, exactly as `guard let
        // supervisor` above already does.
        let capturedWakeCoordinator = wakeCoordinator
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await capturedWakeCoordinator?.disable()
            await supervisor.stopAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// Developer/CI mode, unchanged from before this milestone: explicit
    /// env vars naming exactly where the three Go binaries are.
    private static func loadConfigurationFromEnvironment() -> (CompanionConfiguration, URL)? {
        let env = ProcessInfo.processInfo.environment
        guard let policyPath = env["FRIDAY_POLICYENGINED_PATH"],
              let busPath = env["FRIDAY_CAPABILITYBUSD_PATH"],
              let daemonPath = env["FRIDAY_DAEMON_PATH"] else {
            return nil
        }
        let runtimeDir = env["FRIDAY_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
            ?? CompanionConfiguration.defaultRuntimeDirectory()
        let workspaceRoot = env["FRIDAY_WORKSPACE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? runtimeDir.appendingPathComponent("workspace", isDirectory: true)
        let config = CompanionConfiguration(
            runtimeDirectory: runtimeDir,
            policyEngineBinary: URL(fileURLWithPath: policyPath),
            capabilityBusBinary: URL(fileURLWithPath: busPath),
            workspaceRoot: workspaceRoot
        )
        return (config, URL(fileURLWithPath: daemonPath))
    }

    /// P2-PROD-BOOTSTRAP §B2/§B21 — production mode: when this process is
    /// actually running from inside a real `.app` bundle (built by
    /// `Scripts/build-and-install-app.sh`), the three binaries live
    /// alongside it in `Contents/Resources/`, with no env var required at
    /// all. Env vars (checked first) always take priority, so developer
    /// launches remain byte-for-byte unaffected by this addition.
    private static func resolveBinaryConfiguration() -> (CompanionConfiguration, URL)? {
        if let envResult = loadConfigurationFromEnvironment() { return envResult }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let policyPath = resourceURL.appendingPathComponent("policyengined").path
        let busPath = resourceURL.appendingPathComponent("capabilitybusd").path
        let daemonPath = resourceURL.appendingPathComponent("friday-daemon").path
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: policyPath), fm.isExecutableFile(atPath: busPath), fm.isExecutableFile(atPath: daemonPath) else {
            return nil
        }
        let runtimeDir = CompanionConfiguration.defaultRuntimeDirectory()
        let config = CompanionConfiguration(
            runtimeDirectory: runtimeDir,
            policyEngineBinary: URL(fileURLWithPath: policyPath),
            capabilityBusBinary: URL(fileURLWithPath: busPath),
            workspaceRoot: runtimeDir.appendingPathComponent("workspace", isDirectory: true)
        )
        return (config, URL(fileURLWithPath: daemonPath))
    }

    /// P2-PROD-BOOTSTRAP §B4 — sources the Cartesia voice credential
    /// natively (Keychain + the frozen, owner-accepted FRIDAY Voice V1
    /// identity — `docs/PHASE-2-M5-CONVERSATIONAL-BRAIN-FREEZE.md` /
    /// P2-M5V9-B.3C) when no `FRIDAY_VOICE_PROVIDER_*` env vars are set.
    /// Reuses `PremiumVoiceProviderConfig.fromEnvironment(_:)`'s own,
    /// completely unmodified parsing — this only supplies a DIFFERENT
    /// source dictionary, never new parsing logic, so behavior for an
    /// already-configured-via-env-vars launch is byte-for-byte unchanged.
    private static func resolveVoiceProviderConfig(credentialStore: CredentialStoring) -> PremiumVoiceProviderConfig {
        // P2-PROD-BOOTSTRAP-R2 — the frozen Skylar identity + Keychain
        // resolution now lives once in `FridayCompanionKit`
        // (`premiumVoiceProviderConfigFromNativeSources` /
        // `FridayVoiceV1Identity`), shared with `SetupWindowController`'s
        // "Test Connection" probe.
        premiumVoiceProviderConfigFromNativeSources(
            credentialStore: credentialStore,
            settings: (try? ProductionSettingsStore().load()) ?? .safeDefault
        )
    }
}

