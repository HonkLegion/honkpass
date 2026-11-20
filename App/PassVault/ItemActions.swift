import AppKit
import DesignKit
import Engine
import VaultModel

/// What the menu of a row and the item panel do with an item. Source: cipher-action.service.ts and
/// archive-cipher-utilities.service.ts for the menu, vault-item-dialog.component.ts for the panel.
///
/// Each action asks what the reference asks (the master password of a protected item, then the
/// question of the action), sends one change to the engine and says how it went.
@MainActor
struct ItemActions {
    let model: AppModel
    let navigation: VaultNavigation
    /// The actions of the item panel. The panel asked for the master password when it opened,
    /// so only "restore" asks again, and the panel closes after "restore" and "delete".
    var isPanel = false

    /// The form with the content of the item. The menu of a row asks for the master password of a
    /// protected item first; the panel has asked when it opened.
    func edit(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: !isPanel) { navigation.leaveForm { openForm(.edit, of: item) } }
    }

    /// The form of a new item with the content of this one and " - Clone" after its name.
    func clone(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: true) { navigation.leaveForm { openForm(.copy, of: item) } }
    }

    /// The empty form of a new item. It starts in the folder whose items the list shows. The
    /// form of an SSH key starts with a new key, as in the reference.
    func add(_ type: ItemType) {
        var folderID: String?
        if case .folder(let id) = navigation.filter { folderID = id }
        var draft = ItemDraft(new: type, folderID: folderID)
        // A form with changes asks before another one takes its place.
        navigation.leaveForm {
            guard type == .sshKey else {
                navigation.openItemID = nil
                navigation.itemForm = ItemForm(mode: .new, draft: draft)
                return
            }
            Task {
                do {
                    draft.content = .sshKey(try await model.newSSHKey())
                    navigation.openItemID = nil
                    navigation.itemForm = ItemForm(mode: .new, draft: draft)
                } catch EngineError.invalidState, EngineError.cancelled {
                    // The vault has locked meanwhile.
                } catch {
                    navigation.toasts.show(.error, message: BWText["errorOccurred"])
                }
            }
        }
    }

    /// The dialog "assign to collections" of an item. The menu of a row asks for the master
    /// password of a protected item first.
    func assignToCollections(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: !isPanel) { navigation.assignItemID = item.id }
    }

    /// Gives the item to the organization, or sets its collections there, and says which.
    func assign(_ item: VaultItemSummary, to organization: VaultOrganization, collectionIDs: [String]) {
        Task {
            do {
                try await model.assign(itemID: item.id, toOrganization: organization.id, collectionIDs: collectionIDs)
                navigation.assignItemID = nil
                navigation.toasts.show(.success, message: item.organizationID == nil ? BWText["itemMovedToOrg", organization.name]
                    : BWText["successfullyAssignedCollections"])
            } catch EngineError.cancelled, EngineError.sessionExpired {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch EngineError.itemNotWritable {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["decryptionError"])
            } catch EngineError.server(let message) {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: message)
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    // MARK: Several items

    /// "Add to folder" of the bar of bulk actions: the dialog that chooses the folder.
    func bulkMoveToFolder(_ items: [VaultItemSummary]) {
        guard !items.isEmpty else { return }
        navigation.bulkMoveItemIDs = items.map(\.id)
    }

    /// `bulkArchive` of vault-batch-bar.service.ts: one question for all, with their number.
    func bulkArchive(_ items: [VaultItemSummary]) {
        let single = items.count == 1
        navigation.perform(onAnyOf: items) {
            navigation.question = .init(
                kind: .info, title: BWText[single ? "archiveItemTitle" : "archiveItemsPlural", String(items.count)],
                text: BWText[single ? "archiveItemDialogContent" : "archiveItemsPluralDescription"],
                acceptTitle: BWText["archiveVerb"]) {
                    sendBulk(.archive, of: items, done: single ? "itemArchiveToast" : "bulkArchiveItems")
                }
        }
    }

    func bulkUnarchive(_ items: [VaultItemSummary]) {
        navigation.perform(onAnyOf: items) {
            sendBulk(.unarchive, of: items, done: items.count == 1 ? "itemUnarchivedToast" : "bulkUnarchiveItems")
        }
    }

    func bulkRestore(_ items: [VaultItemSummary]) {
        let single = items.count == 1
        // "archived items restored" only when every one of them goes back to the archive.
        let key = items.allSatisfy(\.isArchived) ? (single ? "archivedItemRestored" : "archivedItemsRestored")
            : (single ? "restoredItem" : "restoredItems")
        navigation.perform(onAnyOf: items) { sendBulk(.restore, of: items, done: key) }
    }

    /// bulk-delete-dialog-desktop.adapter.ts: a question of the kind "danger" with the number of
    /// the items; in the trash they are deleted for ever.
    func bulkDelete(_ items: [VaultItemSummary]) {
        let single = items.count == 1
        let permanent = items.allSatisfy(\.isInTrash)
        let title = single ? BWText[permanent ? "deleteItemPermanently" : "deleteItem"]
            : BWText[permanent ? "deleteItemsPermanentlyCount" : "deleteItemsCount", String(items.count)]
        let text = BWText[permanent ? (single ? "deleteItemPermanentlyDesc" : "deleteItemsPermanentlyDesc")
            : (single ? "deleteItemDesc" : "deleteItemsDesc")]
        let done = permanent ? (single ? "permanentlyDeletedItem" : "permanentlyDeletedItems") : (single ? "deletedItem" : "deletedItems")
        navigation.perform(onAnyOf: items) {
            navigation.question = .init(kind: .danger, title: title, text: text, acceptTitle: BWText["delete"]) {
                sendBulk(permanent ? .deletePermanently : .moveToTrash, of: items, done: done)
            }
        }
    }

    /// Sends one change of several items and unticks them after it, as the reference.
    func sendBulk(_ change: ItemChange, of items: [VaultItemSummary], done key: String) {
        Task {
            do {
                try await model.change(change, ofItems: items.map(\.id))
                navigation.toasts.show(.success, message: BWText[key])
                navigation.checkedItemIDs = []
                navigation.bulkMoveItemIDs = nil
            } catch EngineError.cancelled, EngineError.sessionExpired {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    // MARK: SSH key

    /// `importSshKeyFromClipboard` of default-ssh-import-prompt.service.ts: the private key on the
    /// clipboard becomes the key of the form. An encrypted key opens the dialog that asks for its
    /// password, and a wrong password leaves it open.
    func importSSHKey(into form: ItemForm, password: String? = nil) {
        Task {
            do {
                let key = try await model.importSSHKeyFromClipboard(password: password)
                form.draft.content = .sshKey(key)
                form.asksForSSHKeyPassword = false
                navigation.toasts.show(.success, message: BWText["sshKeyImported"])
            } catch EngineError.sshKeyImport(.passwordRequired) {
                form.asksForSSHKeyPassword = true
            } catch EngineError.sshKeyImport(.wrongPassword) {
                form.asksForSSHKeyPassword = true
                navigation.toasts.show(.error, message: BWText["sshKeyWrongPassword"])
            } catch EngineError.sshKeyImport(.unsupportedKind) {
                form.asksForSSHKeyPassword = false
                navigation.toasts.show(.error, message: BWText["sshKeyTypeUnsupported"])
            } catch EngineError.sshKeyImport {
                form.asksForSSHKeyPassword = false
                navigation.toasts.show(.error, message: BWText["invalidSshKey"])
            } catch EngineError.invalidState, EngineError.cancelled {
                // The vault has locked meanwhile.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    // MARK: Apps of a login

    /// Adds an app of the disk to the login of a form: the engine reads who signed it and gives
    /// its address. An app that cannot be tied to a login, as one that no developer signed or
    /// a browser, is not added. Bitwarden has no words for that, so the toast is its general one.
    func addApp(at location: URL, to form: ItemForm) {
        addApp(to: form) { try await model.appAddress(ofAppAt: location) }
    }

    func addApp(runningID: UUID, to form: ItemForm) {
        addApp(to: form) { try await model.appAddress(ofRunningApp: runningID) }
    }

    private func addApp(to form: ItemForm, resolve: @escaping @MainActor () async throws -> AppAddress) {
        guard navigation.itemForm === form, !form.isReadingApp else { return }
        let context = VaultFileContext(model: model, navigation: navigation)
        let pickerRevision = form.appPickerRevision
        form.isReadingApp = true
        navigation.startFileOperation {
            defer { form.isReadingApp = false }
            do {
                let session = try await context.session()
                let app = try await resolve()
                try await context.check(session)
                guard navigation.itemForm === form, form.appPickerRevision == pickerRevision else { return }
                form.addApp(app)
                form.isAppPickerOpen = false
            } catch is CancellationError {
            } catch EngineError.invalidState, EngineError.cancelled {
                // The vault has locked meanwhile.
            } catch {
                guard (try? context.checkCurrent()) != nil, navigation.itemForm === form,
                      form.appPickerRevision == pickerRevision else { return }
                navigation.toasts.show(.error, message: BWText["honkpassAppNotAccepted"])
            }
        }
    }

    // MARK: Attachments

    /// The attachments dialog of an item. The menu of a row asks for the master password of a
    /// protected item first.
    func showAttachments(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: !isPanel) { navigation.attachmentsItemID = item.id }
    }

    /// Fetches a file and lets the user choose where it goes, in the save panel of the system.
    func download(_ attachment: ItemAttachment, ofItem itemID: String) {
        let context = VaultFileContext(model: model, navigation: navigation)
        navigation.startFileOperation {
            do {
                let session = try await context.session()
                let file = try await model.attachment(attachment.id, of: itemID)
                try await context.check(session)
                guard let url = try await VaultFileSavePanel.destination(named: file.fileName) else { return }
                try await context.check(session)
                try await context.prepare { try await VaultFileIO.write(file.data, to: url) }
                try await context.check(session)
                navigation.toasts.show(.success, message: BWText["fileSavedToDevice"])
            } catch is CancellationError {
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            } catch {
                guard (try? context.checkCurrent()) != nil else { return }
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    /// The decrypted file, or nil with a toast that says so.
    func fetch(_ attachment: ItemAttachment, ofItem itemID: String) async -> AttachmentFile? {
        do {
            return try await model.attachment(attachment.id, of: itemID)
        } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            return nil
        } catch {
            navigation.toasts.show(.error, message: BWText["errorOccurred"])
            return nil
        }
    }

    /// Adds the chosen file to the item. The toasts are the ones of cipher-attachments.component.ts.
    /// Returns whether the file is on the server.
    func upload(_ file: URL?, toItem itemID: String) async -> Bool {
        do {
            return try await navigation.prepareFile { await uploadPreparedFile(file, toItem: itemID) }
        } catch {
            return false
        }
    }

    private func uploadPreparedFile(_ file: URL?, toItem itemID: String) async -> Bool {
        guard let file else {
            navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["selectFile"])
            return false
        }
        let context = VaultFileContext(model: model, navigation: navigation)
        do {
            let session = try await context.session()
            let data = try await context.prepare {
                try await VaultFileIO.read(file, maximumBytes: Engine.maximumAttachmentBytes)
            }
            try await context.check(session)
            try await model.addAttachment(to: itemID, fileName: file.lastPathComponent, data: data, session: session)
            try await context.check(session)
            navigation.toasts.show(.success, message: BWText["attachmentSaved"])
            return true
        } catch is CancellationError {
        } catch VaultFileIO.Failure.tooLarge, EngineError.attachmentTooLarge {
            guard (try? context.checkCurrent()) != nil else { return false }
            navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["maxFileSize"])
        } catch EngineError.itemNotWritable {
            guard (try? context.checkCurrent()) != nil else { return false }
            navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["decryptionError"])
        } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            // The vault has locked meanwhile, or the engine tells the user that the session is over.
        } catch {
            guard (try? context.checkCurrent()) != nil else { return false }
            navigation.toasts.show(.error, message: BWText["errorOccurred"])
        }
        return false
    }

    /// delete-attachment.component.ts: asks first, then the toast "attachment deleted".
    /// `fixOldAttachment` of cipher-attachments.component.ts.
    func repairAttachment(_ attachment: ItemAttachment, ofItem itemID: String) async {
        do {
            try await model.repairAttachment(attachment.id, of: itemID)
            navigation.toasts.show(.success, message: BWText["attachmentUpdated"])
        } catch EngineError.cancelled, EngineError.sessionExpired {
        } catch {
            navigation.toasts.show(.error, message: BWText["errorOccurred"])
        }
    }

    func deleteAttachment(_ attachment: ItemAttachment, ofItem itemID: String) {
        navigation.question = .init(kind: .warning, title: BWText["deleteAttachment"],
                                    text: BWText["permanentlyDeleteAttachmentConfirmation"]) {
            Task {
                do {
                    try await model.deleteAttachment(attachment.id, of: itemID)
                    navigation.toasts.show(.success, message: BWText["deletedAttachment"])
                } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
                } catch {
                    navigation.toasts.show(.error, message: BWText["errorOccurred"])
                }
            }
        }
    }

    /// `checkPassword` of login-details-section: asks the leaked password service and says what it
    /// knows. A check that fails says so; it never reads as "not leaked".
    func checkPassword(_ password: String) {
        guard !password.isEmpty else { return }
        Task {
            do {
                let count = try await model.timesLeaked(password: password)
                if count > 0 {
                    navigation.toasts.show(.warning, message: BWText["passwordExposed", String(count)])
                } else {
                    navigation.toasts.show(.success, message: BWText["passwordSafe"])
                }
            } catch EngineError.invalidState {
                // The vault has locked meanwhile.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    /// Saves the form. An item needs a name; the form says so and nothing is sent. The saved
    /// item then shows in its view, as in the reference.
    func save(_ form: ItemForm) {
        guard !form.isSaving else { return }
        guard !form.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            form.showsNameError = true
            return
        }
        form.isSaving = true
        Task {
            defer { form.isSaving = false }
            do {
                let id = try await model.save(form.draft)
                navigation.toasts.show(.success, message: BWText[form.mode == .edit ? "editedItem" : "addedItem"])
                if navigation.itemForm === form {
                    navigation.itemForm = nil
                    navigation.openItemID = id
                }
            } catch EngineError.cancelled, EngineError.sessionExpired {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch EngineError.itemChanged {
                // The message of the server, which the reference shows as it comes.
                navigation.toasts.show(.error, title: BWText["errorOccurred"],
                                       message: "The client copy of this cipher is out of date. Resync the client and try again.")
            } catch EngineError.itemNotWritable {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["decryptionError"])
            } catch EngineError.invalidState where form.draft.id == nil && form.draft.organizationID != nil {
                // An item of an organization needs a collection.
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["nothingSelected"])
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    private func openForm(_ mode: ItemForm.Mode, of item: VaultItemSummary) {
        let context = VaultFileContext(model: model, navigation: navigation)
        Task {
            do {
                let session = try await context.session()
                var draft = try await model.draft(of: item.id)
                try await context.check(session)
                try context.checkCurrent()
                if mode == .copy { draft = draft.copy(named: draft.name + " - " + BWText["clone"]) }
                navigation.openItemID = mode == .edit ? item.id : nil
                navigation.itemForm = ItemForm(mode: mode, draft: draft)
            } catch is CancellationError {
            } catch EngineError.cancelled {
            } catch EngineError.itemNotWritable {
                guard (try? context.checkCurrent()) != nil else { return }
                // A part of the item did not decrypt, so PassVault does not write it back. The
                // dialog names the item, as when it is opened.
                navigation.decryptionFailureItemID = item.id
            } catch EngineError.invalidState {
                // The vault has locked meanwhile.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    /// The reference does not ask for the master password here.
    func toggleFavorite(_ item: VaultItemSummary) {
        send(.favorite(!item.isFavorite), of: item, done: item.isFavorite ? "itemRemovedFromFavorites" : "itemAddedToFavorites")
    }

    func archive(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: !isPanel) {
            navigation.question = .init(kind: .info, title: BWText["archiveItem"], text: BWText["archiveItemDialogContent"],
                                        acceptTitle: BWText["archiveVerb"]) {
                send(.archive, of: item, done: "itemArchiveToast")
            }
        }
    }

    func unarchive(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: !isPanel) {
            send(.unarchive, of: item, done: "itemUnarchivedToast")
        }
    }

    func restore(_ item: VaultItemSummary) {
        afterMasterPassword(of: item, asks: true) {
            send(.restore, of: item, done: item.isArchived ? "archivedItemRestored" : "restoredItem", closesPanel: isPanel)
        }
    }

    /// To the trash, or for ever when the item is in the trash already. The question of the
    /// panel has the title "delete item" for both, and its toast the title "success".
    func delete(_ item: VaultItemSummary) {
        let isInTrash = item.isInTrash
        afterMasterPassword(of: item, asks: !isPanel) {
            navigation.question = .init(
                kind: .warning, title: BWText[isInTrash && !isPanel ? "permanentlyDeleteItem" : "deleteItem"],
                text: BWText[isInTrash ? "permanentlyDeleteItemConfirmation" : "deleteItemConfirmation"]) {
                    send(isInTrash ? .deletePermanently : .moveToTrash, of: item,
                         done: isInTrash ? "permanentlyDeletedItem" : "deletedItem",
                         title: isPanel ? BWText["success"] : nil, closesPanel: isPanel)
                }
        }
    }

    private func afterMasterPassword(of item: VaultItemSummary, asks: Bool, _ action: @escaping @MainActor () -> Void) {
        if asks {
            navigation.perform(on: item, action)
        } else {
            action()
        }
    }

    private func send(_ change: ItemChange, of item: VaultItemSummary, done key: String, title: String? = nil,
                      closesPanel: Bool = false) {
        Task {
            do {
                try await model.change(change, of: item.id)
                navigation.toasts.show(.success, title: title, message: BWText[key])
                if closesPanel, navigation.openItemID == item.id {
                    navigation.openItemID = nil
                    navigation.itemForm = nil
                }
            } catch EngineError.cancelled, EngineError.sessionExpired {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch {
                // The reference says this for the archive only and is silent for the other changes.
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }
}
