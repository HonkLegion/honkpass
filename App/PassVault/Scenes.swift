#if DEBUG
import AppKit
import AutoFillBridge
import DesignKit
import Engine
import EngineFakes
import ProviderUI
import SwiftUI
import VaultModel

private struct UnavailableAutoFillPreview: AutoFillAsking {
    func ask(_ request: AutoFillRequest) async -> AutoFillResponse { .failure(.unavailable) }
}

/// A frozen clock keeps fake SSH preview requests visible until the user answers.
/// Normal starts and smoke tests retain the engine's continuous clock.
struct SSHApprovalPreviewClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let now = ContinuousClock.now
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        while deadline > now { try await Task.sleep(for: .seconds(86_400)) }
    }
}

/// A key of the keyboard that the scenes and the smoke test press in a window.
enum TestKey: Equatable {
    case down, up, left, right, `return`, escape, tab
    /// A key that types this text.
    case text(String)
    /// A letter with the Command key: a shortcut, which goes to the window as a key equivalent.
    case command(String)

    fileprivate var code: UInt16 {
        switch self {
        case .down: 125
        case .up: 126
        case .left: 123
        case .right: 124
        case .return: 36
        case .escape: 53
        case .tab: 48
        case .text, .command: 0
        }
    }

    fileprivate var characters: String {
        switch self {
        case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .return: "\r"
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .text(let text), .command(let text): text
        }
    }

    fileprivate var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .down, .up, .left, .right: [.numericPad, .function]
        case .command: .command
        default: []
        }
    }
}

extension NSWindow {
    /// Gives the window the events of one press of a key, as the keyboard does. Nothing leaves the
    /// process: the event goes to this window only.
    ///
    /// - Parameter givesContentTheKeyboard: false leaves the keyboard where it is, also when
    ///   it is in no view, as after a click beside a field.
    func press(_ key: TestKey, givesContentTheKeyboard: Bool = true) {
        // A window that is not the key window may have no first responder but itself; its
        // content, which knows where the keyboard is, would not hear of the key.
        if givesContentTheKeyboard, firstResponder === self, let contentView { makeFirstResponder(contentView) }
        if case .command = key {
            // NSApplication offers a shortcut to the key window before the application menu.
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) {
                _ = performKeyEquivalent(with: event)
            }
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { continue }
            sendEvent(event)
        }
    }
}

/// `--scene <name>` opens one screen in a known state and prints "SCENE READY".
/// scripts/compare-screen.fish uses it to take the picture that is compared with the reference.
/// The names are the names of the reference pictures in docs/reference.
@MainActor
struct SceneDriver {
    let model: AppModel
    let flow: LogInFlow
    let navigation: VaultNavigation
    let mainWindow: MainWindowController
    let quickAccess: QuickAccessPanelController
    /// The engine as the AutoFill extension asks it, for the pictures of its windows.
    let autoFill: any AutoFillAsking
    /// The SSH agent without a socket: a scene asks through it what an SSH client would ask.
    var fakeSSHAgent: FakeSSHAgent?
    /// The preferences of the app, for the scenes of a setting.
    var preferences: AppPreferences?
    /// The Keychain behind Touch ID that is none: a scene gives the Mac a sensor through it.
    var fakeBiometrics: FakeBiometricKeys?
    /// The server of the fake backend, which holds an upload half way for its picture.
    var fakeServer: FakeServer?
    var fakeActiveField: FakeActiveField?
    var sshApprovalWindow: SSHApprovalWindowController?
    /// The window that stands for the one the system gives the extension.
    private static var providerWindow: NSWindow?

    /// The scenes that are another scene after some keys were pressed in it: the mark of the
    /// keyboard in an open menu and in the open list of a select.
    /// No reference pictures yet (docs/reference/README.md, "Still to take").
    private static let keyboardScenes: [String: (scene: String, keys: [TestKey])] = [
        "menu-new-keyboard": ("menu-new", [.down, .down]),
        "settings-timeout-list-keyboard": ("settings-timeout-list", [.up]),
        "settings-timeout-list-search": ("settings-timeout-list", [.text("ho")]),
    ]

    func open(_ name: String) {
        let (scene, keys) = Self.keyboardScenes[name] ?? (name, [])
        Task {
            for _ in 0..<100 where model.state.activity != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let fake = model.prefill.map { (server: $0.server, email: $0.email, masterPassword: $0.masterPassword) }
            guard let account = fake ?? LaunchOptions.testCredentials else {
                finish("SCENE FAILED: no test account (--fake-backend or the PASSVAULT_SMOKE_ variables)")
                return
            }
            flow.serverURL = account.server
            var showsQuickAccess = false
            var pictured: NSWindow?
            var nativeMenu: NSMenu?

            switch scene {
            case "vault-performance":
                guard fakeServer != nil else { finish("SCENE FAILED: performance probe requires fakes"); return }
                await VaultPerformanceProbe.run(model: model, quickAccess: quickAccess,
                                                 navigation: navigation, autoFill: autoFill)
                NSApp.terminate(nil)
                return
            case "auth-feedback":
                await fakeBiometrics?.setSensorAvailable(true)
                guard await logIn(account) else { return }
                await model.refreshBiometrics()
                navigation.settingsTab = .security
            case "login-loading":
                guard let fakeServer else {
                    finish("SCENE FAILED: login-loading needs --fake-backend")
                    return
                }
                flow.email = account.email
                flow.step = .masterPassword
                await fakeServer.holdNextSync()
                Task { try? await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword) }
                await fakeServer.syncIsHeld()
            case "account-avatar":
                // System artwork is synthetic preview data, never a personal Gravatar request.
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
                panel.title = "HonkPass"
                panel.contentView = NSHostingView(rootView: VStack(spacing: Metric.space(3)) {
                    NavAccountButton(name: "Demo User", email: "demo@vault.example", id: "demo",
                                     image: NSImage(named: NSImage.userAccountsName)) {}
                    NavAccountButton(name: "demo@vault.example", email: "demo@vault.example", id: "demo") {}
                }
                .padding(Metric.space(4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.theme(.navBgPrimary)))
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                Self.providerWindow = panel
                pictured = panel
            case "native-menu-app", "native-menu-file", "native-menu-edit", "native-menu-view",
                 "native-menu-account", "native-menu-window", "native-menu-help", "native-menu-new",
                 "native-menu-lock", "native-menu-logout":
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let index: Int = switch scene {
                case "native-menu-file", "native-menu-new": 1
                case "native-menu-edit": 2
                case "native-menu-view": 3
                case "native-menu-account": 4
                case "native-menu-window": 5
                case "native-menu-help": 6
                default: 0
                }
                nativeMenu = NSApp.mainMenu?.items[index].submenu
                if scene == "native-menu-new" { nativeMenu = nativeMenu?.items.first { $0.submenu != nil }?.submenu }
                if scene == "native-menu-lock" {
                    nativeMenu = nativeMenu?.items.first { $0.submenu?.identifier == MainMenu.lockMenuIdentifier }?.submenu
                }
                if scene == "native-menu-logout" {
                    nativeMenu = nativeMenu?.items.first { $0.submenu?.identifier == MainMenu.logOutMenuIdentifier }?.submenu
                }
                guard nativeMenu != nil else { finish("SCENE FAILED: native menu unavailable"); return }
                if let nativeMenu {
                    nativeMenu.delegate?.menuNeedsUpdate?(nativeMenu)
                    nativeMenu.update()
                }
            case "menus":
                // Prints the application menu as it is while the vault is unlocked: one line for each
                // item with its shortcut, and "(off)" for a disabled one.
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let menu = NSApp.mainMenu { print(Self.describe(menu, depth: 0), terminator: "") }
            case "about":
                NSApp.activate(ignoringOtherApps: true)
                LegalInformation.shared.showAbout(nil)
                for _ in 0..<40 {
                    pictured = NSApp.windows.first {
                        $0.isVisible && $0.frame.width > 200 && $0.frame.height > 100
                            && $0 !== mainWindow.window && $0 !== quickAccess.window
                    }
                    if pictured != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard pictured != nil else { finish("SCENE FAILED: About panel did not open"); return }
            case "notices":
                // The composition root gave the engine three notices; the window shows them as toasts.
                flow.email = ""
            case "log-in-email":
                flow.email = ""
            case "log-in-server":
                flow.email = ""
                flow.isServerDialogOpen = true
            case "log-in-password":
                // The reference picture is of a device the server knows: one log-in before
                // makes this run such a device.
                guard await logIn(account) else { return }
                for _ in 0..<100 where !flow.twoStepEndedByUser {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard flow.twoStepEndedByUser else { finish("SCENE FAILED: login screen did not reset"); return }
                do { try await model.logOut() } catch { finish("SCENE FAILED: synthetic logout failed"); return }
                flow.email = account.email
                flow.step = .masterPassword
            case "log-in-hint":
                // No reference picture yet.
                flow.email = account.email
                flow.step = .hint
            case "lock":
                guard await logIn(account) else { return }
                await model.lock()
            case "two-step-authenticator", "two-step-email", "two-step-methods":
                // No reference pictures yet (docs/reference/README.md, "Still to take").
                // Needs an account with two-step login: --fake-backend --two-step.
                flow.email = account.email
                try? await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
                guard await waitForTwoStep() else {
                    finish("SCENE FAILED: the account has no two-step login (--fake-backend --two-step)")
                    return
                }
                if scene == "two-step-email" { flow.twoStepMethod = .email }
                if scene == "two-step-methods" { flow.isTwoStepMethodDialogOpen = true }
            case "lock-pin":
                // No reference pictures yet (docs/reference/README.md, "Still to take").
                guard await logIn(account) else { return }
                try? await model.setPin("4812", asksForMasterPasswordAfterRestart: false)
                for _ in 0..<100 where !model.state.pin.canUnlock {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await model.lock()
            case "lock-touch-id", "lock-touch-id-pin", "settings-security-touch-id":
                // Touch ID: the lock screen that starts with it, the form of the PIN with its
                // button, and the rows of the settings. The Mac of the reference pictures had
                // no sensor in reach, so there are none of them. The sensor and the Keychain
                // of a picture run are none: no finger is asked for.
                guard let fakeBiometrics else {
                    finish("SCENE FAILED: the scenes of Touch ID need a test or picture run")
                    return
                }
                await fakeBiometrics.setSensorAvailable(true)
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await model.refreshBiometrics()
                try? await model.setBiometricUnlock(true)
                if scene == "settings-security-touch-id" {
                    navigation.sideNavigationWidth = 361
                    navigation.settingsTab = .security
                } else {
                    if scene == "lock-touch-id-pin" {
                        try? await model.setPin("4812", asksForMasterPasswordAfterRestart: false)
                        for _ in 0..<100 where !model.state.pin.canUnlock {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                    await model.lock()
                }
            case "settings-set-pin":
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.settingsStartWithPinDialog = true
                navigation.settingsTab = .security
            case "settings-timeout-custom":
                // No reference picture yet (docs/reference/README.md, "Still to take").
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                var settings = model.state.settings
                settings.lockPolicy.timeout = .afterInactivity(minutes: 90)
                try? await model.setSettings(settings)
                for _ in 0..<100 where model.state.settings != settings {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.settingsTab = .security
            case "vault-folders-tree":
                // No reference picture: the test account has no nested folders, and the scene must
                // not add any to it. So it needs the fake backend.
                guard model.prefill != nil else {
                    finish("SCENE FAILED: vault-folders-tree needs --fake-backend")
                    return
                }
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                for name in ["Shopping/Receipts", "Shopping/Receipts/2026", "Shopping/Wishes", "Travel/Trains"] {
                    _ = try? await model.saveFolder(id: nil, name: name)
                }
                for _ in 0..<100 where model.state.vault.folders.count < 5 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.isFolderListOpen = true
                navigation.openFolderIDs = Set(model.state.vault.folders.filter { ["Shopping", "Shopping/Receipts"].contains($0.name) }.map(\.id))
                navigation.filter = .folder(model.state.vault.folders.first { $0.name == "Shopping/Receipts" }?.id)
            case "generator-history":
                // No reference picture yet: three values of the generator, then its history.
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                _ = try? await model.generate(.password(PasswordOptions()))
                _ = try? await model.generate(.passphrase(PassphraseOptions()))
                _ = try? await model.generate(.username(UsernameOptions()))
                navigation.showsGeneratorHistory = true
            case let name where Self.formScenes[name] != nil:
                guard await logIn(account), let form = Self.formScenes[name] else { return }
                if name == "form-edit-login-no-website" { await prepareLoginWithoutPassword() }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                navigation.itemPanelStartsAtEnd = form.startsAtEnd
                if let name = form.item, let id = model.state.vault.items.first(where: { $0.name == name })?.id,
                   let draft = try? await model.draft(of: id) {
                    navigation.openItemID = id
                    navigation.itemForm = ItemForm(mode: .edit, draft: draft)
                } else if let type = form.new {
                    var draft = ItemDraft(new: type)
                    if type == .sshKey {
                        guard let key = try? await model.newSSHKey() else {
                            finish("SCENE FAILED: synthetic SSH key generation failed")
                            return
                        }
                        draft.content = .sshKey(key)
                    }
                    navigation.itemForm = ItemForm(mode: .new, draft: draft)
                } else {
                    finish("SCENE FAILED: the form of \(scene) did not open")
                    return
                }
                if form.showsFieldDialog { navigation.itemForm?.showsAddField = true }
                if form.showsHelp { navigation.itemForm?.showsVerificationKeyHelp = true }
                for app in form.apps.compactMap(AppAddress.init) { navigation.itemForm?.addApp(app) }
                if form.showsAddMenu { navigation.itemForm?.isAddWebsiteMenuOpen = true }
                if form.showsAppPicker { navigation.itemForm?.isAppPickerOpen = true }
            case "item-login-no-password":
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await prepareLoginWithoutPassword()
                navigation.openItemID = model.state.vault.items.first { $0.name == "Example Login Without Password" }?.id
            case "vault-archive-populated", "item-archive":
                guard model.prefill != nil else { finish("SCENE FAILED: archive preview requires fakes"); return }
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let item = model.state.vault.items.first(where: { !$0.isInTrash && $0.type == .login }) {
                    try? await model.change(.archive, of: item.id)
                    for _ in 0..<100 where model.state.vault.items.first(where: { $0.id == item.id })?.isArchived != true {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    navigation.filter = .archive
                    if scene == "item-archive" { navigation.openItemID = item.id }
                }
            case "quick-access", "quick-access-compact", "quick-access-single-vault", "quick-access-search", "quick-access-keyboard", "quick-access-locked", "quick-access-logged-out",
                 "quick-access-touch-id", "quick-access-copy-menu", "quick-access-more-menu", "quick-access-copied", "quick-access-reprompt",
                 "quick-access-fill-menu", "quick-access-fill-confirm", "quick-access-app-confirm", "quick-access-suggestions":
                // The quick access window, which the browser extension has as its popup and the
                // desktop app lacks: no reference pictures. Its window number is printed for a picture.
                showsQuickAccess = true
                if scene != "quick-access-logged-out" {
                    guard await logIn(account) else { return }
                    for _ in 0..<100 where !model.state.session.isUnlocked {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                if scene == "quick-access-touch-id" {
                    // The sensor of a picture run is none: no finger is asked for.
                    guard await turnTouchIDOn() else { return }
                }
                if scene == "quick-access-locked" || scene == "quick-access-touch-id" { await model.lock() }
            case "provider-list", "provider-search", "provider-keyboard", "provider-pin", "provider-locked",
                 "provider-touch-id", "provider-touch-id-pin",
                 "provider-logged-out", "provider-unavailable", "provider-setup", "provider-passkeys", "provider-passkey-save",
                 "provider-passkey-overwrite", "provider-passkey-exists", "provider-no-passkeys",
                 "provider-passkey-single", "provider-passkey-new":
                // The windows of the AutoFill extension, which the system shows over a form. Here
                // the app draws them over its own engine, in a window of the size the extension
                // asks for. No reference pictures: the reference draws its windows in the desktop app.
                if scene != "provider-logged-out" {
                    guard await logIn(account) else { return }
                    for _ in 0..<100 where !model.state.session.isUnlocked {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                if scene == "provider-touch-id" || scene == "provider-touch-id-pin" {
                    guard await turnTouchIDOn() else { return }
                }
                if scene == "provider-pin" || scene == "provider-touch-id-pin" {
                    try? await model.setPin("4812", asksForMasterPasswordAfterRestart: false)
                    for _ in 0..<100 where !model.state.pin.canUnlock {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                let website = model.state.vault.items.first { $0.type == .login && !$0.isInTrash && !$0.websites.isEmpty }?
                    .websites.first?.address
                if ["provider-pin", "provider-locked", "provider-touch-id", "provider-touch-id-pin"].contains(scene) {
                    await model.lock()
                }
                var request = ProviderModel.Request.chooseLogin(services: website.map { [$0] } ?? [])
                if scene.contains("passkey") {
                    // A passkey is made here as the extension has one made. Only the fake backend
                    // takes it: the account of the local server stays as it was seeded.
                    guard model.prefill != nil else {
                        finish("SCENE FAILED: the scenes of passkeys need --fake-backend")
                        return
                    }
                    let hash = Data("fake-client-data-hash".utf8)
                    let host = website.flatMap { URL(string: $0)?.host() } ?? "example.com"
                    func passkey(_ rpID: String, user: String, into itemID: String? = nil, excluded: [Data] = []) -> PasskeyRegistrationRequest {
                        PasskeyRegistrationRequest(rpID: rpID, userName: user, userHandle: Data(user.utf8), clientDataHash: hash,
                                                   algorithms: [-7], excludedCredentialIDs: excluded, userVerification: .preferred,
                                                   isUserVerified: true, itemID: itemID)
                    }
                    func made(_ request: PasskeyRegistrationRequest) async -> Data {
                        guard case .passkeyRegistration(let registration) = await autoFill.ask(.registerPasskey(request)) else { return Data() }
                        return registration.credentialID
                    }
                    switch scene {
                    case "provider-passkeys":
                        _ = await made(passkey("example.com", user: "first@example.com"))
                        _ = await made(passkey("example.com", user: "second@example.com"))
                        request = .choosePasskey(.init(rpID: "example.com", clientDataHash: hash, userVerification: .preferred))
                    case "provider-passkey-single":
                        _ = await made(passkey("example.com", user: "first@example.com"))
                        request = .choosePasskey(.init(rpID: "example.com", clientDataHash: hash, userVerification: .preferred))
                    case "provider-passkey-new":
                        request = .newPasskey(passkey("new-passkey.example", user: "demo@example.com"))
                    case "provider-passkey-save":
                        request = .newPasskey(passkey(host, user: "user@example.com"))
                    case "provider-passkey-overwrite":
                        let login = model.state.vault.items.first { $0.websites.first?.address == website }
                        _ = await made(passkey(host, user: "user@example.com", into: login?.id))
                        request = .newPasskey(passkey(host, user: "user@example.com"))
                    case "provider-passkey-exists":
                        let existing = await made(passkey("example.com", user: "first@example.com"))
                        request = .newPasskey(passkey("example.com", user: "second@example.com", excluded: [existing]))
                    default:
                        request = .choosePasskey(.init(rpID: "nothing.example", clientDataHash: hash, userVerification: .preferred))
                    }
                }
                let asking: any AutoFillAsking = scene == "provider-unavailable" ? UnavailableAutoFillPreview() : autoFill
                let provider = ProviderModel(request: request, asking: asking,
                                             pause: scene == "provider-unavailable" ? .milliseconds(50) : .seconds(1),
                                             actions: ProviderModel.Actions(
                    openApp: { _ in }, finish: { _ in }, verifyUser: { _ in true }))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                // As in the extension, the window has its size and the content fills it.
                let host = NSHostingController(rootView: AnyView((scene == "provider-setup" ? AnyView(ProviderConfigurationView())
                    : AnyView(ProviderView(model: provider))).ignoresSafeArea(.container, edges: .top)))
                host.sizingOptions = []
                window.contentViewController = host
                window.setContentSize(NSSize(width: 480, height: 400))
                window.center()
                window.makeKeyAndOrderFront(nil)
                Self.providerWindow = window
                pictured = window
                if scene == "provider-search" {
                    try? await Task.sleep(for: .milliseconds(600))
                    provider.search = "example"
                }
                if scene == "provider-passkey-overwrite" {
                    // The question before a passkey is replaced.
                    try? await Task.sleep(for: .milliseconds(600))
                    if let login = provider.targets.first(where: \.hasPasskey) { provider.save(into: login) }
                }
                if scene == "provider-passkey-exists" {
                    for _ in 0..<100 where provider.screen != .passkeyTargets || provider.isBusy {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    provider.chooseSelected()
                }
            case "dialog-ssh-approval", "dialog-ssh-approval-forwarded", "ssh-approval", "ssh-approval-locked", "ssh-approval-queue":
                // An SSH client asks for the key of the vault. No reference picture yet.
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                var settings = model.state.settings
                settings.sshAgent = SSHAgentSettings(isEnabled: true, prompt: .always)
                try? await model.setSettings(settings)
                var keys: [SSHAgentIdentity] = []
                for _ in 0..<100 where keys.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    keys = await fakeSSHAgent?.requests?.sshIdentities() ?? []
                }
                if let key = keys.first, let client = await fakeSSHAgent?.requests {
                    let isForwarded = scene == "dialog-ssh-approval-forwarded"
                    if scene == "ssh-approval-locked" { await model.lock() }
                    if scene.hasPrefix("ssh-approval") { mainWindow.close() }
                    let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                    Task {
                        _ = await client.sshSignature(for: SSHSignRequest(publicKeyBlob: key.publicKeyBlob, data: Data("synthetic".utf8),
                                                                          processName: applicationURL == nil ? "ssh" : "Terminal",
                                                                          isForwarding: isForwarded, namespace: isForwarded ? nil : "git",
                                                                          requesterApplicationURL: applicationURL))
                    }
                    if scene == "ssh-approval-queue" {
                        Task {
                            _ = await client.sshSignature(for: SSHSignRequest(publicKeyBlob: key.publicKeyBlob,
                                data: Data("synthetic second request".utf8), processName: "ssh-keygen", namespace: "git"))
                        }
                    }
                    for _ in 0..<100 where sshApprovalWindow?.window?.isVisible != true {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    pictured = sshApprovalWindow?.window
                }
            case "dialog-attachments-uploading":
                // The attachments dialog while a file goes: the fake server holds the upload half
                // way. On the fake backend only: a scene writes nothing to a server. No reference picture.
                guard let fakeServer else {
                    finish("SCENE FAILED: the scene of an upload needs --fake-backend")
                    return
                }
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                guard let id = model.state.vault.items.first(where: { $0.name == "Example Mail" })?.id else {
                    finish("SCENE FAILED: the fake account has no item \"Example Mail\"")
                    return
                }
                let file = FileManager.default.temporaryDirectory.appending(path: "synthetic-report.pdf")
                try? Data("A synthetic file of a picture.".utf8).write(to: file)
                navigation.attachmentsItemID = id
                navigation.attachmentFile = file
                await fakeServer.holdNextUpload()
                let actions = ItemActions(model: model, navigation: navigation, isPanel: true)
                Task { _ = await actions.upload(file, toItem: id) }
                await fakeServer.uploadIsHeld()
                // The file was read before it went.
                try? FileManager.default.removeItem(at: file)
                for _ in 0..<100 where model.state.upload?.percent != 50 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            case "item-login-apps":
                // The view of a login with apps. The apps are saved to the login here, on the
                // fake backend only: a scene writes nothing to a server. No reference picture.
                guard model.prefill != nil else {
                    finish("SCENE FAILED: the scene of the apps of a login needs --fake-backend")
                    return
                }
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                navigation.itemPanelStartsAtEnd = true
                if let id = model.state.vault.items.first(where: { $0.name == "Example Shop" })?.id {
                    for app in Self.sceneApps { try? await model.addWebsite(app, toLogin: id) }
                    navigation.openItemID = id
                }
            case "send-list", "send-empty", "send-search-empty", "send-menu", "send-menu-new", "send-view", "send-view-file",
                 "send-edit", "send-new-text", "send-new-file":
                // The Sends. They are made here, on the fake backend only: a scene writes nothing
                // to a server. No reference pictures yet.
                guard model.prefill != nil else {
                    finish("SCENE FAILED: the scenes of the Sends need --fake-backend")
                    return
                }
                guard await logIn(account) else { return }
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                navigation.sideNavigationWidth = 361
                navigation.page = .sends
                if scene != "send-empty" {
                    let day = Date().addingTimeInterval(7 * 86_400)
                    _ = try? await model.saveSend(SendDraft(type: .text, name: "Example Wi-Fi Password", notes: "For the guests",
                                                           text: "synthetic-guest-password", hidesText: true, deletionDate: day,
                                                           maxAccessCount: 5, newPassword: "synthetic"))
                    _ = try? await model.saveSend(SendDraft(type: .file, name: "Example Report",
                                                           file: .init(name: "report.pdf", data: Data(count: 2_048)),
                                                           deletionDate: day.addingTimeInterval(86_400)))
                    _ = try? await model.saveSend(SendDraft(type: .text, name: "Example Old Note", text: "synthetic",
                                                           deletionDate: Date().addingTimeInterval(-60)))
                }
                let sends = model.state.vault.sends
                @MainActor func show(_ name: String, editing: Bool = false) async {
                    guard let id = sends.first(where: { $0.name == name })?.id, let send = try? await model.send(id: id) else { return }
                    let form = SendForm(send)
                    if editing { form.edit() }
                    navigation.sendForm = form
                }
                switch scene {
                case "send-search-empty": navigation.sendSearch = "zzzz-no-results"
                case "send-menu": navigation.openSendMenuID = sends.first { $0.name == "Example Wi-Fi Password" }?.id
                case "send-menu-new": navigation.isNewSendMenuOpen = true
                case "send-view": await show("Example Wi-Fi Password")
                case "send-view-file": await show("Example Report")
                case "send-edit": await show("Example Wi-Fi Password", editing: true)
                case "send-new-text": navigation.sendForm = SendForm(new: .text)
                case "send-new-file": navigation.sendForm = SendForm(new: .file)
                default: break
                }
            default:
                guard let filter = Self.vaultScenes[scene] else {
                    finish("SCENE FAILED: unknown scene \(scene)")
                    return
                }
                guard await logIn(account) else { return }
                // The window model follows the engine a moment later.
                for _ in 0..<100 where !model.state.session.isUnlocked {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // The side navigation of the reference pictures was made wider by hand.
                navigation.sideNavigationWidth = 361
                // The list without "show quick copy actions": one copy button in a row.
                if scene == "vault-combined-copy" { preferences?.showsQuickCopyActions = false }
                filter(navigation, model.state.vault)
            }

            NSApp.activate(ignoringOtherApps: true)
            if !scene.hasPrefix("ssh-approval") { mainWindow.window.makeKeyAndOrderFront(nil) }
            if showsQuickAccess {
                // Preparing the scene can briefly move focus as the Dock policy changes.
                // Restore normal dismissal once the synthetic panel owns the keyboard.
                quickAccess.closesWithoutKeyboard = false
                if scene == "quick-access-compact" || scene == "quick-access-single-vault" {
                    mainWindow.close()
                    await fakeActiveField?.setField(FillTarget(appName: "Safari", website: "https://shop.example.test", takesLogin: true))
                }
                quickAccess.show()
                // The panel looks at the app in front before it shows.
                for _ in 0..<40 where !quickAccess.window.isVisible {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if scene == "quick-access-search" { quickAccess.state.search = "example m" }
                // The row of "Example Mail" in the list of all items.
                let row = model.state.vault.quickAccessRows(search: quickAccess.state.search)
                    .first { $0.item.name == "Example Mail" }?.id
                switch scene {
                case "quick-access-compact", "quick-access-single-vault":
                    if quickAccess.state.target == nil {
                        quickAccess.state.target = FillTarget(appName: "Safari", website: "https://shop.example.test", takesLogin: true)
                    }
                case "quick-access-copy-menu", "quick-access-more-menu":
                    if let detail = model.state.vault.quickAccessRows(search: quickAccess.state.search).first(where: { $0.id == row }) {
                        quickAccess.state.showActions(for: detail)
                        if scene == "quick-access-more-menu" { quickAccess.navigation.openMenuItemID = detail.id }
                    }
                // The toast alone: a picture run puts nothing on the clipboard of the Mac.
                case "quick-access-copied":
                    quickAccess.navigation.toasts.show(.success, message: BWText["valueCopied", BWText["password"]])
                case "quick-access-reprompt": quickAccess.navigation.protectedAction = VaultNavigation.ProtectedAction(run: {})
                // A picture run looks at no field of another app: a field of a browser is made up.
                case "quick-access-fill-menu", "quick-access-fill-confirm", "quick-access-app-confirm", "quick-access-suggestions":
                    // The question is for a page that is none of the login's.
                    let matchingWebsite = model.state.vault.items.first { $0.name == "Example Mail" }?
                        .websites.first?.address ?? "https://shop.example.com/login"
                    quickAccess.state.target = FillTarget(
                        appName: "Safari",
                        website: scene == "quick-access-fill-confirm" ? "https://login.example.org/" : matchingWebsite)
                    if scene == "quick-access-app-confirm" {
                        let target = FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor",
                                                app: FakeAppSignatures.editorAddress, takesLogin: true)
                        await fakeActiveField?.setField(target)
                        quickAccess.state.target = await model.fillTarget()
                        if let item = model.state.vault.items.first(where: { $0.name == "Example Shop" }) {
                            quickAccess.state.selectedRowID = item.id
                            quickAccess.state.pendingFill = .init(item: item, field: nil)
                        }
                    }
                    if scene == "quick-access-fill-menu" {
                        quickAccess.state.fillMenuRowID = row
                    } else if scene == "quick-access-fill-confirm", let item = model.state.vault.items.first(where: { $0.name == "Example Mail" }) {
                        quickAccess.state.pendingFill = .init(item: item, field: .password)
                    }
                default: break
                }
            }
            // Give SwiftUI time to draw the state.
            try? await Task.sleep(for: .milliseconds(900))
            let window = pictured ?? (showsQuickAccess ? quickAccess.window : mainWindow.window)
            // Captures must show the active window, including when scenes run back to back.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))
            for key in scene == "quick-access-keyboard" || scene == "provider-keyboard" ? [TestKey.down, .down] : keys {
                window.press(key)
                try? await Task.sleep(for: .milliseconds(200))
            }
            if showsQuickAccess { print("SCENE WINDOW \(quickAccess.window.windowNumber)") }
            if showsQuickAccess, let glass = quickAccess.window.contentView as? NSGlassEffectView {
                quickAccess.closesWithoutKeyboard = true
                print("SCENE LAYOUT window=\(quickAccess.window.frame) glass=\(glass.frame) content=\(glass.contentView?.frame ?? .zero) hosted=\(glass.contentView?.subviews.first?.frame ?? .zero)")
            }
            if let pictured { print("SCENE WINDOW \(pictured.windowNumber)") }
            finish("SCENE READY")
            if let nativeMenu, let view = mainWindow.window.contentView {
                let top = view.isFlipped ? 100.0 : view.bounds.height - 100
                nativeMenu.popUp(positioning: nil, at: NSPoint(x: 100, y: top), in: view)
            }
        }
    }

    /// The scenes of the item form: the item whose form opens, or the type of a new item.
    /// No reference pictures yet (docs/reference/README.md, "Still to take").
    private struct FormScene {
        var item: String?
        var new: ItemType?
        var startsAtEnd = false
        var showsFieldDialog = false
        var showsHelp = false
        /// Apps the form gets as "add website or app" adds them: nothing is saved.
        var apps: [String] = []
        /// The menu of "add website or app" is open.
        var showsAddMenu = false
        var showsAppPicker = false
    }

    /// The apps of the scenes: one that every Mac has, which is shown by its name and its
    /// picture, and one that is installed nowhere, which is shown by its identifier.
    private static let sceneApps = ["osxapp://com.apple.TextEdit:apple", "osxapp://com.example.Mail:ABCDE12345"]

    private static let formScenes: [String: FormScene] = [
        "form-edit-login": FormScene(item: "Example Shop"),
        "form-edit-login-no-website": FormScene(item: "Example Login Without Password", startsAtEnd: true),
        "form-edit-login-2": FormScene(item: "Example Shop", startsAtEnd: true),
        "form-edit-card": FormScene(item: "Example Card"),
        "form-edit-identity": FormScene(item: "Example Identity"),
        "form-edit-identity-2": FormScene(item: "Example Identity", startsAtEnd: true),
        "form-edit-note": FormScene(item: "Example Note"),
        "form-edit-ssh-key": FormScene(item: "Example SSH Key"),
        "form-new-login": FormScene(new: .login),
        "form-new-card": FormScene(new: .card),
        "form-new-identity": FormScene(new: .identity),
        "form-new-identity-2": FormScene(new: .identity, startsAtEnd: true),
        "form-new-note": FormScene(new: .secureNote),
        "form-new-ssh-key": FormScene(new: .sshKey),
        "form-edit-ssh-key-2": FormScene(item: "Example SSH Key", startsAtEnd: true),
        "form-add-field": FormScene(item: "Example Shop", showsFieldDialog: true),
        "form-authenticator-help": FormScene(item: "Example Shop", showsHelp: true),
        // The apps of a login: PassVault's own, no reference pictures.
        "form-edit-login-apps": FormScene(item: "Example Shop", startsAtEnd: true, apps: sceneApps),
        "form-add-website-menu": FormScene(item: "Example Shop", startsAtEnd: true, showsAddMenu: true),
        "form-running-apps": FormScene(item: "Example Shop", startsAtEnd: true, showsAppPicker: true),
    ]

    /// The scenes of the open vault: what each one sets in the navigation.
    private static let vaultScenes: [String: @MainActor (VaultNavigation, VaultContents) -> Void] = [
        "vault-all-items": { navigation, _ in navigation.filter = .allItems },
        "vault-empty": { navigation, _ in navigation.filter = .allItems },
        // No reference picture yet: the pictures were taken with the quick copy buttons on.
        "vault-combined-copy": { navigation, _ in navigation.filter = .allItems },
        "vault-my-vault": { navigation, _ in navigation.isMyVaultSelected = true },
        "vault-favourites": { navigation, _ in navigation.filter = .favorites },
        "vault-type-login": { navigation, _ in navigation.filter = .type(.login) },
        "vault-type-card": { navigation, _ in navigation.filter = .type(.card) },
        "vault-type-identity": { navigation, _ in navigation.filter = .type(.identity) },
        "vault-type-note": { navigation, _ in navigation.filter = .type(.secureNote) },
        "vault-type-ssh-key": { navigation, _ in navigation.filter = .type(.sshKey) },
        "vault-archive": { navigation, _ in navigation.filter = .archive },
        "vault-trash": { navigation, _ in navigation.filter = .trash },
        "vault-folders": { navigation, _ in navigation.isFolderListOpen = true },
        "vault-folder": { navigation, vault in
            navigation.isFolderListOpen = true
            navigation.filter = .folder((vault.folders.first { $0.name == "Work" } ?? vault.folders.first)?.id)
        },
        "vault-search": { navigation, _ in navigation.search = "Mail" },
        "vault-search-empty": { navigation, _ in navigation.search = "zzzz-no-results" },
        "sidebar-collapsed": { navigation, _ in navigation.isSideNavigationCollapsed = true },
        "item-reprompt": { navigation, _ in navigation.protectedAction = VaultNavigation.ProtectedAction(run: {}) },
        "item-login": { navigation, vault in
            navigation.filter = .type(.login)
            open("Example Mail", navigation, vault)
        },
        "item-login-revealed": { navigation, vault in
            navigation.isFolderListOpen = true
            open("Example Mail", navigation, vault)
            navigation.revealedFields = ["password"]
        },
        "item-login-fields": { navigation, vault in
            navigation.isFolderListOpen = true
            open("Example Shop", navigation, vault)
        },
        "item-login-fields-2": { navigation, vault in
            navigation.itemPanelStartsAtEnd = true
            open("Example Shop", navigation, vault)
        },
        "item-login-no-password": { navigation, vault in
            navigation.isFolderListOpen = true
            open("Example Login Without Password", navigation, vault)
        },
        "item-card": { navigation, vault in open("Example Card", navigation, vault) },
        "item-identity": { navigation, vault in open("Example Identity", navigation, vault) },
        "item-note": { navigation, vault in open("Example Note", navigation, vault) },
        "item-ssh-key": { navigation, vault in open("Example SSH Key", navigation, vault) },
        "settings-security": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.settingsTab = .security
        },
        "settings-options": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.settingsTab = .options
        },
        "settings-app": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.settingsTab = .app
        },
        // No reference pictures yet (docs/reference/README.md, "Still to take").
        "dialog-shortcut": { navigation, _ in navigation.isEditingShortcut = true },
        // Organizations, on the fake backend, whose account has one. No reference pictures yet.
        "dialog-assign-collections": { navigation, vault in
            navigation.assignItemID = vault.items.first { $0.name == "Example Mail" }?.id
        },
        "vault-collections": { navigation, vault in
            navigation.isCollectionListOpen = true
            navigation.owner = vault.organizations.first.map { .organization($0.id) } ?? .all
        },
        // The dialogs of M6, over the vault.
        "dialog-export": { navigation, _ in navigation.isExporting = true },
        "dialog-import": { navigation, _ in navigation.isImporting = true },
        // The same, as in their reference pictures: over the Sends of an account that has none,
        // with the folders open.
        "send": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.showSends(nil)
        },
        "export": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.showSends(nil)
            navigation.isExporting = true
        },
        "import": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.showSends(nil)
            navigation.isImporting = true
        },
        "menu-account": { navigation, _ in navigation.accountMenuStartsOpen = true },
        "dialog-import-success": { navigation, _ in
            navigation.importResult = VaultImport(folders: [.init(name: "Imported")], items: [
                .init(draft: ItemDraft(new: .login)), .init(draft: ItemDraft(new: .login)), .init(draft: ItemDraft(new: .card)),
                .init(draft: ItemDraft(new: .secureNote)),
            ]).summary
        },
        "dialog-fingerprint": { navigation, _ in navigation.fingerprintPhrase = ["fake", "phrase", "of", "five", "words"] },
        "settings-help": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.settingsStartWithHelp = true
            navigation.settingsTab = .options
        },
        "settings-timeout-list": { navigation, _ in
            navigation.settingsStartWithOpenList = true
            navigation.settingsTab = .security
        },
        "item-password-count": { navigation, vault in
            open("Example Mail", navigation, vault)
            navigation.revealedFields = ["password"]
            navigation.showsPasswordCount = true
        },
        "toast-copied": { navigation, vault in
            open("Example Mail", navigation, vault)
            navigation.toasts.show(.success, message: BWText["valueCopied", BWText["username"]])
            navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidMasterPassword"])
        },
        "item-trash": { navigation, vault in
            navigation.filter = .trash
            navigation.openItemID = vault.items.first { $0.isInTrash }?.id
        },
        "vault-row-checked": { navigation, vault in
            navigation.isFolderListOpen = true
            navigation.sort = VaultSort(column: .name, isAscending: true)
            navigation.checkedItemIDs = Set(vault.items.filter { $0.name == "Example Mail" }.map(\.id))
            // The reference picture was taken with the pointer still on the checkbox it had
            // ticked: the row has the ground of a row under the pointer, not of a ticked one.
            navigation.pointerOnCheckboxItemID = navigation.checkedItemIDs.first
        },
        "menu-new": { navigation, _ in navigation.isNewMenuOpen = true },
        "generator-password": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.generator = GeneratorSession(purpose: .standalone, options: GeneratorOptions())
        },
        "generator-passphrase": { navigation, _ in
            navigation.isFolderListOpen = true
            var options = GeneratorOptions()
            options.kind = .passphrase
            navigation.generator = GeneratorSession(purpose: .standalone, options: options)
        },
        // No reference pictures yet (docs/reference/README.md, "Still to take").
        "generator-username-catchall": { navigation, _ in
            navigation.isFolderListOpen = true
            var options = GeneratorOptions()
            options.kind = .username
            options.username.kind = .catchallEmail
            options.username.domain = "example.org"
            navigation.generator = GeneratorSession(purpose: .standalone, options: options)
        },
        "generator-username": { navigation, _ in
            navigation.isFolderListOpen = true
            var options = GeneratorOptions()
            options.kind = .username
            navigation.generator = GeneratorSession(purpose: .standalone, options: options)
        },
        "dialog-bulk-delete": { navigation, vault in
            navigation.checkedItemIDs = Set(vault.items.filter { !$0.isInTrash }.prefix(3).map(\.id))
            navigation.question = .init(kind: .danger, title: BWText["deleteItemsCount", "3"], text: BWText["deleteItemsDesc"],
                                        acceptTitle: BWText["delete"]) {}
        },
        "dialog-bulk-move": { navigation, vault in
            navigation.bulkMoveItemIDs = vault.items.filter { !$0.isInTrash }.prefix(3).map(\.id)
        },
        "generator-history-empty": { navigation, _ in navigation.showsGeneratorHistory = true },
        "dialog-decryption-error": { navigation, vault in
            navigation.decryptionFailureItemID = vault.items.first { $0.name == "Example Mail" }?.id
        },
        "dialog-attachments": { navigation, vault in
            navigation.attachmentsItemID = vault.items.first { $0.name == "Example Mail" }?.id
        },
        // No reference picture yet (docs/reference/README.md, "Still to take").
        "dialog-password-history": { navigation, vault in
            let id = vault.items.first { $0.name == "Example Mail" }?.id
            navigation.openItemID = id
            navigation.passwordHistoryItemID = id
        },
        "dialog-new-folder": { navigation, _ in
            navigation.isFolderListOpen = true
            navigation.folderDialog = .add
        },
        "dialog-edit-folder": { navigation, vault in
            navigation.isFolderListOpen = true
            if let folder = vault.folders.first(where: { $0.name == "Work" }) ?? vault.folders.first {
                navigation.folderDialog = .edit(folder)
            }
        },
        // No reference picture yet (docs/reference/README.md, "Still to take").
        "menu-row-copy": { navigation, vault in
            navigation.openCopyMenuItemID = vault.items.first { $0.type == .sshKey }?.id
        },
        "menu-row-options": { navigation, vault in
            navigation.isFolderListOpen = true
            navigation.openMenuItemID = vault.items.first { $0.name == "Example Mail" }?.id
        },
        // No reference pictures yet (docs/reference/README.md, "Still to take").
        "menu-row-options-trash": { navigation, vault in
            navigation.filter = .trash
            navigation.openMenuItemID = vault.items.first { $0.isInTrash }?.id
        },
        "dialog-delete-item": { navigation, _ in
            navigation.question = .init(kind: .warning, title: BWText["deleteItem"], text: BWText["deleteItemConfirmation"]) {}
        },
        "dialog-archive-item": { navigation, _ in
            navigation.question = .init(kind: .info, title: BWText["archiveItem"], text: BWText["archiveItemDialogContent"],
                                        acceptTitle: BWText["archiveVerb"]) {}
        },
    ]

    /// Opens the panel of the item with this name.
    private static func open(_ name: String, _ navigation: VaultNavigation, _ vault: VaultContents) {
        navigation.openItemID = vault.items.first { $0.name == name }?.id
    }

    private static func describe(_ menu: NSMenu, depth: Int) -> String {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var text = ""
        for item in menu.items {
            let indent = String(repeating: "    ", count: depth)
            if item.isSeparatorItem {
                text += indent + "---\n"
                continue
            }
            var shortcut = ""
            if !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask
                shortcut = "  [" + (flags.contains(.control) ? "ctrl+" : "") + (flags.contains(.option) ? "opt+" : "")
                    + (flags.contains(.shift) ? "shift+" : "") + (flags.contains(.command) ? "cmd+" : "") + item.keyEquivalent + "]"
            }
            // macOS adds hidden twins with another shortcut to some items ("alternate").
            text += indent + item.title + shortcut + (item.isEnabled ? "" : "  (off)") + (item.state == .on ? "  (checked)" : "")
                + (item.isHidden || item.isAlternate ? "  (hidden twin)" : "") + "\n"
            if let submenu = item.submenu { text += describe(submenu, depth: depth + 1) }
        }
        return text
    }

    /// Adds this edge-case fixture only to the in-memory preview account.
    private func prepareLoginWithoutPassword() async {
        guard model.prefill != nil,
              !model.state.vault.items.contains(where: { $0.name == "Example Login Without Password" }) else { return }
        var draft = ItemDraft(new: .login)
        draft.name = "Example Login Without Password"
        draft.content = .login(.init(username: "only-a-username"))
        _ = try? await model.save(draft)
        for _ in 0..<100 where !model.state.vault.items.contains(where: { $0.name == draft.name }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The window model follows the engine a moment later.
    private func waitForTwoStep() async -> Bool {
        for _ in 0..<60 where model.state.twoStep == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model.state.twoStep != nil
    }

    /// Turns the unlock with Touch ID on for the unlocked account, on the sensor of a test
    /// or picture run, which asks for no finger.
    private func turnTouchIDOn() async -> Bool {
        guard let fakeBiometrics else {
            finish("SCENE FAILED: the scenes of Touch ID need a test or picture run")
            return false
        }
        await fakeBiometrics.setSensorAvailable(true)
        await model.refreshBiometrics()
        try? await model.setBiometricUnlock(true)
        return true
    }

    private func logIn(_ account: (server: URL, email: String, masterPassword: String)) async -> Bool {
        do {
            try await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
            return true
        } catch {
            finish("SCENE FAILED: log-in failed with \(error)")
            return false
        }
    }

    private func finish(_ message: String) {
        print(message)
        fflush(stdout)
    }
}
#endif
