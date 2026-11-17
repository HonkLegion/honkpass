import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The files of an item: download, delete and add. Source: libs/vault/src/cipher-view/attachments/
/// attachments-v2.component.html (the dialog) and cipher-form/components/attachments (its content).
/// No reference picture yet: no item of the test account has a file.
struct AttachmentsDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemID: String
    @State private var attachments: [ItemAttachment] = []
    @State private var isUploading = false
    /// The file of the old kind that is being given a key of its own.
    @State private var repairing: String?

    private var actions: ItemActions { ItemActions(model: model, navigation: navigation, isPanel: true) }

    var body: some View {
        BWDialog(title: BWText["addAttachment"], hasAltGround: true, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(attachments) { attachment in
                    AttachmentRow(attachment: attachment) {
                        if attachment.hasOwnKey {
                            BWIconButton(.download, label: BWText["downloadAttachmentName", attachment.fileName]) {
                                actions.download(attachment, ofItem: itemID)
                            }
                        } else {
                            // A file of the old kind is given a key of its own before it is downloaded.
                            BWButton(BWText["fixEncryption"], kind: .primary, isBlock: false, isSmall: true) {
                                repair(attachment)
                            }
                            .disabled(repairing != nil)
                        }
                        BWIconButton(.trash, label: BWText["deleteAttachmentName", attachment.fileName], kind: .dangerGhost) {
                            actions.deleteAttachment(attachment, ofItem: itemID)
                        }
                    }
                }
                // bit-card around bit-file-upload: the button that opens the file panel, then the name of the file.
                BWCard {
                    VStack(alignment: .leading, spacing: Metric.space(2)) {
                        BWFieldLabel(BWText["addAttachment"])
                        BWFieldContainer(isFocused: false) {
                            HStack(spacing: Metric.space(3)) {
                                BWButton(BWText["chooseFile"], isBlock: false, isSmall: true, action: chooseFile)
                                Text(navigation.attachmentFile?.lastPathComponent ?? BWText["noFileSelected"])
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textStyle(.sm)
                                    .foregroundStyle(.theme(navigation.attachmentFile == nil ? .textMuted : .fgHeading))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, Metric.space(3))
                            .contentShape(Rectangle())
                            .onTapGesture(perform: chooseFile)
                        }
                        if let upload = model.state.upload, upload.itemID == itemID {
                            // `uploadProgress() !== null`: no hint, and under the file the bar,
                            // "tw-block tw-mt-2".
                            BWProgressBar(value: upload.percent)
                        } else {
                            BWHint(BWText["maxFileSizeSansPunctuation"])
                        }
                    }
                }
            }
        } footer: {
            BWButton(BWText["upload"], kind: .primary, isBlock: false, action: upload)
                .disabled(isUploading || model.state.upload != nil)
        }
        .onExitCommand(perform: close)
        // A sync, an upload and a deletion change the list.
        .task(id: model.state.vault.lastSync) {
            attachments = (try? await model.item(id: itemID).attachments) ?? []
        }
    }

    /// The system panel for one file.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { navigation.attachmentFile = panel.url }
    }

    private func repair(_ attachment: ItemAttachment) {
        guard repairing == nil else { return }
        repairing = attachment.id
        Task {
            await actions.repairAttachment(attachment, ofItem: itemID)
            repairing = nil
        }
    }

    private func upload() {
        guard !isUploading else { return }
        isUploading = true
        Task {
            defer { isUploading = false }
            // The dialog closes after an upload, as in the reference.
            if await actions.upload(navigation.attachmentFile, toItem: itemID) { close() }
        }
    }

    private func close() {
        navigation.attachmentsItemID = nil
        navigation.attachmentFile = nil
    }
}

/// bit-item of a file: its name, its size under it, and the buttons at the end.
struct AttachmentRow<Buttons: View>: View {
    let attachment: ItemAttachment
    @ViewBuilder let buttons: Buttons

    var body: some View {
        let radius = Metric.containerCornerRadius
        HStack(alignment: .center, spacing: 0) {
            // bit-item-content: "tw-ps-3 tw-py-2"; the name is body2, the size is "helper" in the muted colour.
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMain))
                Text(attachment.sizeName)
                    .textStyle(.xs)
                    .foregroundStyle(.theme(.textMuted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Metric.space(3))
            .padding(.vertical, Metric.space(2))
            if !attachment.hasOwnKey {
                // i slot="default-trailing": "bwi bwi-exclamation-triangle bwi-sm tw-text-muted"
                IconView(.exclamationTriangle, size: TextStyle.sm.size)
                    .foregroundStyle(.theme(.textMuted))
                    .help(BWText["fixEncryptionTooltip"])
                    .accessibilityLabel(BWText["fixEncryptionTooltip"])
                    .padding(.horizontal, Metric.space(2))
            }
            buttons
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderBase), lineWidth: 1))
        .padding(.bottom, Metric.space(1.5))
    }
}
