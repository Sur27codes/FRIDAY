import AppKit
import FridayCompanionKit

// Thin entry point — everything of substance lives in
// `FridayCompanionKit` (tested) or `AppDelegate`/`MenuBarController`
// (thin AppKit wiring, not independently unit-tested, mirroring how
// `cmd/friday/main.go` on the Go side is a thin wrapper around the
// tested `orchestrator` package).
//
// `main.swift`'s top-level code runs on the main thread but is not
// automatically inferred as `@MainActor`-isolated by the compiler;
// `AppDelegate`/`NSApplication` are `@MainActor`-isolated, so this is a
// legitimate, safe assertion of isolation we already structurally have
// (process startup, before any concurrency exists) — not a workaround
// for an actual data race.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // P2-PROD-BOOTSTRAP-R2 §1 — a hand-built `NSApplication` has no main
    // menu, so AppKit never dispatches Cmd-V / Cmd-A / Cmd-Z / Cmd-C /
    // Cmd-X to the first responder (they are routed through the menu's
    // key equivalents). Without this line the FRIDAY Setup secure fields
    // could not accept a pasted API key. `AppMenuFactory` builds a
    // standard App + Edit menu wired entirely to native first-responder
    // selectors.
    app.mainMenu = AppMenuFactory.makeMainMenu(appName: "FRIDAY")
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
