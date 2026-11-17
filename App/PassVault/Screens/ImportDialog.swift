import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// "Import": apps/desktop/src/app/tools/import/import-desktop.component.html around
/// libs/importer/src/components/import.component.html. The destination, a vault and a folder
/// of it; the data, the format of the file, the file or its pasted contents.
///
/// PassVault reads the two exports of Bitwarden that are not encrypted; the reference reads
/// some sixty formats (PLAN.md, "Differences from the reference").
struct ImportDialog: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation

    @State private var vault = "myVault"
    @State private var folderID: String?
    /// The select of the format starts without a value, which shows its placeholder; its
    /// first option, "-- select --", is a value like the others.
    private enum FormatChoice: Hashable {
        case untouched, none, format(VaultImportFormat)
    }

    @State private var formatChoice = FormatChoice.untouched
    private var format: VaultImportFormat? {
        if case .format(let format) = formatChoice { format } else { nil }
    }
    @State private var chosen: URL?
    @State private var pasted = ""
    @State private var isImporting = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        BWDialog(title: BWText["importNoun"], size: .large, hasAltGround: true,
                 fadingEdges: true, floatingFooter: true, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                BWSectionHeader(BWText["destination"], isLarge: true)
                BWCard {
                    VStack(alignment: .leading, spacing: 0) {
                        // The vault is no required field: the form has no validator for it.
                        BWSelect(BWText["vault"], selection: $vault, options: [.init("myVault", BWText["myVault"], icon: .user)])
                        BWSelect(BWText["folder"], selection: $folderID,
                                 options: [.init(String?.none, BWText["selectPlaceholder"], isPlaceholder: true)]
                                     + model.state.vault.folders.map { .init(Optional($0.id), $0.name) },
                                 hint: BWText["importTargetHintFolder"], bottomMargin: 0)
                    }
                }
                .padding(.bottom, Metric.space(5))
                BWSectionHeader(BWText["data"], isLarge: true)
                BWCard {
                    VStack(alignment: .leading, spacing: 0) {
                        BWSelect(BWText["fileFormat"], selection: $formatChoice, options: [
                            .init(FormatChoice.none, "-- " + BWText["select"] + " --"),
                            .init(.format(.bitwardenJSON), "Bitwarden (json)"), .init(.format(.bitwardenCSV), "Bitwarden (csv)"),
                        ], isRequired: true, placeholder: BWText["selectPlaceholder"])
                        if let format { instructions(for: format) }
                        fileChooser
                        BWFormField(BWText["orCopyPasteFileContents"], isFocused: false, bottomMargin: 0, isTextArea: true) {
                            // A textarea without `rows`: two lines.
                            BWTextArea(text: $pasted, rows: 2)
                        }
                    }
                }
                // The second bit-section has its "tw-mb-5" too, above the "tw-pb-4" of the dialog.
                .padding(.bottom, Metric.space(5))
            }
            .disabled(isImporting)
        } footer: {
            BWButton(BWText["importVerb"], kind: .primary, isBlock: false, action: submit)
                .disabled(isImporting)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onDisappear { operation?.cancel() }
    }

    /// The callout "… instructions": the two formats of Bitwarden have no text of their own,
    /// only the sentence that leads to the help of Bitwarden.
    private func instructions(for format: VaultImportFormat) -> some View {
        BWCallout(title: BWText.text("instructionsFor", [format == .bitwardenJSON ? "Bitwarden (json)" : "Bitwarden (csv)"])) {
            HStack(alignment: .firstTextBaseline, spacing: 0.25 * Metric.rem) {
                Text(BWText.text("importHelpCenterInstructions", ["Bitwarden"]))
                BWLink(BWText["importHelpCenterLinkText"], size: TextStyle.sm.size) {
                    if let help = URL(string: "https://bitwarden.com/help/export-your-data/") { NSWorkspace.shared.open(help) }
                }
            }
        }
    }

    /// bit-file-upload: the button that opens the file panel, as the prefix of the field, then
    /// the name of the file.
    private var fileChooser: some View {
        VStack(alignment: .leading, spacing: Metric.space(2)) {
            BWFieldLabel(BWText["selectImportFile"])
            BWFieldContainer(isFocused: false) {
                HStack(spacing: 0) {
                    BWButton(BWText["chooseFile"], isBlock: false, isSmall: true, action: chooseFile)
                        .padding(.horizontal, Metric.space(1))
                    // span "tw-text-sm tw-text-fg-body-subtle" in the content of the field, "tw-px-3".
                    Text(chosen?.lastPathComponent ?? BWText["noFileSelected"])
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textStyle(.sm)
                        .foregroundStyle(.theme(chosen == nil ? .fgBodySubtle : .fgHeading))
                        .padding(.horizontal, Metric.space(3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: chooseFile)
            }
        }
        .padding(.bottom, Metric.space(4))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { chosen = panel.url }
    }

    private func close() {
        operation?.cancel()
        navigation.isImporting = false
    }

    /// `submit()` of import.component.ts and the errors of import.service.ts. A file wins over
    /// what was pasted.
    private func submit() {
        guard !isImporting else { return }
        guard let format else { return fail("selectFormat") }
        let source = chosen
        let pasted = pasted
        let folder = model.state.vault.folders.first { $0.id == folderID }
        let context = VaultFileContext(model: model, navigation: navigation)
        isImporting = true
        operation = navigation.startFileOperation {
            defer { isImporting = false }
            var prepared = false
            do {
                let session = try await context.session()
                let imported = try await context.prepare {
                    try await VaultFileIO.importFile(source, pasted: pasted, format: format, folder: folder)
                }
                prepared = true
                try await context.check(session)
                try await model.importVault(imported.file, session: session)
                try await context.check(session)
                close()
                navigation.importResult = imported.summary
            } catch is CancellationError {
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            } catch VaultFileIO.Failure.empty {
                if (try? context.checkCurrent()) != nil { fail("selectFile") }
            } catch VaultImportError.encrypted {
                if (try? context.checkCurrent()) != nil { fail("importEncKeyError") }
            } catch VaultImportError.empty {
                if (try? context.checkCurrent()) != nil { fail("importNothingError") }
            } catch EngineError.server(let message) {
                guard (try? context.checkCurrent()) != nil else { return }
                let text = message.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                navigation.toasts.show(.error, title: BWText["importError"], message: text ?? BWText["unexpectedError"])
            } catch {
                guard (try? context.checkCurrent()) != nil else { return }
                if prepared {
                    navigation.toasts.show(.error, title: BWText["importError"], message: BWText["unexpectedError"])
                } else {
                    fail("importFormatError")
                }
            }
        }
    }

    private func fail(_ key: String) {
        navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText[key])
    }
}

/// "Data successfully imported" (import-success-dialog.component): how many items were
/// imported, and a table with the number of each type and of the new folders.
struct ImportSuccessDialog: View {
    let result: VaultImport.Summary
    let onClose: () -> Void

    private var rows: [(icon: BWIcon, label: String, count: Int)] {
        let types: [(BWIcon, String, ItemType)] = [
            (.globe, "typeLogin", .login), (.creditCard, "typeCard", .card), (.idCard, "typeIdentity", .identity),
            (.stickyNote, "typeSecureNote", .secureNote), (.key, "typeSshKey", .sshKey),
        ]
        return (types.map { ($0.0, BWText[$0.1], result.count(of: $0.2)) } + [(.folder, BWText["folders"], result.newFolderCount)])
            .filter { $0.2 > 0 }
    }

    var body: some View {
        BWDialog(title: BWText["importSuccess"], onClose: onClose) {
            VStack(alignment: .leading, spacing: Metric.space(4)) {
                Text(BWText.text("importSuccessNumberOfItems", ["\(result.itemCount)"]))
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // bit-table: the head "type" and "total", then a row for each number that is not zero.
                VStack(spacing: 0) {
                    HStack {
                        Text(BWText["type"])
                        Spacer()
                        Text(BWText["total"])
                    }
                    .textStyle(.sm.weight(600))
                    .foregroundStyle(.theme(.textMuted))
                    .padding(.vertical, Metric.space(2))
                    Rectangle().fill(.theme(.secondary300)).frame(height: 2)
                    ForEach(rows, id: \.label) { row in
                        HStack(spacing: Metric.space(2)) {
                            IconView(row.icon, size: TextStyle.body.size).foregroundStyle(.theme(.textMuted))
                            Text(row.label)
                            Spacer()
                            Text("\(row.count)")
                        }
                        .textStyle(.body)
                        .foregroundStyle(.theme(.textMain))
                        .padding(.vertical, Metric.space(3))
                        Rectangle().fill(.theme(.secondary300)).frame(height: 1)
                    }
                }
            }
        } footer: {
            BWButton(BWText["ok"], kind: .primary, isBlock: false, action: onClose)
        }
    }
}
