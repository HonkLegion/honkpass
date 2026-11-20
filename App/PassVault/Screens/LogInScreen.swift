import DesignKit
import Engine
import SwiftUI

/// Log-in in two steps: the email, then the master password.
/// Reference: docs/reference/log-in-email-*.png and log-in-password-*.png.
/// Source: libs/auth/src/angular/login/login.component.html.
///
/// Controls of features that PassVault does not have yet are shown disabled (PLAN.md, allowed deviations).
struct LogInScreen: View {
    let model: AppModel
    @Bindable var flow: LogInFlow
    let toasts: ToastCenter
    @State private var masterPassword = ""
    /// The address on the page of the hint. It starts as the address of the log-in.
    @State private var hintEmail = ""
    @State private var isAskingForHint = false
    @State private var showsPassword = false
    @State private var problem: String?
    /// The server knows this device for the address: `isKnownDevice` of login.component.ts.
    @State private var isKnownDevice = false
    @FocusState private var focus: Field?

    private enum Field {
        case email, masterPassword, hintEmail
    }

    var body: some View {
        switch flow.step {
        case .email: emailStep
        case .masterPassword: masterPasswordStep
        case .hint: hintStep
        }
    }

    // MARK: Step 1

    private var emailStep: some View {
        AnonLayout(illustration: .gooseKey, title: BWText["loginPageEmailEntryScreenTitle"]) {
            accountMenuButton
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                BWFormField(BWText["emailAddress"], isRequired: true, isFocused: focus == .email, error: problem) {
                    BWTextInput(text: $flow.email)
                        .focused($focus, equals: .email)
                        .onSubmit(continueToMasterPassword)
                }
                // bit-form-control: "tw-block" "tw-mb-4"
                BWCheckbox(BWText["rememberEmail"], isOn: $flow.rememberEmail)
                    .padding(.bottom, Metric.space(4))
                // "tw-grid tw-gap-3"
                VStack(spacing: Metric.space(3)) {
                    BWButton(BWText["continue"], kind: .primary, action: continueToMasterPassword)
                    Text(BWText["or"]).textStyle(.body).frame(maxWidth: .infinity)
                    BWButton(BWText["useSingleSignOn"], icon: .provider) {}
                        .disabled(true)
                }
            }
        } secondary: {
            HStack(alignment: .firstTextBaseline, spacing: wordSpace) {
                Text(BWText["newToBitwarden"])
                BWLink(BWText["createAccount"]) {}
                    .disabled(true)
            }
        } footer: {
            environmentSelector
        }
        .onAppear { focus = .email }
    }

    // MARK: The hint of the master password

    /// libs/auth/src/angular/password-hint/password-hint.component.html, in the layout of its
    /// route: the server sends the hint to the address of the account. It answers the same for
    /// an address it does not know.
    private var hintStep: some View {
        AnonLayout(illustration: .gooseKey, title: BWText["requestPasswordHint"],
                   subtitle: BWText["enterYourAccountEmailAddressAndYourPasswordHintWillBeSentToYou"]) {
            accountMenuButton
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                BWFormField(BWText["accountEmail"], isFocused: focus == .hintEmail) {
                    BWTextInput(text: $hintEmail)
                        .focused($focus, equals: .hintEmail)
                        .onSubmit(requestHint)
                }
                BWButton(BWText["requestHint"], kind: .primary, action: requestHint)
                    .disabled(isAskingForHint)
                    .padding(.bottom, Metric.space(2))
                BWButton(BWText["cancel"]) { flow.step = .masterPassword }
            }
        } secondary: {
            EmptyView()
        } footer: {
            EmptyView()
        }
        .onAppear { focus = .hintEmail }
    }

    /// The checks and the toasts of password-hint.component.ts.
    private func requestHint() {
        let email = hintEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else {
            return toasts.show(.error, title: BWText["errorOccurred"], message: BWText["emailRequired"])
        }
        guard email.contains("@") else {
            return toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidEmail"])
        }
        guard let server = flow.serverURL, !isAskingForHint else { return }
        isAskingForHint = true
        Task {
            defer { isAskingForHint = false }
            do {
                try await model.requestPasswordHint(server: server, email: email)
                toasts.show(.success, message: BWText["masterPassSent"])
                flow.step = .masterPassword
            } catch EngineError.server(let message) {
                // What the server says: a server without mail says so, or gives the hint here.
                let text = message.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                toasts.show(.error, title: BWText["errorOccurred"], message: text ?? BWText["unexpectedError"])
            } catch {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            }
        }
    }

    // MARK: Step 2

    private var masterPasswordStep: some View {
        AnonLayout(illustration: .gooseKey, title: BWText["loginPageMasterPasswordEntryScreenTitle"], subtitle: flow.email) {
            accountMenuButton
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                environmentSelector.padding(.bottom, Metric.space(3))
                // bit-form-field class="!tw-mb-1"
                BWFormField(BWText["masterPass"], isRequired: true, isFocused: focus == .masterPassword, error: problem,
                            bottomMargin: Metric.space(1)) {
                    BWTextInput(text: $masterPassword, isSecure: !showsPassword)
                        .focused($focus, equals: .masterPassword)
                        .onSubmit(logIn)
                } suffix: {
                    BWIconButton(showsPassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        showsPassword.toggle()
                        focus = .masterPassword
                    }
                }
                // a bitLink class="tw-inline-block tw-mb-4": "tw-leading-none tw-py-0.5"
                BWLink(BWText["hint"]) {
                    hintEmail = flow.email
                    flow.step = .hint
                }
                    // 14 + 2 x "tw-py-0.5", and one pixel from the line the inline block sits on
                    // (measured in docs/reference/log-in-password-*.png).
                    .frame(height: TextStyle.body.size + 2 * Metric.space(0.5) + 1)
                    .padding(.bottom, Metric.space(4))
                // "tw-grid tw-gap-3"
                VStack(spacing: Metric.space(3)) {
                    BWButton(BWText["logIn"], kind: .primary, action: logIn)
                        .disabled(model.state.activity != nil)
                    // "Log in with device" is there for a device the server knows. PassVault
                    // cannot do it, so the button is disabled (PLAN.md, "Features PassVault lacks").
                    if isKnownDevice {
                        Text(BWText["or"]).textStyle(.body).frame(maxWidth: .infinity)
                        BWButton(BWText["loginWithDevice"], icon: .mobile) {}
                            .disabled(true)
                    }
                    BWButton(BWText["back"]) {
                        problem = nil
                        masterPassword = ""
                        // "Reset known device state when going back to email entry".
                        isKnownDevice = false
                        flow.step = .email
                    }
                }
            }
        } secondary: {
            HStack(alignment: .firstTextBaseline, spacing: wordSpace) {
                Text(BWText["newToBitwarden"])
                BWLink(BWText["createAccount"]) {}
                    .disabled(true)
            }
        } footer: {
            EmptyView()
        }
        .onAppear { focus = .masterPassword }
        // The server is asked when this step opens, for the address of the step before.
        .task(id: flow.email) {
            guard let server = flow.serverURL else { return }
            isKnownDevice = await model.isKnownDevice(server: server, email: flow.email)
        }
    }

    // MARK: Shared parts

    /// The width of a space between a text and the link after it.
    private var wordSpace: CGFloat { TextStyle.body.size * 0.28 }

    /// The "…" button of the account switcher without an active account:
    /// div "tw-py-3" > div "tw-rounded-full tw-bg-bg-brand" > icon button, buttonType contrast.
    /// Its menu lists the accounts that are logged in and wait: one of them takes the place of
    /// this log-in.
    private var accountMenuButton: some View {
        AccountMenuButton(model: model)
    }

    /// Source: libs/angular/src/auth/environment-selector. PassVault knows self-hosted servers only,
    /// so the link opens the server dialog without the menu of regions.
    private var environmentSelector: some View {
        HStack(alignment: .firstTextBaseline, spacing: TextStyle.sm.size * 0.28) {
            Text("\(BWText["accessing"]):")
            // b "tw-text-primary-600 tw-font-medium" inside the link, then bwi-angle-down "bwi-fw bwi-sm".
            // The link is a button, and buttons have the 14 pixel font of the desktop styles.
            BWLink(flow.serverLabel ?? BWText["selfHostedServer"], size: TextStyle.body.size, weight: 500, colour: .primary600, trailingIcon: .angleDown) {
                flow.isServerDialogOpen = true
            }
        }
        // div "tw-mb-1". The 14 pixel link makes the line 2.75 pixels higher than its text style
        // (measured in docs/reference/log-in-email-*.png).
        .padding(.bottom, Metric.space(1) + 2.75)
    }

    // MARK: Actions

    private func continueToMasterPassword() {
        let email = flow.email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else {
            problem = BWText["emailRequired"]
            return
        }
        guard email.contains("@") else {
            problem = BWText["invalidEmail"]
            return
        }
        // Without a server there is nothing to log in to: ask for it first.
        guard flow.serverURL != nil else {
            flow.isServerDialogOpen = true
            return
        }
        problem = nil
        flow.email = email
        flow.rememberEmailIfWanted()
        flow.step = .masterPassword
    }

    private func logIn() {
        guard model.state.activity == nil else { return }
        guard !masterPassword.isEmpty else {
            problem = BWText["masterPasswordRequired"]
            return
        }
        guard let server = flow.serverURL else {
            flow.isServerDialogOpen = true
            return
        }
        problem = nil
        Task {
            do {
                try await model.logIn(server: server, email: flow.email, masterPassword: masterPassword)
                masterPassword = ""
            } catch EngineError.twoStepLoginRequired {
                // The engine keeps the log-in and the window shows the two-step screen.
                masterPassword = ""
            } catch EngineError.twoStepMethodsUnsupported {
                problem = BWText["noTwoStepProviders"]
            } catch EngineError.invalidCredentials {
                problem = BWText["invalidMasterPassword"]
            } catch EngineError.server(let message) {
                problem = message
            } catch {
                problem = BWText["unexpectedError"]
            }
        }
    }
}

/// The "…" button of the screens without an account, with the menu of the accounts that wait.
struct AccountMenuButton: View {
    let model: AppModel
    @State private var isMenuOpen = false

    var body: some View {
        BWIconButton(.ellipsisH, label: BWText["switchAccount"], kind: .contrast) { isMenuOpen = true }
            .disabled(model.state.otherAccounts.isEmpty)
            .padding(.vertical, Metric.space(3))
            .bwMenu(isOpen: $isMenuOpen) { AccountSwitcher.items(model: model, hasAccount: false) }
    }
}
