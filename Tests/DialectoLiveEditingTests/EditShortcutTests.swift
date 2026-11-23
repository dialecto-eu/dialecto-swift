#if DEBUG && canImport(AppKit)
    import AppKit
    import Testing

    @testable import DialectoLiveEditing

    /// ⌃⌥⌘E turns Edit text on and off even while SwiftUI is rebuilding the main menu.
    @MainActor
    struct EditShortcutTests {
        private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 14)!
        }

        @Test func matchesControlOptionCommandE() {
            #expect(MacSupport.isEditShortcut(key("e", [.control, .option, .command])))
            #expect(MacSupport.isEditShortcut(key("E", [.control, .option, .command, .capsLock])))
        }

        @Test func ignoresOtherModifiersAndKeys() {
            #expect(!MacSupport.isEditShortcut(key("e", [.command])))
            #expect(!MacSupport.isEditShortcut(key("e", [.option, .command])))
            #expect(!MacSupport.isEditShortcut(key("e", [.control, .option, .command, .shift])))
            #expect(!MacSupport.isEditShortcut(key("r", [.control, .option, .command])))
        }
    }
#endif
