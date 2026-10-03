#if canImport(AppKit)
import AppKit

/// P2-PROD-BOOTSTRAP-R2 §1 — the standard macOS main menu.
///
/// ROOT CAUSE of the "Command-V does nothing in the FRIDAY Setup secure
/// fields" bug (§1.1): `Sources/FridayCompanion/main.swift` builds
/// `NSApplication` by hand (no `.xib`, no storyboard, `LSUIElement` /
/// `.accessory` activation) and never assigned `NSApp.mainMenu`. AppKit
/// routes `Cmd-V` / `Cmd-A` / `Cmd-Z` / `Cmd-X` / `Cmd-C` to the first
/// responder **through the main menu's key equivalents** — an
/// `NSSecureTextField`'s field editor already implements `paste(_:)`,
/// `selectAll(_:)`, `cut(_:)`, `copy(_:)`, `undo(_:)`/`redo(_:)`, but with
/// no menu carrying those key equivalents, the keystrokes are never
/// dispatched. There was no custom event monitor swallowing the event and
/// no first-responder problem — the menu simply did not exist.
///
/// FIX: assign a real main menu with a standard **Edit** menu whose items
/// use the native first-responder action selectors (`NSText.paste(_:)`
/// etc.) and standard key equivalents. This is pure responder-chain
/// behavior — no custom `NSPasteboard` reader anywhere (§1.2).
public enum AppMenuFactory {
    /// Builds the complete `NSApp.mainMenu`: a minimal **App** menu
    /// (About / Hide / Hide Others / Show All / Quit — the items macOS
    /// users reflexively expect, and the ones a menu-bar-only app still
    /// needs for Cmd-Q) and a standard **Edit** menu (Undo / Redo / Cut /
    /// Copy / Paste / Delete / Select All).
    public static func makeMainMenu(appName: String = "FRIDAY") -> NSMenu {
        let mainMenu = NSMenu()

        // ---- App menu ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]

        // ---- Edit menu (the actual fix) ----
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = makeEditMenu()

        return mainMenu
    }

    /// The standard **Edit** menu, wired entirely to native
    /// first-responder selectors so `NSSecureTextField` (and every other
    /// text control) gets normal editing with zero custom clipboard code.
    public static func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")

        let undo = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        editMenu.addItem(.separator())

        let cut = editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cut.keyEquivalentModifierMask = [.command]
        let copy = editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command]
        let paste = editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")

        editMenu.addItem(.separator())

        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = [.command]

        return editMenu
    }
}
#endif
