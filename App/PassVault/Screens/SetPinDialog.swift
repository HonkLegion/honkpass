import DesignKit
import Engine
import SwiftUI

/// The dialog that sets the PIN, opened by the checkbox "unlock with PIN" of the settings.
/// Source: apps/desktop/src/auth/components/set-pin.component.html. There is no reference picture yet.
struct SetPinDialog: View {
    let model: AppModel
    let toasts: ToastCenter
    let onClose: () -> Void

    @State private var pin = ""
    @State private var showsPin = false
    /// The reference ticks this for an account with a master password.
    @State private var asksForMasterPassword = true
    @State private var problem: String?
    @State private var isSaving = false
    @FocusState private var isPinFocused: Bool

    var body: some View {
        BWDialog(title: BWText["unlockWithPin"], onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                // p: the body text with the 10 pixel bottom margin of the desktop styles.
                Text(BWText["setYourPinCode"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                // bit-form-field; the control is required and at least four characters long.
                BWFormField(BWText["pin"], isRequired: true, isFocused: isPinFocused, error: problem) {
                    BWTextInput(text: $pin, isSecure: !showsPin, isMonospaced: true)
                        .focused($isPinFocused)
                        .onSubmit(submit)
                } suffix: {
                    BWIconButton(showsPin ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        showsPin.toggle()
                        isPinFocused = true
                    }
                }
                // label "tw-flex tw-items-start tw-gap-2" around a bitCheckbox and a span: not a
                // bit-form-control, so the text has the body style.
                HStack(alignment: .top, spacing: Metric.space(2)) {
                    BWCheckboxBox(isOn: $asksForMasterPassword, label: BWText["lockWithMasterPassOnRestart1"])
                        // "!-tw-mt-px !-tw-mb-px !-tw-ms-px"
                        .padding(.top, -1)
                        .padding(.bottom, -1)
                        .padding(.leading, -1)
                    Text(BWText["lockWithMasterPassOnRestart1"])
                        .textStyle(.body)
                        .onTapGesture { asksForMasterPassword.toggle() }
                }
            }
        } footer: {
            if isSaving {
                ProgressView().controlSize(.small)
                Text(BWText["loading"]).textStyle(.sm)
            }
            BWButton(BWText["ok"], kind: .primary, isBlock: false, action: submit)
                .disabled(isSaving)
            BWButton(BWText["cancel"], isBlock: false, action: close)
                .disabled(isSaving)
        }
        .disabled(isSaving)
        .onExitCommand(perform: close)
        .onChange(of: pin) { problem = nil }
    }

    private func submit() {
        guard !isSaving else { return }
        guard !pin.trimmingCharacters(in: .whitespaces).isEmpty else {
            problem = BWText["inputRequired"]
            return
        }
        guard pin.count >= Engine.minimumPinLength else {
            problem = BWText["inputMinLength", String(Engine.minimumPinLength)]
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.setPin(pin, asksForMasterPasswordAfterRestart: asksForMasterPassword)
                onClose()
            } catch {
                toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            }
        }
    }

    private func close() {
        if !isSaving { onClose() }
    }
}
