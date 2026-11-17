import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The locked vault. Reference: docs/reference/lock-*.png (the master password form).
/// Source: libs/key-management-ui/src/lock/components: lock.component.html for the forms of
/// Touch ID and of the PIN, and master-password-lock for the master password form. The forms of
/// Touch ID and of the PIN have no reference picture yet.
struct LockScreen: View {
    /// `UnlockOption`: the ways to unlock. The reference starts with the first one that can
    /// open the vault, in this order.
    enum Option {
        case touchID, pin, masterPassword
    }

    let model: AppModel
    let toasts: ToastCenter
    let account: Account
    @State private var masterPassword = ""
    @State private var pin = ""
    @State private var showsSecret = false
    @State private var problem: String?
    /// The form the user is at. A way that stops working gives its place to the next one.
    @State private var chosen: Option
    /// The system is asking for Touch ID.
    @State private var isAskingForTouchID = false
    @FocusState private var isFieldFocused: Bool

    init(model: AppModel, toasts: ToastCenter, account: Account) {
        self.model = model
        self.toasts = toasts
        self.account = account
        _chosen = State(initialValue: model.state.biometrics.canUnlock ? .touchID
            : (model.state.pin.canUnlock ? .pin : .masterPassword))
    }

    /// The form that is shown: the chosen one while it can open the vault.
    private var option: Option {
        switch chosen {
        case .touchID where model.state.biometrics.canUnlock: .touchID
        case .touchID, .pin: model.state.pin.canUnlock ? .pin : .masterPassword
        case .masterPassword: .masterPassword
        }
    }

    private var showsPinForm: Bool { option == .pin }

    var body: some View {
        AnonLayout(illustration: .gooseKey, title: BWText["yourVaultIsLockedV2"], subtitle: account.email) {
            EmptyView()
        } content: {
            if option == .touchID { touchIDForm } else { secretForm }
        } footer: {
            // "showReadonlyHostname": the host, with its port, and no link.
            Text("\(BWText["accessing"]) \(hostname)")
        }
        .onAppear { isFieldFocused = true }
        .task {
            // A keyboard with Touch ID may have come or gone since the engine last looked.
            await model.refreshBiometrics()
            askForTouchIDAtStart()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshBiometrics()
                // A start may show the window before the app is the one in front.
                askForTouchIDAtStart()
            }
        }
        // The first lock screen after a start is over: a later lock does not ask by itself.
        .onDisappear { model.hasAskedForTouchIDAtStart = true }
        .disabled(model.state.activity == .unlocking)
        .overlay {
            if model.state.activity == .unlocking {
                LoginProgressScreen(phase: model.state.authenticationPhase ?? .authenticating)
            }
        }
    }

    /// "Biometrics Unlock" of lock.component.html: the button, "or", and the other ways.
    private var touchIDForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            // button bitButton buttonType="primary" block class="tw-mb-3", [loading] while the system asks
            BWButton(BWText["unlockWithTouchId"], kind: .primary, action: unlockWithTouchID)
                .disabled(isAskingForTouchID || model.state.activity != nil)
                .padding(.bottom, Metric.space(3))
            Text(BWText["or"])
                .textStyle(.body)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            if model.state.pin.canUnlock {
                BWButton(BWText["unlockWithPin"]) { use(.pin) }
                    .padding(.top, Metric.space(3))
            }
            BWButton(BWText["unlockWithMasterPassword"]) { use(.masterPassword) }
                .padding(.top, Metric.space(3))
            BWButton(BWText["logOut"], action: logOut)
                .padding(.top, Metric.space(3))
        }
    }

    private var secretForm: some View {
            VStack(alignment: .leading, spacing: 0) {
                if showsPinForm {
                    // input type="password" class="tw-font-mono" required
                    BWFormField(BWText["pin"], isRequired: true, isFocused: isFieldFocused) {
                        BWTextInput(text: $pin, isSecure: !showsSecret, isMonospaced: true)
                            .focused($isFieldFocused)
                            .onSubmit(unlockWithPin)
                    } suffix: {
                        visibilityButton
                    }
                } else {
                    BWFormField(BWText["masterPass"], isRequired: true, isFocused: isFieldFocused, error: problem) {
                        BWTextInput(text: $masterPassword, isSecure: !showsSecret, isMonospaced: true)
                            .focused($isFieldFocused)
                            .onSubmit(unlockWithMasterPassword)
                    } suffix: {
                        visibilityButton
                    }
                }
                // "tw-flex tw-flex-col tw-space-y-3"; the paragraph also has the 10 pixel bottom margin of the desktop styles.
                BWButton(BWText["unlock"], kind: .primary, action: showsPinForm ? unlockWithPin : unlockWithMasterPassword)
                    .disabled(model.state.activity != nil)
                Text(BWText["or"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Metric.space(3))
                    .padding(.bottom, 10)
                // The buttons that change the way to unlock, Touch ID first, then "log out".
                if model.state.biometrics.canUnlock {
                    BWButton(BWText["unlockWithTouchId"]) { use(.touchID) }
                        .padding(.top, Metric.space(3))
                }
                if showsPinForm {
                    BWButton(BWText["unlockWithMasterPassword"]) { use(.masterPassword) }
                        .padding(.top, Metric.space(3))
                } else if model.state.pin.canUnlock {
                    BWButton(BWText["unlockWithPin"]) { use(.pin) }
                        .padding(.top, Metric.space(3))
                }
                BWButton(BWText["logOut"], action: logOut)
                    .padding(.top, Metric.space(3))
            }
    }

    private var visibilityButton: some View {
        BWIconButton(showsSecret ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
            showsSecret.toggle()
            isFieldFocused = true
        }
    }

    private var hostname: String {
        let host = account.serverURL.host(percentEncoded: false) ?? ""
        return account.serverURL.port.map { "\(host):\($0)" } ?? host
    }

    /// `swapUnlockOption`: the other form, empty. The form of Touch ID asks at once.
    private func use(_ option: Option) {
        chosen = option
        masterPassword = ""
        pin = ""
        problem = nil
        showsSecret = false
        isFieldFocused = true
        if option == .touchID { unlockWithTouchID() }
    }

    /// `desktopAutoPromptBiometrics`: with "ask for Touch ID on app start" the question of the
    /// system comes by itself, once after a start, and only for a window the user looks at.
    private func askForTouchIDAtStart() {
        guard !model.hasAskedForTouchIDAtStart, model.state.settings.asksForBiometricsOnStart, option == .touchID,
              NSApp.isActive else { return }
        model.hasAskedForTouchIDAtStart = true
        unlockWithTouchID()
    }

    /// `unlockViaBiometrics`: the system asks for a finger, or for the password of the Mac.
    /// A question the user closes says nothing more; another failure is told in a toast.
    private func unlockWithTouchID() {
        guard !isAskingForTouchID else { return }
        isAskingForTouchID = true
        // The question was asked: the start does not ask a second time.
        model.hasAskedForTouchIDAtStart = true
        Task {
            defer { isAskingForTouchID = false }
            do {
                // "touchIdConsentMessage": the question says "PassVault is trying to unlock your vault".
                try await model.unlockWithBiometrics(reason: BWText["touchIdConsentMessage"])
            } catch EngineError.biometrics(.cancelled), EngineError.cancelled, EngineError.invalidState, EngineError.busy {
                // The user closed the question, or the vault was opened another way meanwhile.
            } catch {
                toasts.show(.error, title: BWText["biometricsFailedTitle"], message: BWText["couldNotCompleteBiometrics"])
            }
        }
    }

    /// `submit` of master-password-lock.component.ts: a missing password marks the field and
    /// says so in a toast; a wrong one, like every other failure, is the toast "invalid master
    /// password". What was typed stays.
    private func unlockWithMasterPassword() {
        problem = nil
        guard !masterPassword.isEmpty else {
            problem = BWText["inputRequired"]
            toasts.show(.error, title: BWText["errorOccurred"], message: BWText["masterPasswordRequired"])
            return
        }
        Task {
            do {
                try await model.unlock(masterPassword: masterPassword)
            } catch {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidMasterPassword"])
            }
        }
    }

    /// The reference answers a missing or wrong PIN with a toast and keeps what was typed. After
    /// too many wrong PINs the engine has logged the account out.
    private func unlockWithPin() {
        guard !pin.trimmingCharacters(in: .whitespaces).isEmpty else {
            toasts.show(.error, title: BWText["errorOccurred"], message: BWText["pinRequired"])
            return
        }
        Task {
            do {
                try await model.unlock(pin: pin)
            } catch EngineError.wrongPin {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidPin"])
            } catch EngineError.tooManyPinAttempts {
                toasts.show(.error, message: BWText["tooManyInvalidPinEntryAttemptsLoggingOut"])
            } catch EngineError.invalidState {
                // The PIN stopped working meanwhile; the form of the master password is shown.
                chosen = .masterPassword
            } catch {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            }
        }
    }

    /// The reference asks first: a dialog "log out" with "are you sure you want to log out?".
    private func logOut() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BWText["logOut"]
        alert.informativeText = BWText["logOutConfirmation"]
        alert.addButton(withTitle: BWText["logOut"])
        alert.addButton(withTitle: BWText["cancel"])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.logOut() }
    }
}

/// The items of the menu of accounts, and what they do.
/// The account at the bottom of the side navigation: the avatar, in the open navigation with
/// the address and the server, in a border. It opens the menu of the accounts, which the
/// reference opens from the avatar of the header (PLAN.md, "Differences from the reference").
struct AccountNavButton: View {
    let model: AppModel
    let account: Account
    /// Set, it opens the menu. For a picture of it.
    var opensMenu = false
    @State private var isMenuOpen = false
    @State private var avatar: NSImage?

    var body: some View {
        NavAccountButton(name: model.state.accountName, email: account.email, id: account.id, image: avatar) { isMenuOpen = true }
            .bwMenu(isOpen: $isMenuOpen, minWidth: 13 * Metric.rem, rowGap: 0) { AccountSwitcher.items(model: model, hasAccount: true) }
            .onChange(of: opensMenu, initial: true) {
                if opensMenu { isMenuOpen = true }
            }
            .task(id: account.id) {
                avatar = nil
                let data = await model.accountAvatar()
                guard !Task.isCancelled else { return }
                avatar = data.flatMap(NSImage.init(data:))
            }
    }
}

@MainActor
enum AccountSwitcher {
    static func items(model: AppModel, hasAccount: Bool, onAdd: (@MainActor () -> Void)? = nil) -> [BWMenuItem] {
        let others = model.state.otherAccounts
        // One row for each account that waits: its address and its server. It is locked there.
        var items = others.map { other in
            BWMenuItem(other.email + " · " + (other.serverURL.host ?? other.serverURL.absoluteString), icon: .lock,
                       iconPlace: .startSlot) {
                Task { try? await model.switchAccount(to: other.id) }
            }
        }
        guard hasAccount else { return items }
        // Separate waiting accounts from the action, without an empty leading group.
        if !items.isEmpty { items.append(.divider) }
        // "view.numberOfAccounts < 4": four accounts beside the active one are the limit.
        if others.count + 1 < Engine.accountLimit {
            // A bit-icon without `fixedWidth` before the text.
            items.append(BWMenuItem(BWText["addAccount"], icon: .plus, iconPlace: .inlineNarrow) {
                Task {
                    guard (try? await model.addAccount()) != nil else { return }
                    onAdd?()
                }
            })
        } else {
            items.append(BWMenuItem(BWText["accountSwitcherLimitReached"], isEnabled: false) {})
        }
        return items
    }
}
