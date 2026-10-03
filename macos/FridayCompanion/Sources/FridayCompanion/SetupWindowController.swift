import AppKit
import FridayCompanionKit

/// P2-PROD-BOOTSTRAP §B6, substantially reworked in P2-PROD-BOOTSTRAP-R2
/// §5 — the native first-run/setup surface. Shown instead of the old
/// blocking `NSAlert` + `NSApp.terminate` whenever `determineSetupState`
/// reports a blocking gap. Still intentionally scoped below the full
/// P2-M6 settings experience, but now professionally usable: labelled
/// Conversation / Voice / Permissions / Startup sections, honest copy
/// about the real Cartesia → Chatterbox → Samantha fallback order, clear
/// Stored / Missing status, a REAL two-part "Test Connection" that
/// authenticates against both providers, and a Continue button that
/// refuses to enter a broken production state.
///
/// The Cmd-V / Cmd-A / Cmd-Z etc. that make the secure fields usable come
/// from `AppMenuFactory` (assigned to `NSApp.mainMenu` in `main.swift`) —
/// see that type for the root cause. This controller adds NO custom
/// clipboard code.
@MainActor
final class SetupWindowController: NSWindowController {
    private let credentialStore: CredentialStoring
    private let settingsStore: ProductionSettingsStore
    private let permissionCoordinator: PermissionCoordinator
    private let loginItemManager: LoginItemManaging
    private let onSetupComplete: () -> Void

    // Conversation
    private let conversationProviderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let conversationEndpointField = NSTextField()
    private let conversationModelField = NSTextField()
    private let conversationField = NSSecureTextField()
    private let conversationCredStatus = NSTextField(labelWithString: "")

    // Voice
    private let cartesiaField = NSSecureTextField()
    private let cartesiaCredStatus = NSTextField(labelWithString: "")

    // Permissions
    private let micStatusLabel = NSTextField(labelWithString: "")
    private let speechStatusLabel = NSTextField(labelWithString: "")

    // Startup
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch FRIDAY at login", target: nil, action: nil)

    // Results
    private let conversationTestResultLabel = NSTextField(labelWithString: "")
    private let voiceTestResultLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save Credentials", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)

    /// The provider choices the production adapter actually supports
    /// TODAY (P2-PROD-BOOTSTRAP-R2 §2.5). OpenAI and any OpenAI-compatible
    /// endpoint (Groq, a local inference server, Google's OpenAI-compat
    /// endpoint) go through the same `URLSessionConversationModelClient`.
    /// Anthropic's native API and Gemini's native API need a separate
    /// adapter and are deliberately NOT offered here.
    private enum ConversationProviderChoice: Int, CaseIterable {
        case openAI = 0
        case openAICompatible = 1
        var title: String {
            switch self {
            case .openAI: return "OpenAI"
            case .openAICompatible: return "OpenAI-compatible (Groq, local, other)"
            }
        }
        var settingsValue: String {
            switch self {
            case .openAI: return "openai"
            case .openAICompatible: return "openai-compatible"
            }
        }
        var defaultEndpoint: String {
            switch self {
            case .openAI: return "https://api.openai.com/v1/chat/completions"
            case .openAICompatible: return ""
            }
        }
        static func from(settingsValue: String) -> ConversationProviderChoice {
            settingsValue == "openai-compatible" ? .openAICompatible : .openAI
        }
    }

    init(
        credentialStore: CredentialStoring, settingsStore: ProductionSettingsStore,
        permissionCoordinator: PermissionCoordinator, loginItemManager: LoginItemManaging,
        onSetupComplete: @escaping () -> Void
    ) {
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.permissionCoordinator = permissionCoordinator
        self.loginItemManager = loginItemManager
        self.onSetupComplete = onSetupComplete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FRIDAY Setup"
        window.center()
        super.init(window: window)
        buildUI()
        loadFromSettings()
        refreshPermissionLabels()
        refreshCredentialStatus()
        updateButtonState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - UI

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "FRIDAY Setup")
        title.font = .boldSystemFont(ofSize: 17)

        // ---- Conversation ----
        for choice in ConversationProviderChoice.allCases { conversationProviderPopup.addItem(withTitle: choice.title) }
        conversationProviderPopup.target = self
        conversationProviderPopup.action = #selector(conversationProviderChanged)
        conversationEndpointField.placeholderString = "https://…/v1/chat/completions"
        conversationModelField.placeholderString = "model name, e.g. gpt-4o"
        conversationField.placeholderString = "Paste conversation API key (Cmd-V)"

        // ---- Voice ----
        cartesiaField.placeholderString = "Paste Cartesia API key (Cmd-V)"

        let saveButtonLocal = saveButton
        saveButtonLocal.target = self
        saveButtonLocal.action = #selector(saveTapped)
        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnectionTapped))
        let requestPermissionsButton = NSButton(title: "Request Permissions", target: self, action: #selector(requestPermissionsTapped))
        let openSettingsButton = NSButton(title: "Open System Settings…", target: self, action: #selector(openSystemSettingsTapped))
        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        launchAtLoginCheckbox.state = loginItemManager.isRegistered() ? .on : .off

        conversationTestResultLabel.font = .systemFont(ofSize: 11)
        voiceTestResultLabel.font = .systemFont(ofSize: 11)
        statusLabel.font = .systemFont(ofSize: 11)
        for label in [conversationCredStatus, cartesiaCredStatus] { label.font = .systemFont(ofSize: 11) }

        let stack = NSStackView(views: [
            title,
            NSBox.separatorLine(),

            sectionHeader("Conversation"),
            caption("The reasoning model FRIDAY uses to answer you. FRIDAY always recomputes what is true and allowed locally — the model only proposes wording."),
            row("Provider", conversationProviderPopup),
            row("Endpoint", conversationEndpointField),
            row("Model", conversationModelField),
            row("API key", conversationField),
            conversationCredStatus,

            NSBox.separatorLine(),
            sectionHeader("Voice"),
            caption("FRIDAY's primary voice is Skylar (Cartesia sonic-3.6, en-US). A Cartesia API key is required for Skylar. If it is unavailable, FRIDAY falls back to local Chatterbox speech, then to the macOS system voice as a last resort."),
            labelRow("Provider", "Cartesia"),
            labelRow("Model / Voice", "sonic-3.6 · Skylar"),
            labelRow("Locale", "en-US"),
            row("Cartesia API key", cartesiaField),
            cartesiaCredStatus,

            NSBox.separatorLine(),
            sectionHeader("Permissions"),
            micStatusLabel, speechStatusLabel,
            buttonRow([requestPermissionsButton, openSettingsButton]),

            NSBox.separatorLine(),
            sectionHeader("Startup"),
            launchAtLoginCheckbox,

            NSBox.separatorLine(),
            buttonRow([saveButtonLocal, testButton]),
            conversationTestResultLabel,
            voiceTestResultLabel,
            statusLabel,
            continueButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        for field in [conversationEndpointField, conversationModelField] {
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        conversationField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        cartesiaField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        conversationProviderPopup.widthAnchor.constraint(equalToConstant: 340).isActive = true

        [conversationField, cartesiaField, conversationEndpointField, conversationModelField].forEach {
            $0.delegate = self
        }
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: "\(label):")
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let h = NSStackView(views: [l, control])
        h.orientation = .horizontal
        h.alignment = .firstBaseline
        h.spacing = 8
        return h
    }

    private func labelRow(_ label: String, _ value: String) -> NSView {
        let v = NSTextField(labelWithString: value)
        v.textColor = .secondaryLabelColor
        return row(label, v)
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let h = NSStackView(views: buttons)
        h.orientation = .horizontal
        h.spacing = 8
        return h
    }

    // MARK: - State

    private func loadFromSettings() {
        let settings = (try? settingsStore.load()) ?? .safeDefault
        let choice = ConversationProviderChoice.from(settingsValue: settings.conversationProvider)
        conversationProviderPopup.selectItem(at: choice.rawValue)
        conversationEndpointField.stringValue = settings.conversationEndpoint ?? choice.defaultEndpoint
        conversationModelField.stringValue = settings.conversationModel == "unspecified" ? "" : settings.conversationModel
    }

    private func currentConversationChoice() -> ConversationProviderChoice {
        ConversationProviderChoice(rawValue: conversationProviderPopup.indexOfSelectedItem) ?? .openAI
    }

    @objc private func conversationProviderChanged() {
        let choice = currentConversationChoice()
        if choice == .openAI, conversationEndpointField.stringValue.isEmpty || conversationEndpointField.stringValue.contains("api.openai.com") {
            conversationEndpointField.stringValue = choice.defaultEndpoint
        }
        conversationEndpointField.isEnabled = true // both choices allow an explicit endpoint
        updateButtonState()
    }

    private func refreshCredentialStatus() {
        conversationCredStatus.stringValue = statusText(credentialStore.status(.conversationProvider), name: "Conversation credential")
        conversationCredStatus.textColor = credentialStore.status(.conversationProvider).exists ? .systemGreen : .secondaryLabelColor
        cartesiaCredStatus.stringValue = statusText(credentialStore.status(.cartesiaVoiceProvider), name: "Cartesia credential")
        cartesiaCredStatus.textColor = credentialStore.status(.cartesiaVoiceProvider).exists ? .systemGreen : .secondaryLabelColor
    }

    /// P2-PROD-BOOTSTRAP-R2.2 §12 — never renders any fragment of the real
    /// secret (`maskedPreview` exists on `CredentialStatus` for developer
    /// diagnostics elsewhere, but there is no product need to reveal any
    /// part of a stored credential here, and doing so is a needless
    /// privacy exposure). Only a boolean Stored/Missing state is shown.
    private func statusText(_ status: CredentialStatus, name: String) -> String {
        if status.exists {
            return "\(name): Stored ✓"
        }
        return "\(name): Missing"
    }

    private func refreshPermissionLabels() {
        let snapshot = permissionCoordinator.currentSnapshot()
        micStatusLabel.stringValue = "Microphone: \(describe(snapshot.microphone))"
        micStatusLabel.textColor = snapshot.microphone == .granted ? .systemGreen : .secondaryLabelColor
        speechStatusLabel.stringValue = "Speech Recognition: \(describe(snapshot.speechRecognition))"
        speechStatusLabel.textColor = snapshot.speechRecognition == .granted ? .systemGreen : .secondaryLabelColor
    }

    private func describe(_ state: CoordinatedPermissionState) -> String {
        switch state {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet requested"
        case .requiresSystemSettings: return "Denied — open System Settings ▸ Privacy & Security"
        }
    }

    /// §5.1 — Save is enabled when there is at least one credential to
    /// write (new text typed) OR a config field changed; Continue is
    /// enabled only when the blocking production gate is satisfied.
    private func updateButtonState() {
        let hasCredentialToSave = !conversationField.stringValue.isEmpty || !cartesiaField.stringValue.isEmpty
        let hasConfigToSave = !conversationModelField.stringValue.isEmpty || !conversationEndpointField.stringValue.isEmpty
        saveButton.isEnabled = hasCredentialToSave || hasConfigToSave

        continueButton.isEnabled = blockingGaps().isEmpty
        continueButton.toolTip = blockingGaps().isEmpty ? nil :
            "Still needed: " + blockingGaps().map(\.displayName).joined(separator: ", ")
    }

    private func blockingGaps() -> [SetupRequirement] {
        let settings = (try? settingsStore.load()) ?? .safeDefault
        let state = determineSetupState(
            settings: settings,
            conversationCredentialExists: credentialStore.status(.conversationProvider).exists,
            voiceCredentialExists: PremiumVoiceProviderConfig.fromEnvironment().isConfigured || credentialStore.status(.cartesiaVoiceProvider).exists,
            permissions: permissionCoordinator.currentSnapshot()
        )
        if case .setupRequired(let missing) = state { return missing }
        return []
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        let conversationValue = conversationField.stringValue
        let cartesiaValue = cartesiaField.stringValue
        do {
            if !conversationValue.isEmpty {
                try credentialStore.save(conversationValue, for: .conversationProvider)
                conversationField.stringValue = ""
            }
            if !cartesiaValue.isEmpty {
                try credentialStore.save(cartesiaValue, for: .cartesiaVoiceProvider)
                cartesiaField.stringValue = ""
            }

            var settings = (try? settingsStore.load()) ?? .safeDefault
            let choice = currentConversationChoice()
            settings.conversationProvider = choice.settingsValue
            let endpoint = conversationEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.conversationEndpoint = endpoint.isEmpty ? nil : endpoint
            let model = conversationModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.conversationModel = model.isEmpty ? "unspecified" : model
            if credentialStore.status(.cartesiaVoiceProvider).exists {
                settings.voiceProvider = FridayVoiceV1Identity.providerName
                settings.voiceModel = FridayVoiceV1Identity.model
                settings.voiceID = FridayVoiceV1Identity.voiceID
                settings.locale = FridayVoiceV1Identity.locale
            }
            try settingsStore.save(settings)

            statusLabel.stringValue = "Saved. Credentials are stored in the macOS Keychain — never shown again after saving."
            statusLabel.textColor = .systemGreen
        } catch {
            // Never include the credential value itself — only that saving failed.
            statusLabel.stringValue = "Could not save to the macOS Keychain. The credential value was discarded and not logged. Check that the login keychain is unlocked and try again."
            statusLabel.textColor = .systemRed
        }
        refreshCredentialStatus()
        updateButtonState()
    }

    @objc private func testConnectionTapped() {
        // Persist whatever is currently typed first, so the probes test
        // exactly what the owner sees (without this, a freshly-typed key
        // that hasn't been Saved wouldn't be tested).
        if !conversationField.stringValue.isEmpty || !cartesiaField.stringValue.isEmpty
            || !conversationModelField.stringValue.isEmpty || !conversationEndpointField.stringValue.isEmpty {
            saveTapped()
        }

        conversationTestResultLabel.stringValue = "Conversation: testing…"
        conversationTestResultLabel.textColor = .secondaryLabelColor
        voiceTestResultLabel.stringValue = "Voice: testing…"
        voiceTestResultLabel.textColor = .secondaryLabelColor

        let settings = (try? settingsStore.load()) ?? .safeDefault
        let conversationConfig = conversationModelConfigFromNativeSources(credentialStore: credentialStore, settings: settings)
        let voiceConfig = premiumVoiceProviderConfigFromNativeSources(credentialStore: credentialStore, settings: settings)

        ConversationProviderProbe().probe(config: conversationConfig) { [weak self] result in
            // P2-PROD-BOOTSTRAP-R2.2 §11 — the bounded, secret-free detail
            // (e.g. "HTTP 400: ...") goes to the developer log ONLY; the
            // visible label always uses the sanitized `displayLine` category.
            if let detail = result.diagnosticDetail {
                NSLog("FRIDAY Setup: conversation connectivity check — \(detail)")
            }
            Task { @MainActor in
                guard let self else { return }
                self.conversationTestResultLabel.stringValue = "Conversation: \(result.displayLine)"
                self.conversationTestResultLabel.textColor = result.isConnected ? .systemGreen : .systemRed
            }
        }
        VoiceProviderProbe().probe(config: voiceConfig) { [weak self] result in
            if let detail = result.diagnosticDetail {
                NSLog("FRIDAY Setup: voice connectivity check — \(detail)")
            }
            Task { @MainActor in
                guard let self else { return }
                self.voiceTestResultLabel.stringValue = "Voice: \(result.displayLine)"
                self.voiceTestResultLabel.textColor = result.isConnected ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func requestPermissionsTapped() {
        Task {
            _ = await permissionCoordinator.requestAll()
            await MainActor.run {
                self.refreshPermissionLabels()
                self.updateButtonState()
            }
        }
    }

    @objc private func openSystemSettingsTapped() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func launchAtLoginToggled() {
        do {
            try loginItemManager.setRegistered(launchAtLoginCheckbox.state == .on)
            var settings = (try? settingsStore.load()) ?? .safeDefault
            settings.launchAtLoginEnabled = launchAtLoginCheckbox.state == .on
            try? settingsStore.save(settings)
        } catch {
            launchAtLoginCheckbox.state = loginItemManager.isRegistered() ? .on : .off
            statusLabel.stringValue = "Could not change the login item. macOS may require approval in System Settings ▸ General ▸ Login Items."
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func continueTapped() {
        let gaps = blockingGaps()
        guard gaps.isEmpty else {
            statusLabel.stringValue = "Not ready yet — still needed: " + gaps.map(\.displayName).joined(separator: ", ") + "."
            statusLabel.textColor = .systemRed
            return
        }
        onSetupComplete()
        window?.close()
    }
}

extension SetupWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateButtonState()
    }
}

private extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
