import DesignKit
import SwiftUI

/// The dialog of an item that asks for the master password again.
/// Reference: docs/reference/item-reprompt-*.png. Source: libs/vault/src/components/password-reprompt.component.html.
struct MasterPasswordPrompt: View {
    let model: AppModel
    let navigation: VaultNavigation
    @State private var masterPassword = ""
    @State private var showsPassword = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        BWDialog(title: BWText["passwordConfirmation"], onClose: cancel) {
            VStack(alignment: .leading, spacing: 0) {
                // The text stands in the body of the dialog without an element of its own.
                Text(BWText["passwordConfirmationDesc"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // bit-form-field disableMargin class="tw-mt-6"
                BWFormField(BWText["masterPass"], isRequired: true, isFocused: isFieldFocused, bottomMargin: 0) {
                    BWTextInput(text: $masterPassword, isSecure: !showsPassword)
                        .focused($isFieldFocused)
                        .onSubmit(confirm)
                } suffix: {
                    BWIconButton(showsPassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        showsPassword.toggle()
                        isFieldFocused = true
                    }
                }
                .padding(.top, Metric.space(6))
            }
        } footer: {
            BWButton(BWText["ok"], kind: .primary, isBlock: false, action: confirm)
            BWButton(BWText["cancel"], isBlock: false, action: cancel)
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: cancel)
    }

    /// A wrong password is answered by a toast, as in the reference; the dialog stays open.
    private func confirm() {
        Task {
            guard await model.isMasterPassword(masterPassword) else {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidMasterPassword"])
                return
            }
            let action = navigation.protectedAction
            navigation.protectedAction = nil
            action?.run()
        }
    }

    private func cancel() {
        navigation.protectedAction = nil
    }
}
