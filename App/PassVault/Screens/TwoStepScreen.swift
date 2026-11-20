import AppKit
import DesignKit
import Engine
import SwiftUI

/// The second step of a log-in: a code from an authenticator app or from an email.
/// Source: libs/auth/src/angular/two-factor-auth (two-factor-auth.component.html and its child
/// components for the authenticator app and for email). There is no reference picture yet.
///
/// The engine holds the waiting log-in; this screen sends the code or gives up. As in the
/// reference, the logo leads back to the first screen.
struct TwoStepScreen: View {
    let model: AppModel
    @Bindable var flow: LogInFlow
    let toasts: ToastCenter
    let challenge: TwoStepChallenge

    @State private var code = ""
    @State private var remember = false
    @State private var problem: String?
    @State private var keyReader = WebAuthnSession()
    @State private var isReadingKey = false
    @FocusState private var isCodeFocused: Bool

    /// The chosen method, or the one the reference prefers: a security key, then the
    /// authenticator app, then email. The engine lists them in that order.
    private var method: TwoStepMethod {
        if let chosen = flow.twoStepMethod, challenge.methods.contains(chosen) { return chosen }
        return challenge.methods.first ?? .authenticator
    }

    private var subtitleKey: String {
        switch method {
        case .authenticator: "enterTheCodeFromYourAuthenticatorApp"
        case .email: "enterTheCodeSentToYourEmail"
        case .webAuthn: "followTheStepsBelowToFinishLoggingInWithSecurityKey"
        }
    }

    var body: some View {
        AnonLayout(illustration: .gooseKey, title: BWText["verifyYourIdentity"], subtitle: BWText[subtitleKey],
                   onHome: cancel) {
            AccountMenuButton(model: model)
        } content: {
            form
        } footer: {
            EmptyView()
        }
        .onAppear {
            isCodeFocused = true
            sendEmailIfNeeded()
        }
        .onDisappear { keyReader.cancel() }
        // Another method starts with an empty form, and email with a new code on its way.
        .onChange(of: method) {
            keyReader.cancel()
            code = ""
            remember = false
            problem = nil
            isCodeFocused = true
            sendEmailIfNeeded()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server = flow.serverLabel {
                Text(verbatim: server).textStyle(.sm)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Metric.space(3))
            }
            if method == .webAuthn {
                // two-factor-auth-webauthn: the button that has the key read, in place of the
                // frame of the reference. A browser of the system does the reading.
                BWButton(BWText[isReadingKey ? "awaitingSecurityKeyInteraction" : "readSecurityKey"], kind: .primary, action: readKey)
                    .disabled(isReadingKey || model.state.activity != nil)
                    .padding(.bottom, Metric.space(3))
            } else {
                // bit-form-field; for email with "!tw-mb-0" and the link "resend code" under it in a div "tw-mb-4".
                BWFormField(BWText["verificationCode"], isRequired: true, isFocused: isCodeFocused, error: problem,
                            bottomMargin: method == .email ? 0 : Metric.space(4)) {
                    BWTextInput(text: $code)
                        .focused($isCodeFocused)
                        .onSubmit(submit)
                }
            }
            if method == .email {
                // a bitTypography="helper" bitLink: 10.5 pixels in the colour of a link, on the 20 pixel line of its block.
                BWLink(BWText["resendCode"], size: TextStyle.xs.size) { sendEmail(saysSo: true) }
                    .frame(height: TextStyle.body.lineHeight)
                    .padding(.bottom, Metric.space(4))
            }
            // bit-form-control: "tw-block tw-mb-4"
            BWCheckbox(BWText["dontAskAgainOnThisDeviceFor30Days"], isOn: $remember)
                .padding(.bottom, Metric.space(4))
            // div "tw-flex tw-flex-col tw-space-y-3"
            VStack(spacing: Metric.space(3)) {
                // A security key has no code to send: its answer continues the log-in.
                if method != .webAuthn {
                    BWButton(BWText["continueLoggingIn"], kind: .primary, action: submit)
                        .disabled(model.state.activity != nil)
                    // p "tw-text-center tw-mb-0"
                    Text(BWText["or"]).textStyle(.body).frame(maxWidth: .infinity)
                }
                if challenge.methods.count > 1 {
                    BWButton(BWText["selectAnotherMethod"]) { flow.isTwoStepMethodDialogOpen = true }
                }
                BWButton(BWText["useYourRecoveryCode"], action: openRecovery)
            }
        }
        // A typed character clears the message; a pasted code is sent at once, as in the reference.
        .onChange(of: code) { old, new in
            problem = nil
            if new.count - old.count > 1, !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submit() }
        }
    }

    /// Has a browser of the system read the security key on the page of the server, and sends
    /// its answer as the code of the method.
    private func readKey() {
        guard !isReadingKey, let server = flow.serverURL, let request = challenge.webAuthnRequest,
              let page = WebAuthnConnector.url(server: server, request: request,
                                               header: BWText["followTheStepsBelowToFinishLoggingInWithSecurityKey"],
                                               button: BWText["readSecurityKey"], returnButton: BWText["continueLoggingIn"]) else {
            toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            return
        }
        isReadingKey = true
        Task {
            let outcome = await keyReader.read(page, over: NSApp.keyWindow)
            isReadingKey = false
            switch outcome {
            case .token(let answer): send(answer, method: .webAuthn)
            case .failed: toasts.show(.error, title: BWText["errorOccurred"], message: BWText["webauthnCancelOrTimeout"])
            }
        }
    }

    private func submit() {
        guard model.state.activity == nil else { return }
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else {
            problem = BWText["inputRequired"]
            return
        }
        problem = nil
        send(entered, method: method)
    }

    private func send(_ entered: String, method: TwoStepMethod) {
        Task {
            do {
                try await model.submitTwoStepCode(entered, method: method, rememberDevice: remember)
            } catch EngineError.invalidTwoStepCode {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidVerificationCode"])
            } catch EngineError.invalidState, EngineError.cancelled {
                // The log-in was given up meanwhile; the window is already back at the first screen.
            } catch EngineError.server(let message) {
                toasts.show(.error, title: BWText["errorOccurred"], message: message)
            } catch {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            }
        }
    }

    /// The email method sends a code when it is shown, without a note.
    private func sendEmailIfNeeded() {
        if method == .email { sendEmail(saysSo: false) }
    }

    private func sendEmail(saysSo: Bool) {
        Task {
            do {
                try await model.sendTwoStepEmail()
                if saysSo {
                    toasts.show(.success, message: BWText["verificationCodeEmailSent", challenge.emailHint ?? ""])
                }
            } catch {
                // The reference only writes this to its log.
            }
        }
    }

    /// Opens the page of the web vault where a recovery code turns two-step login off.
    private func openRecovery() {
        guard let server = flow.serverURL, ["http", "https"].contains(server.scheme?.lowercased() ?? ""),
              let url = URL(string: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/#/recover-2fa")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func cancel() {
        keyReader.cancel()
        flow.twoStepEnded()
        Task { await model.cancelTwoStepLogin() }
    }
}

/// The dialog "select two-step login method": one row for each method the account has.
/// Source: libs/auth/src/angular/two-factor-auth/two-factor-options.component.html.
struct TwoStepMethodsDialog: View {
    @Bindable var flow: LogInFlow
    let challenge: TwoStepChallenge

    var body: some View {
        BWDialog(title: BWText["selectTwoStepLoginMethod"], size: .large, hasAltGround: true, onClose: close) {
            // bit-item-group. The reference lists email before the authenticator app, and a
            // security key last.
            VStack(spacing: 0) {
                ForEach([TwoStepMethod.email, .authenticator, .webAuthn].filter(challenge.methods.contains), id: \.self) { method in
                    // button bit-item-content class="tw-h-auto md:tw-h-20"
                    BWItem(BWText[Self.texts[method]?.title ?? ""], secondary: BWText[Self.texts[method]?.description ?? ""],
                           height: Metric.space(20)) {
                        flow.twoStepMethod = method
                        close()
                    } start: {
                        // div slot="start" class="tw-w-16 md:tw-w-20 tw-mr-2 sm:tw-mr-4" around the picture of the method
                        Illustration(method == .email ? .emailCodeSent : method == .webAuthn ? .twoFactorWebAuthn : .twoFactorAuthenticator)
                            .frame(width: Metric.space(20))
                            .padding(.trailing, Metric.space(4))
                    }
                }
            }
        } footer: {
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onExitCommand(perform: close)
    }

    private static let texts: [TwoStepMethod: (title: String, description: String)] = [
        .email: ("emailTitle", "emailDescV2"), .authenticator: ("authenticatorAppTitle", "authenticatorAppDescV2"),
        .webAuthn: ("webAuthnTitle", "webAuthnDesc"),
    ]

    private func close() {
        flow.isTwoStepMethodDialogOpen = false
    }
}
