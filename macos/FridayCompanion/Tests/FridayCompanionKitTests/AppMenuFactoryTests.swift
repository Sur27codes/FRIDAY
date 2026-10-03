#if canImport(AppKit)
import Testing
import AppKit
@testable import FridayCompanionKit

/// P2-PROD-BOOTSTRAP-R2 §1.1/§1.2 — the standard Edit menu that makes
/// Cmd-V / Cmd-A / Cmd-Z work in the FRIDAY Setup secure fields. Pure
/// `NSMenu` construction — no running `NSApplication` event loop needed.
@Suite struct AppMenuFactoryTests {
    private func editMenu() -> NSMenu {
        let main = AppMenuFactory.makeMainMenu(appName: "FRIDAY")
        let editItem = main.items.first { $0.submenu?.title == "Edit" }
        return editItem!.submenu!
    }

    @Test func mainMenu_hasAppAndEditSubmenus() {
        let main = AppMenuFactory.makeMainMenu(appName: "FRIDAY")
        #expect(main.items.count == 2)
        #expect(main.items.contains { $0.submenu?.title == "Edit" })
        // The first submenu is the App menu — it must carry Quit (Cmd-Q).
        let appMenu = main.items.first!.submenu!
        let quit = appMenu.items.first { $0.title == "Quit FRIDAY" }
        #expect(quit?.keyEquivalent == "q")
        #expect(quit?.keyEquivalentModifierMask == [.command])
        #expect(quit?.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func editMenu_paste_isCmdV_wiredToNativeSelector() {
        let paste = editMenu().items.first { $0.title == "Paste" }
        #expect(paste != nil)
        #expect(paste?.keyEquivalent == "v")
        #expect(paste?.keyEquivalentModifierMask == [.command])
        #expect(paste?.action == #selector(NSText.paste(_:)))
        // Crucially NOT targeted at a custom object — it must ride the
        // responder chain to whatever text field is first responder.
        #expect(paste?.target == nil)
    }

    @Test func editMenu_selectAll_isCmdA_wiredToNativeSelector() {
        let selectAll = editMenu().items.first { $0.title == "Select All" }
        #expect(selectAll?.keyEquivalent == "a")
        #expect(selectAll?.keyEquivalentModifierMask == [.command])
        #expect(selectAll?.action == #selector(NSText.selectAll(_:)))
        #expect(selectAll?.target == nil)
    }

    @Test func editMenu_cutCopyDelete_wiredToNativeSelectors() {
        let items = editMenu().items
        let cut = items.first { $0.title == "Cut" }
        let copy = items.first { $0.title == "Copy" }
        let delete = items.first { $0.title == "Delete" }
        #expect(cut?.keyEquivalent == "x")
        #expect(cut?.action == #selector(NSText.cut(_:)))
        #expect(copy?.keyEquivalent == "c")
        #expect(copy?.action == #selector(NSText.copy(_:)))
        #expect(delete?.action == #selector(NSText.delete(_:)))
    }

    @Test func editMenu_undoRedo_useStandardFirstResponderSelectors() {
        let items = editMenu().items
        let undo = items.first { $0.title == "Undo" }
        let redo = items.first { $0.title == "Redo" }
        #expect(undo?.keyEquivalent == "z")
        #expect(undo?.keyEquivalentModifierMask == [.command])
        #expect(undo?.action == Selector(("undo:")))
        #expect(redo?.keyEquivalent == "z")
        #expect(redo?.keyEquivalentModifierMask == [.command, .shift])
        #expect(redo?.action == Selector(("redo:")))
    }

    @Test func editMenu_hasSeparators_notOneFlatList() {
        #expect(editMenu().items.contains { $0.isSeparatorItem })
    }
}
#endif
