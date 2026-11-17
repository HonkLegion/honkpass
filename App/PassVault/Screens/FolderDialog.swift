import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The dialog that adds a folder, or renames or deletes one.
/// Source: libs/vault/src/components/add-edit-folder-dialog. No reference picture yet.
struct FolderDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let dialog: VaultNavigation.FolderDialog
    @State private var name: String
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    init(model: AppModel, navigation: VaultNavigation, dialog: VaultNavigation.FolderDialog) {
        self.model = model
        self.navigation = navigation
        self.dialog = dialog
        var name = ""
        if case .edit(let folder) = dialog { name = folder.name }
        _name = State(initialValue: name)
    }

    private var actions: FolderActions { FolderActions(model: model, navigation: navigation) }

    var body: some View {
        BWDialog(title: BWText[dialog == .add ? "addFolder" : "editFolder"], onClose: close) {
            // bit-form-field disableMargin with a required input and a hint
            BWFormField(BWText["folderName"], isRequired: true, isFocused: isNameFocused, hint: BWText["folderHintText"],
                        bottomMargin: 0) {
                BWTextInput(text: $name)
                    .focused($isNameFocused)
                    .onSubmit(save)
            }
        } footer: {
            // `disableSubmit`: no save while the name is missing.
            BWButton(BWText["save"], kind: .primary, isBlock: false, action: save)
                .disabled(name.isEmpty || isSaving)
            BWButton(BWText["cancel"], isBlock: false, action: close)
            if case .edit(let folder) = dialog {
                Spacer(minLength: 0)
                BWIconButton(.trash, label: BWText["deleteFolder"], kind: .dangerGhost) { actions.delete(folder) }
            }
        }
        .onAppear { isNameFocused = true }
        .onExitCommand(perform: close)
    }

    private func save() {
        guard !name.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            var id: String?
            if case .edit(let folder) = dialog { id = folder.id }
            await actions.save(id: id, name: name)
        }
    }

    private func close() {
        navigation.folderDialog = nil
    }
}

/// What the folder dialog does. Each action sends one change to the engine and says how it went,
/// with the toasts of the reference.
@MainActor
struct FolderActions {
    let model: AppModel
    let navigation: VaultNavigation

    /// Adds a folder (`id` nil) or renames one, and closes the dialog after it.
    func save(id: String?, name: String) async {
        do {
            try await model.saveFolder(id: id, name: name)
            navigation.toasts.show(.success, message: BWText[id == nil ? "addedFolder" : "editedFolder"])
            navigation.folderDialog = nil
        } catch EngineError.cancelled, EngineError.sessionExpired {
            // The vault has locked meanwhile, or the engine tells the user that the session is over.
        } catch {
            navigation.toasts.show(.error, message: BWText["errorOccurred"])
        }
    }

    /// Asks first. The reference names a text for the question that its locale files do not have;
    /// "are you sure you want to delete this folder?" is the one they have.
    func delete(_ folder: VaultFolder) {
        navigation.question = .init(kind: .warning, title: BWText["deleteFolder"], text: BWText["deleteFolderConfirmation"]) {
            Task {
                do {
                    try await model.deleteFolder(id: folder.id)
                    navigation.toasts.show(.success, message: BWText["deletedFolder"])
                    navigation.folderDialog = nil
                    // The list of a folder that is gone shows all items again.
                    if navigation.filter == .folder(folder.id) { navigation.filter = .allItems }
                } catch EngineError.cancelled, EngineError.sessionExpired {
                } catch {
                    navigation.toasts.show(.error, message: BWText["errorOccurred"])
                }
            }
        }
    }
}

/// The dialog of an item that could not be decrypted: it names the item by its identifier.
/// Source: libs/vault/src/components/decryption-failure-dialog. No reference picture yet.
struct DecryptionFailureDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemID: String

    /// The first sentence of the text of the reference. Its second one sends the user to the
    /// customer support of Bitwarden, which PassVault does not have (PLAN.md, allowed deviations).
    private var description: String {
        let text = BWText["couldNotDecryptVaultItem"]
        return text.firstIndex(of: ".").map { String(text[...$0]) } ?? text
    }

    var body: some View {
        BWDialog(title: BWText["decryptionError"], titleIcon: .error, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                // p, with the 10 pixels the desktop styles give every paragraph
                Text(description)
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                // span "tw-block tw-mb-4 tw-font-bold"
                Text(BWText["itemId"])
                    .textStyle(.body.weight(700))
                    .padding(.bottom, Metric.space(4))
                // "tw-rounded-xl tw-border tw-border-solid tw-border-border-strong tw-bg-bg-secondary tw-px-3 tw-py-2",
                // the identifier "tw-whitespace-nowrap tw-font-mono tw-text-sm tw-leading-6"
                Text(itemID)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .textStyle(TextStyle(size: TextStyle.sm.size, lineHeight: Metric.space(6), isMonospaced: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metric.space(3))
                    .padding(.vertical, Metric.space(2))
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).fill(.theme(.bgSecondary)))
                    .overlay(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).strokeBorder(.theme(.borderStrong), lineWidth: 1))
            }
        } footer: {
            BWButton(BWText["copyId"], kind: .primary, startIcon: .clone, isBlock: false) {
                Task {
                    guard (try? await model.copy(text: itemID, isSensitive: false)) != nil else { return }
                    navigation.toasts.show(.success, message: BWText["valueCopied", BWText["itemId"]])
                }
            }
            BWButton(BWText["close"], isBlock: false, action: close)
        }
        .onExitCommand(perform: close)
    }

    private func close() {
        navigation.decryptionFailureItemID = nil
    }
}

/// "Add to folder" for the ticked items: the folder they go to.
/// Source: libs/vault/src/components/bulk-action-dialogs/bulk-move-dialog. No reference picture yet.
struct BulkMoveDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemIDs: [String]
    @State private var folderID: String?

    var body: some View {
        BWDialog(title: BWText["addToFolder"], size: .small, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                // p, with the 10 pixels the desktop styles give every paragraph
                Text(BWText["moveSelectedItemsDesc", String(itemIDs.count)])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                BWSelect(BWText["selectFolder"], selection: $folderID, options: folders)
            }
        } footer: {
            BWButton(BWText["save"], kind: .primary, isBlock: false) {
                let items = model.state.vault.items.filter { itemIDs.contains($0.id) }
                ItemActions(model: model, navigation: navigation).sendBulk(.moveToFolder(folderID), of: items, done: "movedItems")
            }
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onExitCommand(perform: close)
    }

    /// The folders by name, then "no folder", as in the form of an item.
    private var folders: [BWSelect<String?>.Option] {
        let sorted = model.state.vault.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sorted.map { .init($0.id, $0.name) } + [.init(nil, BWText["noneFolder"])]
    }

    private func close() {
        navigation.bulkMoveItemIDs = nil
    }
}
