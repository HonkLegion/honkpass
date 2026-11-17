import AppKit
import DesignKit
import Engine
import EngineFakes
import EngineLive
import ServiceManagement
import VaultModel

/// The composition root. It creates the engine first and the clients after it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let launch: LaunchOptions
    private let model: AppModel
    /// The engine, for the clients that are no windows: the AutoFill extension asks it.
    private let engine: Engine
    private let flow: LogInFlow
    private let preferences: AppPreferences
    private let navigation = VaultNavigation()
    private var appUpdater: MacAppUpdater?
    private var mainWindow: MainWindowController?
    private var statusItem: StatusItemController?
    private var quickAccess: QuickAccessPanelController?
    private var sshApprovalWindow: SSHApprovalWindowController?
    /// The app's side of the system's AutoFill. A test or picture run has none: it must not
    /// take the place of the app the user runs.
    private var autoFill: AutoFillController?
    /// The field the fake backend fills in place of a field of another app, for the smoke test.
    private var fakeActiveField: FakeActiveField?
    /// The SSH agent of a test or picture run: it has no socket, and the run asks through it
    /// what an SSH client would ask.
    private var fakeSSHAgent: FakeSSHAgent?
    /// The Keychain behind Touch ID of a test or picture run: it is none, so the run asks for
    /// no finger and leaves no key in the Keychain of the user.
    private var fakeBiometrics: FakeBiometricKeys?
    /// The server of the fake backend, which a test or a picture can hold half way through an upload.
    private var fakeServer: FakeServer?
    /// The shortcut of quick access. nil in test and picture runs, and when the system refuses it.
    private var quickAccessHotKey: GlobalHotKey?
    /// The shortcut that fills without the panel. nil while it is off, and as above.
    private var fillHotKey: GlobalHotKey?
    private var activityMonitor: Any?
    private var lastActivityNote = Date.distantPast

    override init() {
        let launch = LaunchOptions(arguments: CommandLine.arguments)
        self.launch = launch
        let isDevelopmentRun = launch.isDevelopmentRun
        flow = LogInFlow(defaults: isDevelopmentRun ? nil : .standard)
        let preferences = AppPreferences(defaults: isDevelopmentRun ? nil : .standard)
        preferences.isAppearanceFixed = launch.appearance != nil
        // The pictures of the reference were taken with the quick copy buttons on.
        if isDevelopmentRun { preferences.showsQuickCopyActions = true }
        self.preferences = preferences
        // The engine exists from the start of the process, before and without any window.
        let ports: EnginePorts
        var notices: [EngineNotice] = []
        var fakeAccount: FakeAccount = launch.fakeAccountHasTwoStep ? .demoWithTwoStep : .demo
        #if DEBUG
        if launch.usesFakeBackend, launch.scene == "vault-performance" {
            fakeAccount = VaultPerformanceProbe.account
        }
        if launch.usesFakeBackend, launch.scene == "vault-empty" {
            fakeAccount.contents = .empty
        }
        if launch.usesFakeBackend, let scene = launch.scene,
           ["quick-access-compact", "quick-access-single-vault"].contains(scene) {
            let multiple = launch.scene == "quick-access-compact"
            fakeAccount.contents = VaultContents(items: [
                VaultItemSummary(id: "quick-personal", type: .login, name: "Example Shop", subtitle: "alex@example.test",
                                 fields: [.username, .password, .website], websites: [.init(address: "https://shop.example.test")]),
                VaultItemSummary(id: "quick-work", type: .login, name: "Example Shop · práce", subtitle: "alex.work@example.test",
                                 fields: [.username, .password, .website], websites: [.init(address: "https://shop.example.test")],
                                 organizationID: multiple ? "quick-work-vault" : nil),
                VaultItemSummary(id: "quick-admin", type: .login, name: "Example Shop · admin", subtitle: "admin@example.test",
                                 fields: [.username, .password, .website], websites: [.init(address: "https://shop.example.test")]),
            ], folders: [], organizations: multiple ? [VaultOrganization(id: "quick-work-vault", name: "Práce")] : [])
        }
        #endif
        if launch.usesFakeBackend {
            let fake = EnginePorts.fake(fakeAccount)
            var fakePorts = fake.ports
            if launch.scene == "auth-feedback" {
                fakePorts.crypto = FakeCrypto(authenticationDelay: .seconds(5))
            }
            // The check of filling writes into its fixture app through the real port.
            if launch.runsFillCheck { fakePorts.activeField = MacActiveField() }
            ports = fakePorts
            fakeActiveField = fake.handles.activeField
            fakeSSHAgent = fake.handles.sshAgent
            fakeBiometrics = fake.handles.biometrics
            fakeServer = fake.handles.server
        } else {
            // Test and picture runs keep the account in memory, so they never touch the user's session.
            var store: any AccountStorePort = InMemoryAccountStore()
            if !isDevelopmentRun {
                do {
                    store = try FileAccountStore.applicationStore()
                } catch {
                    // Without its folder the app still works, but forgets the log-in at its end.
                    notices.append(.storeUnavailable)
                }
            }
            // A test or picture run asks no outside service.
            let leaks: any PasswordLeaksPort = isDevelopmentRun ? FakePasswordLeaks() : PwnedPasswords()
            // A test or picture run looks at no field of another app and writes into none.
            let activeField: any ActiveFieldPort = isDevelopmentRun ? NoActiveField() : MacActiveField()
            // And it leaves no entry in the store of the system's AutoFill.
            let identities: any CredentialIdentitiesPort = isDevelopmentRun ? NoCredentialIdentities() : SystemCredentialIdentities()
            // And it makes no socket in the home folder of the user.
            let withoutSocket = FakeSSHAgent()
            if isDevelopmentRun { fakeSSHAgent = withoutSocket }
            let sshAgent: any SSHAgentPort = isDevelopmentRun ? withoutSocket : UnixSSHAgentSocket()
            // And it asks for no finger and keeps no key in the Keychain of the user.
            let withoutKeychain = FakeBiometricKeys()
            if isDevelopmentRun { fakeBiometrics = withoutKeychain }
            let biometrics: any BiometricKeysPort = isDevelopmentRun ? withoutKeychain : KeychainBiometricKeys()
            // The signature of an app the user chose is read in every run: it changes nothing.
            ports = EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                systemEvents: MacSystemEvents(), clipboard: MacClipboard(), leaks: leaks,
                                activeField: activeField, identities: identities, sshAgent: sshAgent,
                                appSignatures: MacAppSignatures(), biometrics: biometrics,
                                avatars: isDevelopmentRun ? NoAccountAvatars() : Gravatar())
        }
        #if DEBUG
        // The scene "notices" shows what the window says about each of them.
        if launch.scene == "notices" { notices = [.sessionExpired, .storedAccountUnreadable, .storedSettingsUnreadable] }
        #endif
        let engine: Engine
        #if DEBUG
        if launch.usesFakeBackend, launch.scene?.hasPrefix("ssh-approval") == true {
            engine = Engine(ports: ports, clock: SSHApprovalPreviewClock(), notices: notices)
        } else { engine = Engine(ports: ports, notices: notices) }
        #else
        engine = Engine(ports: ports, notices: notices)
        #endif
        self.engine = engine
        model = AppModel(engine: engine, prefill: launch.usesFakeBackend ? fakeAccount : nil)
        if !isDevelopmentRun { autoFill = AutoFillController(engine: engine) }
        BWText.configure { settings in
            // The command line wins over the chosen language; without both, the system language stays.
            if let language = launch.language ?? preferences.language, BWText.supportedLanguages.contains(language) {
                settings.language = language
            }
            if let productName = launch.productName { settings.productName = productName }
        }
        super.init()
        if let server = launch.server { flow.serverURL = server }
        model.onVaultClosed = { [navigation] in navigation.closeItemViews() }
        navigation.sideNavigation = SideNavigationSize(saved: preferences.sideNavigationWidth.map { CGFloat($0) })
        navigation.onSideNavigationWidthChosen = { [preferences] width in preferences.sideNavigationWidth = Double(width) }
        model.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = launch.appearance {
            NSApp.appearance = NSAppearance(named: appearance)
        } else {
            preferences.applyTheme()
        }
        let mainWindow = MainWindowController(model: model, flow: flow, navigation: navigation, preferences: preferences,
                                              size: launch.windowSize, remembersFrame: !launch.isDevelopmentRun)
        navigation.afterCopy = { [preferences, weak mainWindow] in
            if preferences.minimizesOnCopy { mainWindow?.window.miniaturize(nil) }
        }
        // Quick access shows an item in the main window: all items, no search, the item open.
        let quickAccess = QuickAccessPanelController(model: model, showMainWindow: { [weak self] in
            self?.showMainWindow(nil)
        }, openItem: { [weak self, navigation] id in
            navigation.leaveForm {
                navigation.itemForm = nil
                navigation.filter = .allItems
                navigation.search = ""
                navigation.openItemID = id
            }
            self?.showMainWindow(nil)
        }, inMainWindow: { [weak self, model, navigation] action in
            action(ItemActions(model: model, navigation: navigation))
            self?.showMainWindow(nil)
        })
        self.quickAccess = quickAccess
        // A lock or a logout also ends what the panel had open.
        model.onVaultClosed = { [navigation, weak quickAccess] in
            navigation.closeItemViews()
            quickAccess?.navigation.closeItemViews()
        }
        let sshApprovalWindow = SSHApprovalWindowController(model: model, preferences: preferences)
        self.sshApprovalWindow = sshApprovalWindow
        model.onSSHStateChanged = { [weak sshApprovalWindow] in sshApprovalWindow?.update() }
        sshApprovalWindow.update()
        let statusItem = StatusItemController(showMainWindow: { [weak self, weak quickAccess] in
                                                  quickAccess?.close()
                                                  self?.showMainWindow(nil)
                                              },
                                              showQuickAccess: { [weak quickAccess] in quickAccess?.show() },
                                              autofill: { [weak quickAccess] in quickAccess?.fillFromShortcut() },
                                              lockVault: { [weak self] in self?.lockVault(nil) },
                                              openSettings: { [weak self, weak quickAccess] in
                                                  quickAccess?.close()
                                                  self?.openSettings(nil)
                                              },
                                              isUnlocked: { [weak model] in model?.state.session.isUnlocked == true })
        // A test or picture run takes no key combination from the other apps of the user.
        if !launch.usesFakeBackend, !launch.runsSmokeTest, launch.scene == nil {
            preferences.onQuickAccessShortcutChanged = { [weak self] in self?.takeQuickAccessShortcut() }
            preferences.canTakeShortcut = { [weak self] shortcut in self?.canTake(shortcut) ?? false }
            takeQuickAccessShortcut()
            preferences.onFillShortcutChanged = { [weak self] in self?.takeFillShortcut() }
            takeFillShortcut()
        }
        // The windows can be kept out of screenshots and remote sessions.
        preferences.onAllowsScreenshotsChanged = { [weak self] in self?.applyScreenshotSetting() }
        if !launch.usesFakeBackend, !launch.runsSmokeTest, launch.scene == nil {
            // "Open at login": the system keeps the app among the items it opens.
            preferences.isOpenAtLoginOn = SMAppService.mainApp.status == .enabled
            preferences.setOpenAtLogin = { [weak self] isOn in
                do {
                    if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    self?.navigation.toasts.show(.error, message: BWText["errorOccurred"])
                }
                self?.preferences.isOpenAtLoginOn = SMAppService.mainApp.status == .enabled
            }
        }
        if let autoFill {
            // The switch of the settings: the system's AutoFill takes its logins from PassVault.
            preferences.isAutoFillOn = autoFill.isOn
            preferences.setAutoFillOn = { [weak self] isOn in
                Task {
                    await autoFill.setOn(isOn)
                    self?.preferences.isAutoFillOn = autoFill.isOn
                }
            }
            preferences.openAutoFillSettings = { autoFill.openSystemSettings() }
            Task { await autoFill.start() }
        }
        self.mainWindow = mainWindow
        applyScreenshotSetting()
        self.statusItem = statusItem
        // "Keep running in the background": the menu bar item is there only with it, and
        // without it closing the window quits the app, as in the reference.
        statusItem.isShown = preferences.runsInBackground
        preferences.onRunsInBackgroundChanged = { [weak self] in
            guard let self else { return }
            self.statusItem?.isShown = self.preferences.runsInBackground
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: mainWindow.window,
                                               queue: .main) { [weak self] _ in
            // Wait for the close to finish. A reopen in the same turn must keep its Dock entry.
            DispatchQueue.main.async { [weak self] in
                guard let self, let mainWindow = self.mainWindow,
                      !mainWindow.isVisible, !mainWindow.window.isMiniaturized else { return }
                if self.preferences.runsInBackground {
                    NSApp.setActivationPolicy(.accessory)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        #if !DEBUG
        if !launch.isDevelopmentRun {
            appUpdater = MacAppUpdater(prepare: { [weak self] in
                guard let self else { return false }
                let navigations = [self.navigation, self.quickAccess?.navigation].compactMap { $0 }
                guard !navigations.contains(where: {
                    $0.itemForm != nil || $0.sendForm != nil || $0.isImporting || $0.isExporting
                }) else {
                    self.showUpdateBlocked()
                    return false
                }
                do {
                    try await self.engine.prepareForAppUpdate()
                    return true
                } catch {
                    self.showUpdateBlocked()
                    return false
                }
            }, recover: { [engine] in
                await engine.resumeAfterAppUpdate()
            })
        }
        #endif
        NSApp.mainMenu = MainMenu.build(delegate: self)
        mainWindow.window.level = preferences.isAlwaysOnTop ? .floating : .normal
        installActivityMonitor()
        mainWindow.show()

        #if DEBUG
        if launch.runsFillCheck {
            FillCheck(model: model).run()
        } else if launch.runsSmokeTest {
            SmokeTest(model: model, navigation: navigation, mainWindow: mainWindow, statusItem: statusItem,
                      quickAccess: quickAccess, preferences: preferences, fakeActiveField: fakeActiveField,
                      fakeSSHAgent: fakeSSHAgent, fakeBiometrics: fakeBiometrics, fakeServer: fakeServer,
                      sshApprovalWindow: sshApprovalWindow).run()
        } else if let scene = launch.scene {
            SceneDriver(model: model, flow: flow, navigation: navigation, mainWindow: mainWindow, quickAccess: quickAccess,
                        autoFill: EngineAnswers(engine: engine), fakeSSHAgent: fakeSSHAgent, preferences: preferences,
                        fakeBiometrics: fakeBiometrics, fakeServer: fakeServer, fakeActiveField: fakeActiveField,
                        sshApprovalWindow: sshApprovalWindow)
                .open(scene)
        }
        #endif
    }

    /// Takes the shortcut of quick access from the system, after it gave back the one it had.
    /// While a new one is typed in the settings none is taken. When another app has the
    /// shortcut, the settings say so.
    private func takeQuickAccessShortcut() {
        quickAccessHotKey?.release()
        quickAccessHotKey = nil
        guard preferences.isQuickAccessShortcutOn else {
            preferences.isQuickAccessShortcutAvailable = true
            return
        }
        guard !preferences.isRecordingShortcut else { return }
        quickAccessHotKey = GlobalHotKey(preferences.quickAccessShortcut) { [weak self] in self?.quickAccess?.toggle() }
        preferences.isQuickAccessShortcutAvailable = quickAccessHotKey != nil
    }

    /// A window that may not be captured is left out of screenshots and remote sessions.
    private func applyScreenshotSetting() {
        let sharing: NSWindow.SharingType = preferences.allowsScreenshots ? .readOnly : .none
        mainWindow?.window.sharingType = sharing
        quickAccess?.window.sharingType = sharing
        sshApprovalWindow?.window?.sharingType = sharing
    }

    /// The same for the shortcut that fills, which is taken only while the user has it on.
    private func takeFillShortcut() {
        fillHotKey?.release()
        fillHotKey = nil
        guard preferences.isFillShortcutOn else {
            preferences.isFillShortcutAvailable = true
            return
        }
        guard !preferences.isRecordingShortcut else { return }
        fillHotKey = GlobalHotKey(preferences.fillShortcut) { [weak self] in self?.quickAccess?.fillFromShortcut() }
        preferences.isFillShortcutAvailable = fillHotKey != nil
    }

    /// Whether the system gives PassVault this shortcut: it is taken and given back at once.
    /// The one in use is given back first; it is taken again when the dialog closes.
    private func canTake(_ shortcut: BWKeyShortcut) -> Bool {
        quickAccessHotKey?.release()
        quickAccessHotKey = nil
        guard let probe = GlobalHotKey(shortcut, action: {}) else { return false }
        probe.release()
        return true
    }

    /// Closing the main window ends nothing here: the engine and the menu bar item stay. The
    /// window itself quits the app when the user has turned "keep running in the background" off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may come back from the settings of the system, where the agent is allowed.
        autoFill?.startIfNeeded()
        if let autoFill { preferences.isAutoFillOn = autoFill.isOn }
        if preferences.setOpenAtLogin != nil { preferences.isOpenAtLoginOn = SMAppService.mainApp.status == .enabled }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    // MARK: Menu actions

    @objc func showMainWindow(_ sender: Any?) {
        mainWindow?.show()
    }

    /// The settings belong to an unlocked account, as in the reference.
    @objc func openSettings(_ sender: Any?) {
        guard model.state.session.isUnlocked else { return }
        mainWindow?.show()
        if navigation.settingsTab == nil { navigation.settingsTab = .security }
    }

    @objc func lockVault(_ sender: Any?) {
        Task { await model.lock() }
    }

    /// The reference asks first: "log out", "are you sure you want to log out?".
    @objc func logOut(_ sender: Any?) {
        guard model.state.session.account != nil,
              confirm(title: BWText["logOut"], text: BWText["logOutConfirmation"], accept: BWText["logOut"], decline: BWText["cancel"])
        else { return }
        Task { await model.logOut() }
    }

    /// "Sync now": the toast says how it went, as in the reference.
    @objc func syncVault(_ sender: Any?) {
        Task {
            do {
                try await model.sync()
                navigation.toasts.show(.success, message: BWText["syncingComplete"])
            } catch {
                navigation.toasts.show(.error, message: BWText["syncingFailed"])
            }
        }
    }

    @objc func copyUsername(_ sender: Any?) {
        copyFromOpenItem(.username, labelKey: "username")
    }

    @objc func copyPassword(_ sender: Any?) {
        copyFromOpenItem(.password, labelKey: "password")
    }

    @objc func copyVerificationCode(_ sender: Any?) {
        copyFromOpenItem(.verificationCode, labelKey: "verificationCodeTotp")
    }

    /// `copyValue` of vault.component.ts: a field of the item whose panel is open. Nothing happens
    /// without an open item or without that field. The password and the verification code of an
    /// item that asks for the master password wait for it; the toast is of the kind "info".
    private func copyFromOpenItem(_ field: ItemField, labelKey: String) {
        guard let id = navigation.openItemID, let item = model.state.vault.items.first(where: { $0.id == id }),
              item.fields.contains(field) else { return }
        let copy = { @MainActor [model, navigation] in
            _ = Task {
                guard (try? await model.copy(field, of: id)) != nil else { return }
                navigation.toasts.show(.info, message: BWText["valueCopied", BWText[labelKey]])
                navigation.afterCopy?()
            }
        }
        if field == .username {
            copy()
        } else {
            navigation.perform(on: item, copy)
        }
    }

    @objc func newLogin(_ sender: Any?) { openNewItem(.login) }
    @objc func newCard(_ sender: Any?) { openNewItem(.card) }
    @objc func newIdentity(_ sender: Any?) { openNewItem(.identity) }
    @objc func newNote(_ sender: Any?) { openNewItem(.secureNote) }
    @objc func newSSHKey(_ sender: Any?) { openNewItem(.sshKey) }

    @objc func openGenerator(_ sender: Any?) {
        guard model.state.session.isUnlocked else { return }
        mainWindow?.show()
        navigation.generator = GeneratorSession(purpose: .standalone, options: model.state.settings.generator)
    }

    /// The empty form of a new item in the main window.
    private func openNewItem(_ type: ItemType) {
        guard model.state.session.isUnlocked else { return }
        mainWindow?.show()
        ItemActions(model: model, navigation: navigation).add(type)
    }

    @objc func openGeneratorHistory(_ sender: Any?) {
        guard model.state.session.isUnlocked else { return }
        mainWindow?.show()
        navigation.showsGeneratorHistory = true
    }

    @objc func newFolder(_ sender: Any?) {
        guard model.state.session.isUnlocked else { return }
        mainWindow?.show()
        navigation.folderDialog = .add
    }

    @objc func searchVault(_ sender: Any?) {
        mainWindow?.show()
        navigation.searchFocusRequest += 1
    }

    /// "Hide to menu bar": the window goes, the app and its engine stay.
    @objc func hideToMenuBar(_ sender: Any?) {
        mainWindow?.close()
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        preferences.isAlwaysOnTop.toggle()
        mainWindow?.window.level = preferences.isAlwaysOnTop ? .floating : .normal
    }

    /// The reference sends the user to the web app for both, after a question.
    @objc func changeMasterPassword(_ sender: Any?) {
        if confirm(title: BWText["continueToWebApp"], text: BWText["changeMasterPasswordOnWebConfirmation"],
                   accept: BWText["continue"], decline: BWText["cancel"]) {
            openWebVault(sender)
        }
    }

    /// "Import" and "export" of the file menu: their dialogs in the main window.
    @objc func importVault(_ sender: Any?) {
        mainWindow?.show()
        navigation.isImporting = true
    }

    @objc func exportVault(_ sender: Any?) {
        mainWindow?.show()
        navigation.isExporting = true
    }

    /// "Fingerprint phrase" of the account menu: the dialog with the five words.
    @objc func showFingerprintPhrase(_ sender: Any?) {
        Task {
            guard let words = try? await model.fingerprintPhrase() else { return }
            mainWindow?.show()
            navigation.fingerprintPhrase = words
        }
    }

    @objc func openTwoStepLogin(_ sender: Any?) {
        if confirm(title: BWText["twoStepLogin"], text: BWText["twoStepLoginConfirmation"],
                   accept: BWText["yes"], decline: BWText["no"]) {
            openWebVault(sender)
        }
    }

    /// The web vault of the account's server, or of the server chosen for the log-in.
    @objc func openWebVault(_ sender: Any?) {
        guard let url = webVaultURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var webVaultURL: URL? {
        guard let url = model.state.session.account?.serverURL ?? flow.serverURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func confirm(title: String, text: String, accept: String, decline: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: decline)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func checkForUpdates(_ sender: Any?) {
        appUpdater?.checkForUpdates()
    }

    private func showUpdateBlocked() {
        let alert = NSAlert()
        alert.messageText = BWText["checkForUpdates"]
        alert.informativeText = BWText["honkpassUpdateFinishWork"]
        alert.addButton(withTitle: BWText["ok"])
        alert.runModal()
    }

    /// An item is enabled by the state of the engine, as the reference enables it by "locked",
    /// "lockable" and "authenticated". An item without an action never gets here and stays disabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isUnlocked = model.state.session.isUnlocked
        switch menuItem.action {
        case #selector(checkForUpdates(_:)):
            return appUpdater?.canCheckForUpdates == true
        case #selector(openSettings(_:)), #selector(lockVault(_:)), #selector(syncVault(_:)), #selector(searchVault(_:)),
             #selector(copyUsername(_:)), #selector(copyPassword(_:)), #selector(copyVerificationCode(_:)),
             #selector(changeMasterPassword(_:)), #selector(openTwoStepLogin(_:)), #selector(showFingerprintPhrase(_:)),
             #selector(importVault(_:)), #selector(exportVault(_:)),
             #selector(newLogin(_:)), #selector(newCard(_:)), #selector(newIdentity(_:)), #selector(newNote(_:)),
             #selector(newFolder(_:)), #selector(newSSHKey(_:)), #selector(openGenerator(_:)),
             #selector(openGeneratorHistory(_:)):
            return isUnlocked
        case #selector(logOut(_:)):
            return model.state.session.account != nil
        case #selector(openWebVault(_:)):
            return webVaultURL != nil
        case #selector(hideToMenuBar(_:)):
            return mainWindow?.isVisible == true
        case #selector(toggleAlwaysOnTop(_:)):
            menuItem.state = preferences.isAlwaysOnTop ? .on : .off
            return true
        default:
            return true
        }
    }

    /// "Lock vault" and "log out" list the account by its email, as the reference lists every account.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == MainMenu.lockMenuIdentifier || menu.identifier == MainMenu.logOutMenuIdentifier else { return }
        menu.removeAllItems()
        guard let account = model.state.session.account else { return }
        let action = menu.identifier == MainMenu.lockMenuIdentifier ? #selector(lockVault(_:)) : #selector(logOut(_:))
        menu.addItem(NSMenuItem(title: account.email, action: action, keyEquivalent: ""))
    }

    // MARK: User activity

    /// Keyboard and mouse use inside PassVault restarts the inactivity timeout, at most once a second.
    private func installActivityMonitor() {
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastActivityNote) > 1 else { return }
                self.lastActivityNote = Date()
                Task { await self.model.noteUserActivity() }
            }
            return event
        }
    }
}
