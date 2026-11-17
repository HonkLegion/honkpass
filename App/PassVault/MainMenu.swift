import AppKit
import DesignKit

/// The application menu: the structure, the texts and the shortcuts of Bitwarden desktop on macOS
/// (apps/desktop/src/main/menu). The menus themselves are native (PLAN.md, allowed deviations).
///
/// An item without an action is something PassVault does not have yet: it is shown disabled.
/// The app delegate enables the others by the state of the engine (`validateMenuItem`).
@MainActor
enum MainMenu {
    /// The submenus that list the account; the app delegate fills them when they open.
    static let lockMenuIdentifier = NSUserInterfaceItemIdentifier("lockVault")
    static let logOutMenuIdentifier = NSUserInterfaceItemIdentifier("logOut")

    static func build(delegate: any NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(application(delegate))
        main.addItem(file())
        main.addItem(edit())
        main.addItem(view())
        main.addItem(account())
        main.addItem(window())
        main.addItem(help())
        return main
    }

    // MARK: Menus

    /// menu.bitwarden.ts
    private static func application(_ delegate: any NSMenuDelegate) -> NSMenuItem {
        let menu = NSMenu(title: BWText.settings.productName)
        let about = item("aboutBitwarden", #selector(LegalInformation.showAbout(_:)))
        about.target = LegalInformation.shared
        menu.addItem(about)
        let licenses = item("honkpassLicensesAndSource", #selector(LegalInformation.showLicenses(_:)))
        licenses.target = LegalInformation.shared
        menu.addItem(licenses)
        menu.addItem(item("checkForUpdates", #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("preferences", #selector(AppDelegate.openSettings(_:)), key: ","))
        menu.addItem(accountList("lockVault", lockMenuIdentifier, delegate))
        menu.addItem(item("lockAllVaults", #selector(AppDelegate.lockVault(_:)), key: "l"))
        menu.addItem(accountList("logOut", logOutMenuIdentifier, delegate))
        menu.addItem(.separator())
        let services = NSMenu(title: BWText["services"])
        NSApp.servicesMenu = services
        menu.addItem(parent("services", services))
        menu.addItem(.separator())
        menu.addItem(item("hideBitwarden", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(item("hideOthers", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        menu.addItem(item("showAll", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("quitBitwarden", #selector(NSApplication.terminate(_:)), key: "q"))
        return parent(title: BWText.settings.productName, menu)
    }

    /// menu.file.ts. Import and export come later.
    private static func file() -> NSMenuItem {
        let menu = NSMenu(title: BWText["file"])
        menu.addItem(item("addNewLogin", #selector(AppDelegate.newLogin(_:)), key: "n"))
        let newItem = NSMenu(title: BWText["addNewItem"])
        let types: [(String, Selector?, String)] = [
            ("typeLogin", #selector(AppDelegate.newLogin(_:)), "l"), ("typeCard", #selector(AppDelegate.newCard(_:)), "c"),
            ("typeIdentity", #selector(AppDelegate.newIdentity(_:)), "i"), ("typeNote", #selector(AppDelegate.newNote(_:)), "s"),
            ("typeSshKey", #selector(AppDelegate.newSSHKey(_:)), "k"),
        ]
        for (key, action, shortcut) in types {
            newItem.addItem(item(key, action, key: shortcut, modifiers: [.command, .shift]))
        }
        menu.addItem(parent("addNewItem", newItem))
        menu.addItem(item("newFolder", #selector(AppDelegate.newFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("syncNow", #selector(AppDelegate.syncVault(_:))))
        menu.addItem(item("importNoun", #selector(AppDelegate.importVault(_:))))
        menu.addItem(item("exportNoun", #selector(AppDelegate.exportVault(_:))))
        return parent("file", menu)
    }

    /// menu.edit.ts. The three copy items take the field from the item whose panel is open.
    private static func edit() -> NSMenuItem {
        let menu = NSMenu(title: BWText["edit"])
        menu.addItem(item("undo", Selector(("undo:")), key: "z"))
        menu.addItem(item("redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(.separator())
        menu.addItem(item("selectAll", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(item("copyUsername", #selector(AppDelegate.copyUsername(_:)), key: "u"))
        menu.addItem(item("copyPassword", #selector(AppDelegate.copyPassword(_:)), key: "p"))
        menu.addItem(item("copyVerificationCodeTotp", #selector(AppDelegate.copyVerificationCode(_:)), key: "t"))
        return parent("edit", menu)
    }

    /// menu.view.ts. The generator comes with M2. Zoom and reload belong to the web page the
    /// reference is; PassVault has no counterpart.
    private static func view() -> NSMenuItem {
        let menu = NSMenu(title: BWText["view"])
        menu.addItem(item("searchVault", #selector(AppDelegate.searchVault(_:)), key: "f"))
        menu.addItem(.separator())
        menu.addItem(item("generator", #selector(AppDelegate.openGenerator(_:)), key: "g"))
        menu.addItem(item("generatorHistory", #selector(AppDelegate.openGeneratorHistory(_:))))
        menu.addItem(.separator())
        menu.addItem(item("zoomIn", nil, key: "="))
        menu.addItem(item("zoomOut", nil, key: "-"))
        menu.addItem(item("resetZoom", nil, key: "0"))
        menu.addItem(.separator())
        menu.addItem(item("toggleFullScreen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("reload", nil))
        return parent("view", menu)
    }

    /// menu.account.ts. "Premium membership" is there only for an account without premium, which
    /// a Vaultwarden account never is.
    private static func account() -> NSMenuItem {
        let menu = NSMenu(title: BWText["account"])
        menu.addItem(item("changeMasterPass", #selector(AppDelegate.changeMasterPassword(_:))))
        menu.addItem(item("twoStepLogin", #selector(AppDelegate.openTwoStepLogin(_:))))
        menu.addItem(item("fingerprintPhrase", #selector(AppDelegate.showFingerprintPhrase(_:))))
        menu.addItem(.separator())
        menu.addItem(item("deleteAccount", nil))
        return parent("account", menu)
    }

    /// menu.window.ts
    private static func window() -> NSMenuItem {
        let menu = NSMenu(title: BWText["window"])
        menu.addItem(item("minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("hideToMenuBar", #selector(AppDelegate.hideToMenuBar(_:)), key: "m", modifiers: [.command, .shift]))
        menu.addItem(item("alwaysOnTop", #selector(AppDelegate.toggleAlwaysOnTop(_:)), key: "t", modifiers: [.command, .shift]))
        menu.addItem(item("zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("bringAllToFront", #selector(NSApplication.arrangeInFront(_:))))
        menu.addItem(.separator())
        menu.addItem(item("close", #selector(NSWindow.performClose(_:)), key: "w"))
        NSApp.windowsMenu = menu
        return parent("window", menu)
    }

    /// menu.help.ts. The help pages, the bug tracker, the news and the other apps are Bitwarden's
    /// own; PassVault has none of its own yet. The web vault is the one of the account's server.
    private static func help() -> NSMenuItem {
        let menu = NSMenu(title: BWText["help"])
        menu.addItem(item("helpAndFeedback", nil))
        menu.addItem(item("fileBugReport", nil))
        menu.addItem(.separator())
        menu.addItem(parent("followUs", list([BWText["blog"], "Twitter", "Facebook", "GitHub", "Mastodon"]), isEnabled: false))
        menu.addItem(.separator())
        menu.addItem(item("goToWebVault", #selector(AppDelegate.openWebVault(_:))))
        menu.addItem(.separator())
        menu.addItem(parent("getMobileApp", list(["iOS", "Android"]), isEnabled: false))
        menu.addItem(parent("getBrowserExtension", list(["Chrome", "Firefox", "Opera", "Edge", "Safari"]), isEnabled: false))
        menu.addItem(.separator())
        let troubleshooting = NSMenu(title: BWText["troubleshooting"])
        troubleshooting.addItem(item("disableHardwareAccelerationRestart", nil))
        troubleshooting.addItem(item("downloadDiagnosticReport", nil))
        menu.addItem(parent("troubleshooting", troubleshooting, isEnabled: false))
        NSApp.helpMenu = menu
        return parent("help", menu)
    }

    // MARK: Parts

    /// One item with the text of a locale key. Without an action it stays disabled.
    private static func item(_ key: String, _ action: Selector?, key shortcut: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: BWText[key], action: action, keyEquivalent: shortcut)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func parent(_ key: String, _ submenu: NSMenu, isEnabled: Bool = true) -> NSMenuItem {
        let item = parent(title: BWText[key], submenu)
        item.isEnabled = isEnabled
        return item
    }

    private static func parent(title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        return item
    }

    /// A submenu with one item for the account, made when it opens.
    private static func accountList(_ key: String, _ identifier: NSUserInterfaceItemIdentifier,
                                    _ delegate: any NSMenuDelegate) -> NSMenuItem {
        let submenu = NSMenu(title: BWText[key])
        submenu.identifier = identifier
        submenu.delegate = delegate
        return parent(key, submenu)
    }

    private static func list(_ titles: [String]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
}
