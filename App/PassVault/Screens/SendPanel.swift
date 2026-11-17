import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The panel of a Send beside the list: the view of a Send of the vault, its form, or the form
/// of a new one. Source: libs/tools/send/send-ui/src/add-edit/send-add-edit-dialog (the frame
/// and its footer) and send-form (the sections). No reference picture yet.
///
/// "Specific people" of the select "who can view" is left out (PLAN.md, differences).
struct SendPanel: View {
    let model: AppModel
    let navigation: VaultNavigation
    @Bindable var form: SendForm
    @FocusState private var focus: String?

    private var actions: SendActions { SendActions(model: model, navigation: navigation) }

    var body: some View {
        BWDrawer(title: title, onClose: { navigation.leaveForm { navigation.sendForm = nil } }) {
            VStack(alignment: .leading, spacing: 0) {
                if !form.isEditing, let send = form.original, !send.summary.isDisabled { link(of: send) }
                details
                options
            }
            // Return in a field submits the form, as in the reference.
            .onSubmit { if form.isEditing { save() } }
        } footer: {
            footer
        }
        .onAppear { if form.original == nil { focus = "name" } }
    }

    /// `headerText` of send-add-edit-dialog.component.ts.
    private var title: String {
        let isText = form.type == .text
        if form.original == nil { return BWText[isText ? "newItemHeaderTextSendV2" : "newItemHeaderFileSendV2"] }
        if form.isEditing { return BWText[isText ? "editItemHeaderTextSendV2" : "editItemHeaderFileSendV2"] }
        return BWText[isText ? "viewTextSendHeader" : "viewFileSendHeader"]
    }

    // MARK: The link

    /// bit-card of send-form.component.html: the link of the Send and the button that copies it.
    private func link(of send: VaultSend) -> some View {
        BWCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(BWText["sendLink"])
                    .textStyle(.h4)
                    .foregroundStyle(.theme(.textMain))
                // div "tw-text-muted tw-mt-2 tw-mb-4 tw-truncate" bitTypography="body2"
                Text(model.state.session.account.flatMap { send.link(server: $0.serverURL) } ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
                    .padding(.top, Metric.space(2))
                    .padding(.bottom, Metric.space(4))
                    .accessibilityHidden(true)
                BWButton(BWText["copy"], kind: .primary, startIcon: .clone) { actions.copyLink(of: send.id) }
            }
        }
    }

    // MARK: Send details

    /// send-details.component.html
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(BWText["sendDetails"])
                .padding(.top, Metric.space(2))
            BWCard {
                VStack(alignment: .leading, spacing: 0) {
                    // bit-label: "Send" and the word "name" in small letters.
                    let nameLabel = "Send " + BWText["name"].lowercased()
                    if form.isEditing {
                        BWFormField(nameLabel, isRequired: true, isFocused: focus == "name",
                                    error: form.showsErrors && form.isNameMissing ? BWText["inputRequired"] : nil) {
                            BWTextInput(text: $form.name).focused($focus, equals: "name")
                        }
                    } else {
                        readOnly(nameLabel, form.name)
                    }
                    switch form.type {
                    case .text: textDetails
                    case .file: fileDetails
                    }
                    deletionDate
                    access
                }
            }
        }
    }

    private func readOnly(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        BWReadOnlyField(label) { BWFieldValue(value) }
            .padding(.bottom, isLast ? 0 : Metric.space(4))
    }

    /// send-text-details: the text, and the box that hides it from the one who opens the link.
    @ViewBuilder
    private var textDetails: some View {
        if form.isEditing {
            BWFormField(BWText["sendTypeTextToShare"], isRequired: true, isFocused: focus == "text",
                        error: form.showsErrors && form.isContentMissing ? BWText["inputRequired"] : nil, isTextArea: true) {
                BWTextArea(text: $form.text, rows: 3).focused($focus, equals: "text")
            }
        } else {
            BWReadOnlyField(BWText["sendTypeTextToShare"], isTextArea: true) { BWFieldText(form.text, rows: 3) }
                .padding(.bottom, Metric.space(4))
        }
        // showHiddenCheckbox: while the form is one, and in the view of a Send that hides its text.
        if form.isEditing || form.hidesText {
            BWCheckbox(BWText["hideTextByDefault"], isOn: $form.hidesText)
                .disabled(!form.isEditing)
                .padding(.bottom, Metric.space(4))
        }
    }

    /// send-file-details: the file of a Send the vault has is named only; a new Send takes one.
    @ViewBuilder
    private var fileDetails: some View {
        if let send = form.original {
            VStack(alignment: .leading, spacing: 0) {
                Text(BWText["file"])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
                Text(send.fileName ?? "")
                    .textStyle(.body)
                    .foregroundStyle(.theme(.textMain))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(send.fileSizeName ?? "")
                    .textStyle(.body)
                    .foregroundStyle(.theme(.textMuted))
            }
            .padding(.bottom, Metric.space(4))
        } else {
            // bit-file-upload: the button that opens the file panel, then the name of the file.
            VStack(alignment: .leading, spacing: Metric.space(2)) {
                BWFieldLabel(BWText["fileToShare"], isRequired: true)
                BWFieldContainer(isFocused: false, hasError: form.showsErrors && form.isContentMissing) {
                    HStack(spacing: Metric.space(3)) {
                        BWButton(BWText["chooseFile"], isBlock: false, isSmall: true, action: chooseFile)
                        Text(form.file?.lastPathComponent ?? BWText["noFileSelected"])
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textStyle(.sm)
                            .foregroundStyle(.theme(form.file == nil ? .textMuted : .fgHeading))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Metric.space(3))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: chooseFile)
                }
                BWHint(BWText["maxFileSize"])
            }
            .padding(.bottom, Metric.space(4))
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { form.file = panel.url }
    }

    /// The select of the day of deletion: so long after the save. The form of a Send of the
    /// vault starts with the day it has.
    @ViewBuilder
    private var deletionDate: some View {
        if form.isEditing {
            var presets: [BWSelect<SendForm.Deletion>.Option] {
                var options: [BWSelect<SendForm.Deletion>.Option] = []
                if let send = form.original { options.append(.init(.current, ItemPanel.short(send.summary.deletionDate))) }
                options.append(.init(.hours(1), BWText["oneHour"]))
                options.append(.init(.hours(24), BWText["oneDay"]))
                for days in [2, 3, 7, 14, 30] { options.append(.init(.hours(days * 24), BWText["days", String(days)])) }
                return options
            }
            BWSelect(BWText["deletionDate"], selection: $form.deletion, options: presets, hint: BWText["deletionDateDescV2"])
        } else if let send = form.original {
            readOnly(BWText["deletionDate"], ItemPanel.short(send.summary.deletionDate))
        }
    }

    /// "Who can view", and the password of a Send that asks for one.
    @ViewBuilder
    private var access: some View {
        let asksForPassword = form.access == .password
        if form.isEditing {
            BWSelect(BWText["whoCanView"], selection: $form.access,
                     options: [.init(.anyone, BWText["noAuth"]), .init(.password, BWText["anyOneWithPassword"])],
                     hint: asksForPassword ? BWText["sendPasswordHelperText"] : nil,
                     bottomMargin: asksForPassword ? Metric.space(4) : 0)
        } else {
            readOnly(BWText["whoCanView"], BWText[asksForPassword ? "anyOneWithPassword" : "noAuth"], isLast: !asksForPassword)
        }
        if asksForPassword {
            if form.hasStoredPassword {
                // The password of the Send cannot be shown: stars, and the button that removes it.
                BWFormField(BWText["password"], isFocused: false, bottomMargin: 0) {
                    BWTextInput(text: .constant("************"), isSecure: true).disabled(true)
                } suffix: {
                    if form.isEditing, let id = form.original?.id {
                        BWIconButton(.minusCircle, label: BWText["removePassword"], size: .small, kind: .dangerGhost) {
                            actions.removePassword(of: id)
                        }
                    }
                }
            } else if form.isEditing {
                // A Send whose password was removed takes a "new password".
                BWFormField(BWText[form.original == nil ? "password" : "newPassword"], isRequired: true, isFocused: focus == "password",
                            error: form.showsErrors && form.isPasswordMissing ? BWText["inputRequired"] : nil, bottomMargin: 0) {
                    BWTextInput(text: $form.password, isSecure: !form.revealsPassword, isMonospaced: true)
                        .focused($focus, equals: "password")
                } suffix: {
                    BWIconButton(form.revealsPassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        form.revealsPassword.toggle()
                    }
                    BWIconButton(.generate, label: BWText["generatePassword"], size: .small) {
                        navigation.generator = GeneratorSession(purpose: .sendPassword(form), options: model.state.settings.generator)
                    }
                    BWIconButton(.clone, label: BWText["copyPassword"], size: .small) { copyPassword() }
                        .disabled(form.password.isEmpty)
                }
            }
        }
    }

    private func copyPassword() {
        let password = form.password
        Task {
            guard (try? await model.copy(text: password, isSensitive: true)) != nil else { return }
            navigation.copied(BWText["valueCopied", BWText["password"]])
        }
    }

    // MARK: Additional options

    /// send-options.component.html. The view shows a field only when it has a value.
    @ViewBuilder
    private var options: some View {
        let showsCount = form.isEditing || !form.maxAccessCount.isEmpty
        let showsHideEmail = form.isEditing || form.hidesEmail
        let showsNote = form.isEditing || !form.notes.isEmpty
        if showsCount || showsHideEmail || showsNote {
            VStack(alignment: .leading, spacing: 0) {
                BWSectionHeader(BWText["additionalOptions"])
                    .padding(.top, Metric.space(4))
                BWCard {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsCount { maxAccessCount(isLast: !showsHideEmail && !showsNote) }
                        if showsHideEmail {
                            BWCheckbox(BWText["hideMyEmail"], isOn: $form.hidesEmail)
                                .disabled(!form.isEditing)
                                .padding(.bottom, showsNote ? Metric.space(4) : 0)
                        }
                        if showsNote {
                            if form.isEditing {
                                BWFormField(BWText["privateNote"], isFocused: focus == "notes", bottomMargin: 0, isTextArea: true) {
                                    BWTextArea(text: $form.notes, rows: 3).focused($focus, equals: "notes")
                                }
                            } else {
                                BWReadOnlyField(BWText["privateNote"], isTextArea: true) { BWFieldText(form.notes, rows: 3) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The number of times the link opens, with what is left of it for a Send that counts.
    @ViewBuilder
    private func maxAccessCount(isLast: Bool) -> some View {
        let margin = isLast ? 0 : Metric.space(4)
        // showAccessCount: "$N$ views left" for a Send that has a limit.
        let left: String? = form.original.flatMap { send in
            send.summary.maxAccessCount.map { BWText["limitSendViewsCount", String(max($0 - send.summary.accessCount, 0))] }
        }
        if form.isEditing {
            let isInvalid = form.showsErrors && form.maxAccessCountValue == nil
            BWFormField(BWText["maxAccessCount"], isFocused: focus == "maxAccessCount",
                        error: isInvalid ? BWText["numericInputError"] : nil,
                        hint: [BWText["limitSendViewsHint"], left].compactMap { $0 }.joined(separator: " "), bottomMargin: margin) {
                BWTextInput(text: $form.maxAccessCount).focused($focus, equals: "maxAccessCount")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                BWReadOnlyField(BWText["maxAccessCount"]) { BWFieldValue(form.maxAccessCount) }
                if let left { BWHint(left) }
            }
            .padding(.bottom, margin)
        }
    }

    // MARK: Footer

    /// The footer of send-add-edit-dialog: "save" and "cancel" of a form, "edit" of a view, and
    /// for a Send of the vault the delete button at the end.
    @ViewBuilder
    private var footer: some View {
        if form.isEditing {
            BWButton(BWText["save"], kind: .primary, isBlock: false, action: save)
                .disabled(form.isSaving)
            BWButton(BWText["cancel"], isBlock: false, action: cancel)
        } else {
            BWButton(BWText["edit"], isBlock: false) { form.edit() }
        }
        Spacer(minLength: 0)
        if let id = form.original?.id {
            BWIconButton(.trash, label: BWText["delete"], kind: .dangerGhost) { actions.delete(id, isPanel: true) }
        }
    }

    private func save() {
        if form.isNameMissing { focus = "name" }
        actions.save(form)
    }

    /// `cancelEditSend`: the form of a Send of the vault goes back to its view, a new one closes.
    private func cancel() {
        navigation.leaveForm {
            if let send = form.original { form.show(send) } else { navigation.sendForm = nil }
        }
    }
}
