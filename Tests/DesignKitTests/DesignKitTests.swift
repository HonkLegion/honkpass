import AppKit
import CoreText
import DesignKit
import Testing

/// The generated tokens and the bundled resources are present and usable.
@Suite(.serialized) struct DesignKitTests {
    @Test func theProgressBarKeepsItsValueBetweenNoneAndAll() {
        #expect(BWProgressBar.clamped(-5) == 0)
        #expect(BWProgressBar.clamped(42) == 42)
        #expect(BWProgressBar.clamped(140) == 100)
        // "$PERCENT$% complete" with the clamped value.
        #expect(BWProgressBar.startText(140) == BWText["percentageCompleted", "100"])
        #expect(BWProgressBar.startText(140).contains("100"))
    }

    @Test func theArrowKeysGoRoundAnOpenListAndSkipWhatCannotBeChosen() {
        // A menu: two items, a divider, a disabled item, one more item.
        let menu = [true, true, false, false, true]
        #expect(KeyboardList.step(from: nil, by: 1, canChoose: menu) == 0)
        #expect(KeyboardList.step(from: nil, by: -1, canChoose: menu) == 4)
        #expect(KeyboardList.step(from: 0, by: 1, canChoose: menu) == 1)
        #expect(KeyboardList.step(from: 1, by: 1, canChoose: menu) == 4)
        #expect(KeyboardList.step(from: 4, by: 1, canChoose: menu) == 0)
        #expect(KeyboardList.step(from: 0, by: -1, canChoose: menu) == 4)
        #expect(KeyboardList.step(from: 4, by: -1, canChoose: menu) == 1)
        // From an entry that cannot be chosen: the nearest one in the direction of the step.
        #expect(KeyboardList.step(from: 2, by: 1, canChoose: menu) == 4)
        #expect(KeyboardList.step(from: 3, by: -1, canChoose: menu) == 1)
        // Nothing to choose: the place stays.
        #expect(KeyboardList.step(from: nil, by: 1, canChoose: [false, false]) == nil)
        #expect(KeyboardList.step(from: nil, by: 1, canChoose: []) == nil)
        // One entry: it stays on it.
        #expect(KeyboardList.step(from: 0, by: 1, canChoose: [true]) == 0)
    }

    @Test func theHandleOfTheSideNavigationPaintsWhileDraggedAndChoosesWhenLetGo() {
        let rem = Metric.rem
        var size = SideNavigationSize()
        #expect(size.displayWidth == 18.5 * rem && size.saved == 18.5 * rem)
        // A drag paints the width; the choice is made when the handle is let go.
        size.drag(to: 25 * rem)
        #expect(size.displayWidth == 25 * rem && size.saved == 18.5 * rem)
        size.endDrag()
        #expect(size.saved == 25 * rem)
        // Wider than the largest width: it stays at it.
        size.drag(to: 50 * rem)
        size.endDrag()
        #expect(size.saved == 37.5 * rem)
        // Under the smallest width it gives way a little, and goes back to it when let go.
        size.drag(to: 10 * rem)
        #expect(size.displayWidth == (15 - 5 * 0.15) * rem && size.isOpen)
        size.endDrag()
        #expect(size.displayWidth == 15 * rem && size.saved == 15 * rem)
        // Dragged to the rail it closes and keeps the width the user had.
        size.drag(to: 20 * rem)
        size.endDrag()
        size.drag(to: 30 * rem)
        size.drag(to: 3 * rem)
        #expect(!size.isOpen && size.displayWidth == 4 * rem)
        size.endDrag()
        #expect(!size.isOpen && size.saved == 20 * rem)
        // Out of the rail: a preview, which opens at the old width when let go under the smallest one.
        size.drag(to: 9 * rem)
        #expect(!size.isOpen && size.displayWidth == 9 * rem)
        size.endDrag()
        #expect(size.isOpen && size.displayWidth == 20 * rem)
        // Out of the rail past the smallest width: open at the pointer.
        size.toggle()
        size.drag(to: 16 * rem)
        #expect(size.isOpen && size.displayWidth == 16 * rem)
        size.endDrag()
        #expect(size.saved == 16 * rem)
        // The arrows: a rem a step; left at the smallest width closes, right opens.
        size.press(.left)
        #expect(size.saved == 15 * rem)
        size.press(.left)
        #expect(!size.isOpen && size.saved == 15 * rem)
        size.press(.left)
        #expect(!size.isOpen)
        size.press(.right)
        #expect(size.isOpen && size.displayWidth == 15 * rem)
        size.press(.right)
        #expect(size.saved == 16 * rem)
        // A remembered width outside the bounds is brought into them.
        #expect(SideNavigationSize(saved: 5).saved == 15 * rem)
        #expect(SideNavigationSize(saved: 5000).saved == 37.5 * rem)
    }

    @Test func aShortcutForEveryAppNeedsAModifierThatIsNotTyping() {
        let space = BWKeyShortcut.quickAccess
        #expect(space.isValid && space.display == "⇧⌘Space")
        #expect(BWKeyShortcut(keyCode: 40, modifiers: [.control, .option], keyName: "k").display == "⌃⌥K")
        #expect(BWKeyShortcut(keyCode: 40, modifiers: [.control, .option, .shift, .command], keyName: "k").display == "⌃⌥⇧⌘K")
        // A letter alone, or with Shift, is typing.
        #expect(!BWKeyShortcut(keyCode: 40, modifiers: [], keyName: "k").isValid)
        #expect(!BWKeyShortcut(keyCode: 40, modifiers: .shift, keyName: "K").isValid)
        #expect(BWKeyShortcut(keyCode: 40, modifiers: .option, keyName: "k").isValid)
        // A function key may stand alone; a modifier key is no key of a shortcut.
        let f19 = BWKeyShortcut(keyCode: 80, modifiers: [], keyName: "")
        #expect(f19.isValid && f19.display == "F19")
        #expect(!BWKeyShortcut(keyCode: 55, modifiers: .command, keyName: "").isValid)
        #expect(BWKeyShortcut(keyCode: 36, modifiers: .command, keyName: "\r").display == "⌘↩")
        // The same key with the same modifiers is the same shortcut, whatever the layout calls the key.
        #expect(BWKeyShortcut(keyCode: 6, modifiers: .command, keyName: "z") == BWKeyShortcut(keyCode: 6, modifiers: .command, keyName: "y"))
        #expect(BWKeyShortcut(keyCode: 6, modifiers: .command, keyName: "z") != BWKeyShortcut(keyCode: 6, modifiers: .control, keyName: "z"))
        // It is kept as it is.
        let kept = try? JSONDecoder().decode(BWKeyShortcut.self, from: JSONEncoder().encode(space))
        #expect(kept == space && kept?.keyName == " ")
    }

    @Test func textsComeFromTheLocaleFilesInBothLanguages() {
        BWText.configure { $0 = .init(language: "en", productName: "HonkPass") }
        #expect(BWText["unlock"] == "Unlock")
        #expect(BWText["yourVaultIsLockedV2"] == "Your vault is locked")
        #expect(BWText["honkpassConfirmAppFillDescription", "Synthetic Bitwarden login"]
            == "This application will receive credentials from “Synthetic Bitwarden login”.")
        BWText.configure { $0.language = "cs" }
        #expect(BWText["unlock"] == "Odemknout")
        #expect(BWText["autofillConfigurationMessage"] == "Zapíná se automatické vyplňování pomocí HonkPassu…")
        #expect(BWText["yourVaultIsLockedV2"] == "Váš trezor je uzamčen")
        #expect(BWText["honkpassConfirmAppFillDescription", "Synthetic Bitwarden login"]
            == "Do této aplikace se vyplní údaje položky „Synthetic Bitwarden login“.")
    }

    @Test func theProductNameReplacesBitwardenAndPlaceholdersAreFilled() {
        BWText.configure { $0 = .init(language: "en", productName: "HonkPass") }
        #expect(BWText["loginPageEmailEntryScreenTitle"] == "Log in to HonkPass")
        #expect(BWText["passwordProtectedOptionDescription"].contains("Bitwarden clients"))
        #expect(BWText["accessAttemptBy", "a@example.com"] == "Access attempt by a@example.com")
        #expect(BWText["websiteItemLabel", "3"] == "Website 3 (URI)")
        #expect(BWText["honkpassSSHVault", "$SERVER$", "$2"] == "Vault: $SERVER$ ($2)")
        // Another product of Bitwarden keeps its name.
        #expect(BWText["authenticatorAppDescV2"] == "Enter a code generated by an authenticator app like Bitwarden Authenticator.")
        BWText.configure { $0.productName = "Bitwarden" }
        #expect(BWText["loginPageEmailEntryScreenTitle"] == "Log in to Bitwarden")
        BWText.configure { $0.productName = "HonkPass" }
    }

    @Test func theIllustrationsOfTwoStepLoginAreThere() {
        for name in [Illustration.Name.twoFactorAuthenticator, .emailCodeSent] {
            #expect(Illustration.exists(name, dark: false), "\(name.rawValue)")
            #expect(Illustration.exists(name, dark: true), "\(name.rawValue)")
        }
    }

    @Test func themeColoursHaveTheValuesOfTheReference() {
        // The backgrounds measured in docs/reference/lock-*.png.
        #expect(ThemeColor.bgTertiary.dark == 0x020618FF)
        #expect(ThemeColor.bgSecondary.light == 0xF7F9FAFF)
        #expect(ThemeColor.primary600.light == 0x175DDCFF)
    }

    @Test func theFontsLoad() {
        let inter = BWFont.interCT(16, weight: 600)
        #expect(CTFontCopyFamilyName(inter) as String == "Inter Variable")
        #expect(!BWIcon.lock.systemName.isEmpty)
        #expect(BWIcon.lock != BWIcon.eye)
    }

    @Test func technicalProductArgumentsKeepTheirNames() {
        BWText.configure { $0.language = "en"; $0.productName = "HonkPass" }
        #expect(BWText["instructionsFor", "Bitwarden (json)"] == "Bitwarden (json) Instructions")
        #expect(BWText["importHelpCenterInstructions", "Bitwarden"].contains("Bitwarden"))
        #expect(BWText["loginPageEmailEntryScreenTitle"] == "Log in to HonkPass")
    }

    @Test @MainActor func theNativeInterfaceSymbolsAreAvailable() {
        for icon in [BWIcon.lock, .vault, .search, .close, .trash, .archive, .edit, .eye, .key, .generate] {
            #expect(NSImage(systemSymbolName: icon.systemName, accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(icon.systemName)")
        }
    }
}
