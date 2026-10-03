import AppKit
import FridayCompanionKit

/// The actual `NSStatusItem`-backed menu bar surface. Still intentionally
/// minimal (the full P2-M6 menu-bar experience remains later work) —
/// P2-M3 adds a truthful microphone/wake status line and a wake ON/OFF
/// toggle on top of P2-M1's supervisor status, per §13/§40 of the P2-M3
/// authorization. No microphone waveform/audio content is ever shown or
/// logged here — only the `AudioState` label.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let supervisor: Supervisor
    private let wakeCoordinator: WakeCoordinator
    private var refreshTask: Task<Void, Never>?

    private let startItem = NSMenuItem(title: "Start / Resume", action: #selector(startTapped), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop / Pause", action: #selector(stopTapped), keyEquivalent: "")
    private let statusDetailItem = NSMenuItem(title: "Status: unknown", action: nil, keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "Microphone: Off", action: nil, keyEquivalent: "")
    private let wakeToggleItem = NSMenuItem(title: "Enable Wake (\"Hey Friday\")", action: #selector(wakeToggleTapped), keyEquivalent: "")

    init(supervisor: Supervisor, wakeCoordinator: WakeCoordinator) {
        self.supervisor = supervisor
        self.wakeCoordinator = wakeCoordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        startItem.target = self
        stopItem.target = self
        wakeToggleItem.target = self

        let menu = NSMenu()
        statusDetailItem.isEnabled = false
        microphoneItem.isEnabled = false
        menu.addItem(statusDetailItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(microphoneItem)
        menu.addItem(wakeToggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit FRIDAY", action: #selector(quitTapped), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        statusItem.button?.title = "FRIDAY ○"

        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func refresh() async {
        let overall = await supervisor.overall
        let perService = await supervisor.snapshot()
        let display = MenuBarStateFormatter.display(overall: overall, perService: perService)
        statusItem.button?.title = display.title
        statusDetailItem.title = display.detail.isEmpty ? "Status: unknown" : display.detail
        startItem.isEnabled = display.canStart
        stopItem.isEnabled = display.canStop

        let audioState = await wakeCoordinator.state
        let reason = await wakeCoordinator.lastUnavailableReason
        let wakeDisplay = WakeStatusFormatter.display(audioState: audioState, unavailableReason: reason)
        microphoneItem.title = wakeDisplay.microphoneLine
        wakeToggleItem.title = wakeDisplay.wakeToggleTitle
        wakeToggleItem.isEnabled = wakeDisplay.wakeToggleEnabled
    }

    @objc private func startTapped() {
        Task { await supervisor.startAll() }
    }

    @objc private func stopTapped() {
        // P2-PROD-BOOTSTRAP-R2.8 §14 — a conversation session (including
        // an open follow-up window) must not keep listening/speaking
        // once the owner has asked FRIDAY to stop; mirrors the same
        // `disable()`-before-`stopAll()` ordering `quitTapped()` already
        // uses. `disable()` is a safe no-op if wake was already off.
        Task {
            await wakeCoordinator.disable()
            await supervisor.stopAll()
        }
    }

    @objc private func wakeToggleTapped() {
        Task {
            if await wakeCoordinator.state == .microphoneOff {
                await wakeCoordinator.enable()
            } else {
                await wakeCoordinator.disable()
            }
        }
    }

    @objc private func quitTapped() {
        Task {
            await wakeCoordinator.disable()
            await supervisor.stopAll()
            NSApplication.shared.terminate(nil)
        }
    }
}
