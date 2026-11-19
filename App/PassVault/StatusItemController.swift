import AppKit
import DesignKit

/// The system owns the menu's glass, placement and keyboard handling. Actions reuse the same
/// commands as the main window and global shortcuts.
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let showMainWindow: () -> Void
    private let showQuickAccess: () -> Void
    private let autofill: () -> Void
    private let lockVault: () -> Void
    private let openSettings: () -> Void
    private let isUnlocked: () -> Bool
    private let menu = NSMenu()

    init(showMainWindow: @escaping () -> Void, showQuickAccess: @escaping () -> Void,
         autofill: @escaping () -> Void, lockVault: @escaping () -> Void,
         openSettings: @escaping () -> Void, isUnlocked: @escaping () -> Bool) {
        self.showMainWindow = showMainWindow
        self.showQuickAccess = showQuickAccess
        self.autofill = autofill
        self.lockVault = lockVault
        self.openSettings = openSettings
        self.isUnlocked = isUnlocked
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // The menu bar measures the image itself when it chooses the symbol's drawing size.
        let symbol = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: BWText.settings.productName)?
            .withSymbolConfiguration(.init(pointSize: Metric.statusItemSymbolSize, weight: .medium))
        symbol?.isTemplate = true
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = symbol
        statusItem.button?.toolTip = BWText.settings.productName
        add(.show, "honkpassOpenMainWindow", #selector(show))
        add(.quickAccess, "honkpassOpenQuickAccess", #selector(quickAccess))
        add(.autofill, "autofillVerb", #selector(fill))
        menu.addItem(.separator())
        add(.lock, "lockVault", #selector(lock))
        add(.settings, "preferences", #selector(settings))
        menu.addItem(.separator())
        add(.exit, "exit", #selector(quit))
        statusItem.menu = menu
    }

    var isInstalled: Bool { statusItem.button?.window != nil }
    #if DEBUG
    var menuActions: [Item] { menu.items.filter { !$0.isSeparatorItem }.compactMap { Item(rawValue: $0.tag) } }
    #endif

    /// The item is in the menu bar. Without "keep running in the background" it is not.
    var isShown: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    enum Item: Int {
        case show = 1, exit, quickAccess, autofill, lock, settings
    }

    /// Does what a click on a menu item does. Returns false when the item is missing or disabled.
    func perform(_ item: Item) -> Bool {
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.tag == item.rawValue }), menu.items[index].isEnabled else {
            return false
        }
        menu.performActionForItem(at: index)
        return true
    }

    private func add(_ item: Item, _ key: String, _ action: Selector) {
        let menuItem = NSMenuItem(title: BWText[key], action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = item.rawValue
        menu.addItem(menuItem)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch Item(rawValue: menuItem.tag) {
        case .lock, .settings: return isUnlocked()
        default: return true
        }
    }

    @objc private func quickAccess() {
        showQuickAccess()
    }

    @objc private func fill() { autofill() }
    @objc private func lock() { lockVault() }
    @objc private func settings() { openSettings() }

    @objc private func show() {
        showMainWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
