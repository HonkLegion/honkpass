import AppKit
import DesignKit
import Foundation
import EngineLive
import Observation

/// What the user has set for the app on this Mac, for every account: how it looks and how its
/// windows behave. The settings the engine acts on are `EngineSettings`.
///
/// PassVault shares its preferences domain with HonkPass, so the keys carry its name.
@MainActor @Observable
final class AppPreferences {
    var updater: MacAppUpdater?

    enum Theme: String, CaseIterable {
        case system, light, dark
    }

    var theme: Theme {
        didSet {
            defaults?.set(theme.rawValue, forKey: Key.theme)
            applyTheme()
        }
    }
    /// "en" or "cs"; nil follows the language of the system. A change shows after a restart.
    var language: String? {
        didSet { defaults?.set(language, forKey: Key.language) }
    }
    /// The main window leaves the screen after a value of an item was copied.
    var minimizesOnCopy: Bool {
        didSet { defaults?.set(minimizesOnCopy, forKey: Key.minimizesOnCopy) }
    }

    /// The main window stays over the windows of other apps.
    /// The user has closed the note at the top of the generator.
    var hidesGeneratorNudge: Bool {
        didSet { defaults?.set(hidesGeneratorNudge, forKey: Key.hidesGeneratorNudge) }
    }

    var isAlwaysOnTop: Bool {
        didSet { defaults?.set(isAlwaysOnTop, forKey: Key.isAlwaysOnTop) }
    }

    /// Enabled by default to preserve the existing shortcut behavior.
    var isQuickAccessShortcutOn: Bool {
        didSet {
            guard isQuickAccessShortcutOn != oldValue else { return }
            defaults?.set(isQuickAccessShortcutOn, forKey: Key.isQuickAccessShortcutOn)
            onQuickAccessShortcutChanged?()
        }
    }

    /// The shortcut that opens quick access in every app.
    var quickAccessShortcut: BWKeyShortcut {
        didSet {
            guard quickAccessShortcut != oldValue else { return }
            defaults?.set(try? JSONEncoder().encode(quickAccessShortcut), forKey: Key.quickAccessShortcut)
            onQuickAccessShortcutChanged?()
        }
    }
    /// false when the system did not give PassVault the shortcut: another app has it.
    var isQuickAccessShortcutAvailable = true
    /// A new shortcut is being typed in the settings: the one in use must not answer meanwhile.
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            onQuickAccessShortcutChanged?()
            onFillShortcutChanged?()
        }
    }
    /// Called when the shortcut has to be taken from the system anew, or given back.
    @ObservationIgnored var onQuickAccessShortcutChanged: (() -> Void)?

    /// The two shortcuts that work in every app.
    enum Shortcut {
        /// Opens quick access.
        case quickAccess
        /// Fills the login of the page in front without the panel.
        case fill
    }

    /// The shortcut that fills is on. It is off until the user turns it on, as the autotype
    /// shortcut of the reference.
    var isFillShortcutOn: Bool {
        didSet {
            guard isFillShortcutOn != oldValue else { return }
            defaults?.set(isFillShortcutOn, forKey: Key.isFillShortcutOn)
            onFillShortcutChanged?()
            if isFillShortcutOn { onFillShortcutEnabled?() }
        }
    }
    var fillShortcut: BWKeyShortcut {
        didSet {
            guard fillShortcut != oldValue else { return }
            defaults?.set(try? JSONEncoder().encode(fillShortcut), forKey: Key.fillShortcut)
            onFillShortcutChanged?()
        }
    }
    /// false when the shortcut is on and the system did not give it: another app has it.
    var isFillShortcutAvailable = true
    @ObservationIgnored var onFillShortcutChanged: (() -> Void)?
    @ObservationIgnored var onFillShortcutEnabled: (() -> Void)?

    func shortcut(_ which: Shortcut) -> BWKeyShortcut {
        which == .quickAccess ? quickAccessShortcut : fillShortcut
    }

    func isAvailable(_ which: Shortcut) -> Bool {
        which == .quickAccess ? isQuickAccessShortcutAvailable : isFillShortcutAvailable
    }

    /// Makes a shortcut the one of quick access or of the fill. false when it is no shortcut,
    /// when it is the other of the two, or when the system does not give it because another
    /// app has it; the one in use stays then.
    func set(_ shortcut: BWKeyShortcut, for which: Shortcut) -> Bool {
        guard shortcut != self.shortcut(which == .quickAccess ? .fill : .quickAccess) else { return false }
        guard which == .fill else { return setQuickAccessShortcut(shortcut) }
        guard shortcut.isValid, canTakeShortcut?(shortcut) ?? true else { return false }
        fillShortcut = shortcut
        return true
    }
    /// Asks the system whether PassVault can have a shortcut. nil in a test or picture run,
    /// which takes no shortcut: every valid one counts as free there.
    @ObservationIgnored var canTakeShortcut: ((BWKeyShortcut) -> Bool)?

    /// PassVault opens when the user logs in to the Mac. The system says it; no preference is
    /// stored. nil for the setter in a test or picture run, which changes nothing in the system.
    var isOpenAtLoginOn = false
    @ObservationIgnored var setOpenAtLogin: ((Bool) -> Void)?

    /// The windows may be captured in screenshots and seen in remote sessions.
    var allowsScreenshots: Bool {
        didSet {
            guard allowsScreenshots != oldValue else { return }
            defaults?.set(allowsScreenshots, forKey: Key.allowsScreenshots)
            onAllowsScreenshotsChanged?()
        }
    }
    @ObservationIgnored var onAllowsScreenshotsChanged: (() -> Void)?

    /// "Keep running in the background": the app stays in the menu bar when its window is
    /// closed. Without it the menu bar item is gone and closing the window quits the app, as
    /// in the reference (tray.main.ts).
    var runsInBackground: Bool {
        didSet {
            guard runsInBackground != oldValue else { return }
            defaults?.set(runsInBackground, forKey: Key.runsInBackground)
            onRunsInBackgroundChanged?()
        }
    }
    @ObservationIgnored var onRunsInBackgroundChanged: (() -> Void)?

    /// "Show quick copy actions in vault": a login and a card have a copy button for each of
    /// their fields in the list. Without it they have one button with a menu.
    var showsQuickCopyActions: Bool {
        didSet { defaults?.set(showsQuickCopyActions, forKey: Key.showsQuickCopyActions) }
    }

    /// The system's AutoFill takes its logins from PassVault: the launch agent through which
    /// the AutoFill extension finds the app is registered and allowed. The system says it; no
    /// preference is stored.
    var isAutoFillOn = false
    /// Turns the system's AutoFill on or off. nil in a test or picture run, which changes
    /// nothing in the system: the row of the settings is shown and does nothing there.
    @ObservationIgnored var setAutoFillOn: ((Bool) -> Void)?
    /// Opens the settings of the system where the user turns the extension on and off.
    @ObservationIgnored var openAutoFillSettings: (() -> Void)?

    /// Makes a shortcut the one of quick access. false when it is no shortcut, or when the
    /// system does not give it because another app has it; the one in use stays then.
    func setQuickAccessShortcut(_ shortcut: BWKeyShortcut) -> Bool {
        guard shortcut.isValid, canTakeShortcut?(shortcut) ?? true else { return false }
        quickAccessShortcut = shortcut
        return true
    }

    /// The width the user gave the side navigation, in points. nil until its handle was used.
    var sideNavigationWidth: Double? {
        didSet { defaults?.set(sideNavigationWidth, forKey: Key.sideNavigationWidth) }
    }

    /// nil in test and picture runs, which must leave no trace in the user's preferences.
    @ObservationIgnored private let defaults: UserDefaults?
    /// A picture run fixes the appearance on the command line; the theme then changes nothing.
    @ObservationIgnored var isAppearanceFixed = false

    private enum Key {
        static let theme = "PassVault.theme"
        static let language = "PassVault.language"
        static let minimizesOnCopy = "PassVault.minimizesOnCopy"
        static let isAlwaysOnTop = "PassVault.alwaysOnTop"
        static let hidesGeneratorNudge = "PassVault.hidesGeneratorNudge"
        static let sideNavigationWidth = "PassVault.sideNavigationWidth"
        static let quickAccessShortcut = "PassVault.quickAccessShortcut"
        static let isQuickAccessShortcutOn = "PassVault.isQuickAccessShortcutOn"
        static let isFillShortcutOn = "PassVault.isFillShortcutOn"
        static let allowsScreenshots = "PassVault.allowsScreenshots"
        static let fillShortcut = "PassVault.fillShortcut"
        static let runsInBackground = "PassVault.runsInBackground"
        static let showsQuickCopyActions = "PassVault.showsQuickCopyActions"
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        theme = defaults?.string(forKey: Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        language = defaults?.string(forKey: Key.language)
        minimizesOnCopy = defaults?.bool(forKey: Key.minimizesOnCopy) ?? false
        isAlwaysOnTop = defaults?.bool(forKey: Key.isAlwaysOnTop) ?? false
        hidesGeneratorNudge = defaults?.bool(forKey: Key.hidesGeneratorNudge) ?? false
        sideNavigationWidth = defaults?.object(forKey: Key.sideNavigationWidth) as? Double
        // A stored shortcut that cannot be read, or is none, is the usual one again.
        let stored = defaults?.data(forKey: Key.quickAccessShortcut).flatMap { try? JSONDecoder().decode(BWKeyShortcut.self, from: $0) }
        quickAccessShortcut = stored.flatMap { $0.isValid ? $0 : nil } ?? .quickAccess
        isQuickAccessShortcutOn = (defaults?.object(forKey: Key.isQuickAccessShortcutOn) as? Bool) ?? true
        isFillShortcutOn = defaults?.bool(forKey: Key.isFillShortcutOn) ?? false
        // The reference allows the capture until the user turns it off.
        allowsScreenshots = (defaults?.object(forKey: Key.allowsScreenshots) as? Bool) ?? true
        // The defaults of the reference: in the background, and one copy button ("combined").
        runsInBackground = (defaults?.object(forKey: Key.runsInBackground) as? Bool) ?? true
        showsQuickCopyActions = defaults?.bool(forKey: Key.showsQuickCopyActions) ?? false
        let storedFill = defaults?.data(forKey: Key.fillShortcut).flatMap { try? JSONDecoder().decode(BWKeyShortcut.self, from: $0) }
        fillShortcut = storedFill.flatMap { $0.isValid ? $0 : nil } ?? .fill
    }

    /// Gives the app the appearance of the theme. The system theme follows macOS.
    func applyTheme() {
        guard !isAppearanceFixed else { return }
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
