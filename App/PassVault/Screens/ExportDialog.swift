import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// "Export": apps/desktop/src/app/tools/export/export-desktop.component.html around
/// libs/tools/export-vault-ui/src/components/export.component.html. The file format; for the
/// encrypted one the export type and the password of the file; then "confirm vault export",
/// which asks for the master password, and the file panel of the system.
///
/// What PassVault leaves out is in PLAN.md, "Differences from the reference": the select
/// "export from" (the reference shows it only with organizations), the format with
/// attachments, the export type "account restricted", and the strength of the file password.
struct ExportDialog: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation

    private enum Format: Hashable {
        case json, csv, encryptedJSON
    }

    @State private var format = Format.json
    @State private var filePassword = ""
    @State private var confirmation = ""
    @State private var showsFilePassword = false
    /// "Confirm vault export" lies over the dialog.
    @State private var isConfirming = false
    @State private var masterPassword = ""
    @State private var showsMasterPassword = false
    @State private var isWorking = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field {
        case filePassword, confirmation, masterPassword
    }

    var body: some View {
        BWDialog(title: BWText["exportNoun"], size: .large, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                // tools-export-scope-description: span "tw-text-muted tw-block tw-mt-2 tw-mb-4", bitTypography="body2".
                Text(BWText["exportingIndividualVaultScopeDescription"])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Metric.space(2))
                    .padding(.bottom, Metric.space(4))
                // The labels of the formats are no texts of the locale: the reference writes them so.
                // The format is required (`Validators.required`), which the label marks.
                // It is a `select bitInput`, the one select that the browser draws, in a
                // bit-form-field that keeps its "tw-mb-4" at the end of the dialog.
                BWSelect(BWText["fileFormat"], selection: $format, options: [
                    .init(Format.json, ".json"), .init(.csv, ".csv"), .init(.encryptedJSON, ".json (Encrypted)"),
                ], isRequired: true, isNative: true)
                if format == .encryptedJSON { encryption }
            }
        } footer: {
            BWButton(BWText["exportVerb"], kind: .primary, isBlock: false, action: submit)
                .disabled(isWorking)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .overlay {
            if isConfirming { confirmationDialog }
        }
        .onChange(of: format) {
            // The fields of the file password are emptied when the format changes.
            filePassword = ""
            confirmation = ""
        }
        .onDisappear { operation?.cancel() }
    }

    /// bit-radio-group "export type" and the two fields of the file password.
    private var encryption: some View {
        VStack(alignment: .leading, spacing: 0) {
            BWFieldLabel(BWText["exportTypeHeading"])
                .padding(.bottom, Metric.space(2))
            // "Account restricted" is shown and cannot be chosen: the SDK writes the other one.
            VStack(alignment: .leading, spacing: 0) {
                BWRadio(BWText["accountRestricted"], isOn: false) {}
                BWHint(BWText["accountRestrictedOptionDescription"])
                    .padding(.leading, Metric.space(8))
            }
            .disabled(true)
            .opacity(0.6)
            .padding(.bottom, Metric.space(3))
            BWRadio(BWText["passwordProtected"], isOn: true) {}
            BWHint(BWText["passwordProtectedOptionDescription"])
                .padding(.leading, Metric.space(8))
                .padding(.bottom, Metric.space(4))
            BWFormField(BWText["filePassword"], isRequired: true, isFocused: focus == .filePassword,
                        hint: BWText["exportPasswordDescription"]) {
                BWTextInput(text: $filePassword, isSecure: !showsFilePassword, isMonospaced: true)
                    .focused($focus, equals: .filePassword)
            } suffix: {
                BWIconButton(showsFilePassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                    showsFilePassword.toggle()
                }
                BWIconButton(.generate, label: BWText["generatePassword"], size: .small, action: generate)
                BWIconButton(.clone, label: BWText["password"], size: .small) {
                    Task { try? await model.copy(text: filePassword, isSensitive: true) }
                }
                .disabled(filePassword.isEmpty)
            }
            BWFormField(BWText["confirmFilePassword"], isRequired: true, isFocused: focus == .confirmation) {
                BWTextInput(text: $confirmation, isSecure: !showsFilePassword, isMonospaced: true)
                    .focused($focus, equals: .confirmation)
                    .onSubmit(submit)
            } suffix: {
                BWIconButton(showsFilePassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                    showsFilePassword.toggle()
                }
            }
        }
    }

    /// UserVerificationDialogComponent as the export opens it: the warning of the format, the
    /// master password, "continue" and "cancel".
    private var confirmationDialog: some View {
        BWDialog(title: BWText["confirmVaultExport"], onClose: cancelConfirmation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(BWText[format == .encryptedJSON ? "fileEncryptedExportWarningDesc" : "exportUnencryptedWarningDesc"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BWFormField(BWText["masterPass"], isRequired: true, isFocused: focus == .masterPassword, hint: BWText["confirmIdentity"],
                            bottomMargin: 0) {
                    BWTextInput(text: $masterPassword, isSecure: !showsMasterPassword)
                        .focused($focus, equals: .masterPassword)
                        .onSubmit(export)
                } suffix: {
                    BWIconButton(showsMasterPassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        showsMasterPassword.toggle()
                        focus = .masterPassword
                    }
                }
                .padding(.top, Metric.space(6))
            }
        } footer: {
            BWButton(BWText["continue"], kind: .primary, isBlock: false, action: export)
                .disabled(isWorking)
            BWButton(BWText["cancel"], isBlock: false, action: cancelConfirmation)
        }
        .onAppear { focus = .masterPassword }
    }

    private func close() {
        operation?.cancel()
        navigation.isExporting = false
    }

    private func cancelConfirmation() {
        operation?.cancel()
        isConfirming = false
    }

    /// The generator's password with the options the user has set for it.
    private func generate() {
        Task {
            guard let password = try? await model.generate(.password(model.state.settings.generator.password)) else { return }
            filePassword = password
            confirmation = password
        }
    }

    /// `submit()` of export.component.ts: the two passwords of the file are the same, then the
    /// user is verified.
    private func submit() {
        guard !isWorking else { return }
        if format == .encryptedJSON {
            guard !filePassword.isEmpty, !confirmation.isEmpty else {
                let empty = [filePassword, confirmation].count(where: \.isEmpty)
                return navigation.toasts.show(.error, title: BWText["errorOccurred"],
                                              message: BWText.text("fieldsNeedAttention", ["\(empty)"]))
            }
            guard filePassword == confirmation else {
                return navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["filePasswordConfirmationMismatch"])
            }
        }
        masterPassword = ""
        isConfirming = true
    }

    private func export() {
        guard !isWorking else { return }
        isWorking = true
        let chosen: VaultExportFormat = switch format {
        case .json: .json
        case .csv: .csv
        case .encryptedJSON: .encryptedJson(password: filePassword)
        }
        let password = masterPassword
        let context = VaultFileContext(model: model, navigation: navigation)
        operation = navigation.startFileOperation {
            defer { isWorking = false }
            do {
                let session = try await context.session()
                let file = try await model.exportVault(format: chosen, masterPassword: password, session: session)
                try await context.check(session)
                isConfirming = false
                guard let place = try await VaultFileSavePanel.destination(named: Self.fileName(for: chosen, at: Date())) else { return }
                try await context.check(session)
                try await context.prepare { try await VaultFileIO.write(file, to: place) }
                try await context.check(session)
                navigation.toasts.show(.success, message: BWText["exportSuccess"])
                close()
            } catch is CancellationError {
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            } catch EngineError.wrongMasterPassword {
                guard (try? context.checkCurrent()) != nil else { return }
                return navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["invalidMasterPassword"])
            } catch {
                guard (try? context.checkCurrent()) != nil else { return }
                return navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["exportError"])
            }
        }
    }

    /// `ExportHelper.getFileName`: the name of the product, "export" and the time, as
    /// "passvault_export_20261114093000.json"; an encrypted export says so in its name.
    static func fileName(for format: VaultExportFormat, at date: Date, product: String = BWText.settings.productName) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMddHHmmss"
        var isEncrypted = false
        if case .encryptedJson = format { isEncrypted = true }
        return "\(product.lowercased())\(isEncrypted ? "_encrypted" : "")_export_\(stamp.string(from: date)).\(format.fileExtension)"
    }

}
