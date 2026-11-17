import DesignKit
import Foundation
import Observation
import VaultModel

/// What the vault window shows: the chosen filter, the search text and the open parts of the
/// side navigation. It is view state only; the items come from the engine state.
@MainActor @Observable
final class VaultNavigation {
    var filter = VaultFilter.allItems
    var search = ""
    /// Counts the requests of the menu item "search vault"; the search field takes the focus on each.
    var searchFocusRequest = 0
    /// The existing scope follows the selected filter and owner, regardless of field placement.
    var searchPlaceholderKey: String {
        switch filter {
        case .favorites: "searchFavorites"
        case .archive: "searchArchive"
        case .trash: "searchTrash"
        case .type(.login): "searchLogin"
        case .type(.card): "searchCard"
        case .type(.identity): "searchIdentity"
        case .type(.secureNote): "searchSecureNote"
        case .type(.sshKey): "searchSshKey"
        case .folder(.some): "searchFolder"
        case .collection: "searchCollection"
        case .allItems, .folder(nil):
            switch owner {
            case .all: "searchVault"
            case .user: "searchMyVault"
            case .organization: "searchOrganization"
            }
        }
    }
    /// nil until the user clicks a column title.
    var sort: VaultSort?
    var isVaultGroupOpen = true
    var isOwnerListOpen = true
    var isTypeListOpen = true
    var isSendListOpen = false
    var isFolderListOpen = false
    /// The folders of the tree whose folders under them are shown.
    var openFolderIDs: Set<String> = []
    /// The width of the side navigation and whether it is open; its handle changes both.
    var sideNavigation = SideNavigationSize() {
        didSet {
            if sideNavigation.saved != oldValue.saved { onSideNavigationWidthChosen?(sideNavigation.saved) }
        }
    }
    /// Called with the width the user chose, to remember it.
    @ObservationIgnored var onSideNavigationWidthChosen: ((CGFloat) -> Void)?
    var isSideNavigationCollapsed: Bool {
        get { !sideNavigation.isOpen }
        set { if sideNavigation.isOpen == newValue { sideNavigation.toggle() } }
    }
    /// Whose items the list shows: "all vaults", "my vault", or the vault of an organization.
    var owner = VaultOwner.all
    /// "My vault" instead of "All vaults".
    var isMyVaultSelected: Bool {
        get { owner == .user }
        set { owner = newValue ? .user : .all }
    }
    var isCollectionListOpen = false
    /// The item whose dialog "assign to collections" is open.
    var assignItemID: String?
    /// The width of the open side navigation: 18.5 rem unless the user chose another.
    var sideNavigationWidth: CGFloat {
        get { sideNavigation.width }
        set { sideNavigation.restore(newValue) }
    }

    /// The item whose panel is open. Another item starts with everything hidden again.
    var openItemID: String? {
        didSet {
            guard openItemID != oldValue else { return }
            invalidateFileWork()
            revealedFields = []
            showsPasswordCount = false
        }
    }
    /// The hidden fields of the open item that are shown in clear, by the key of the field.
    var revealedFields: Set<String> = []
    /// The revealed password of the open item is shown with the position of each character.
    var showsPasswordCount = false
    /// The panel opens at its end. Only a comparison scene sets it.
    var itemPanelStartsAtEnd = false
    /// The settings dialog opens with the list of its timeout select open. Only a scene sets it.
    var settingsStartWithOpenList = false
    /// The settings dialog opens with the dialog that sets the PIN over it. Only a scene sets it.
    var settingsStartWithPinDialog = false
    /// The settings dialog opens with the help of its first question mark. For a picture of it.
    var settingsStartWithHelp = false
    /// The menu of the accounts is open from the start. Only a comparison scene sets it.
    var accountMenuStartsOpen = false
    /// The row that is drawn as if the pointer were on its checkbox. Only a comparison scene sets it.
    var pointerOnCheckboxItemID: String?
    /// The dialog that takes a new shortcut for quick access is open, over the settings dialog.
    /// The shortcut whose dialog "type shortcut" is open.
    var editedShortcut: AppPreferences.Shortcut?
    /// The dialog is open; set to true it opens for the shortcut of quick access.
    var isEditingShortcut: Bool {
        get { editedShortcut != nil }
        set { editedShortcut = newValue ? (editedShortcut ?? .quickAccess) : nil }
    }
    /// The ticked rows of the list. The bar of bulk actions is there while one is ticked.
    var checkedItemIDs: Set<String> = []
    /// The ticked items that the dialog "add to folder" moves; nil while it is closed.
    var bulkMoveItemIDs: [String]?
    /// The row whose menu is open.
    var openMenuItemID: String?
    /// The item whose copy menu is open: the fields of an identity or of an SSH key.
    var openCopyMenuItemID: String?
    /// The menu of the button "new" is open.
    var isNewMenuOpen = false
    /// The open form of an item. It takes the place of the item panel.
    var itemForm: ItemForm? {
        didSet { if itemForm !== oldValue { invalidateFileWork() } }
    }
    /// An action on an item that asks for the master password first. The dialog is open while this is set.
    var protectedAction: ProtectedAction?
    /// A question of an action, such as "delete item". The dialog is open while this is set.
    var question: Question?
    /// The open generator; nil while it is closed.
    var generator: GeneratorSession?
    /// The dialog with the history of the generator is open, over the generator or alone.
    var showsGeneratorHistory = false
    /// The item whose earlier passwords are shown in a dialog.
    var passwordHistoryItemID: String?
    /// The item whose files are shown in the attachments dialog.
    var attachmentsItemID: String? {
        didSet { if attachmentsItemID != oldValue { invalidateFileWork() } }
    }
    /// The file chosen in the attachments dialog, which "upload" adds.
    var attachmentFile: URL?
    /// The item that could not be decrypted and whose dialog says so.
    var decryptionFailureItemID: String?
    /// The dialog of a folder: a new one, or the folder that is renamed or deleted.
    var folderDialog: FolderDialog?

    enum FolderDialog: Equatable {
        case add
        case edit(VaultFolder)
    }
    /// The open tab of the settings dialog; nil while the dialog is closed.
    var settingsTab: SettingsDialog.Tab?
    /// The notes at the top right corner of the window.
    let toasts = ToastCenter()
    /// What the app does after a value of an item was copied. The composition root sets it.
    @ObservationIgnored var afterCopy: (@MainActor () -> Void)?

    struct ProtectedAction {
        let run: @MainActor () -> Void
    }

    /// What the main area shows: the items of the vault, or the Sends.
    enum Page {
        case vault, sends
    }
    var page = Page.vault {
        didSet {
            if page == .sends, oldValue != .sends { isSendListOpen = true }
        }
    }
    /// The type of the Sends that show; nil for all of them.
    var sendFilter: SendType?
    var sendSearch = ""
    var sendSort = SendSort()
    /// The Send whose menu is open.
    var openSendMenuID: String?
    /// The menu of the button "new" of the Sends is open.
    var isNewSendMenuOpen = false
    /// The open panel of a Send: a new one, or one of the vault that is shown or changed.
    var sendForm: SendForm? {
        didSet { if sendForm !== oldValue { invalidateFileWork() } }
    }

    /// Shows the items of the vault under a filter. An open panel of a Send asks first when it
    /// has changes.
    func showVault(_ filter: VaultFilter, owner: VaultOwner? = nil) {
        guard page != .vault else {
            self.filter = filter
            if let owner { self.owner = owner }
            checkedItemIDs = []
            return
        }
        leaveForm { [self] in
            sendForm = nil
            page = .vault
            self.filter = filter
            if let owner { self.owner = owner }
            checkedItemIDs = []
        }
    }

    /// Shows the Sends of a type, or all of them. The panel of an item closes; its form asks
    /// first when it has changes.
    func showSends(_ type: SendType?) {
        guard page != .sends else {
            sendFilter = type
            return
        }
        leaveForm { [self] in
            itemForm = nil
            openItemID = nil
            checkedItemIDs = []
            page = .sends
            sendFilter = type
        }
    }

    /// The dialogs "export" and "import" of the file menu and the side navigation.
    var isExporting = false {
        didSet { if isExporting != oldValue { invalidateFileWork() } }
    }
    var isImporting = false {
        didSet { if isImporting != oldValue { invalidateFileWork() } }
    }
    @ObservationIgnored private(set) var fileWorkRevision = UUID()
    @ObservationIgnored private var fileWorkers: [UUID: () -> Void] = [:]

    /// Cancel blocking preparation when its original surface disappears or is replaced.
    private func invalidateFileWork() {
        fileWorkRevision = UUID()
        let workers = fileWorkers.values.map { $0 }
        fileWorkers.removeAll()
        for cancel in workers { cancel() }
    }

    @discardableResult
    func startFileOperation(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            defer { fileWorkers[id] = nil }
            await work()
        }
        fileWorkers[id] = { task.cancel() }
        return task
    }

    func prepareFile<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        let task = Task { try await work() }
        fileWorkers[id] = { task.cancel() }
        defer { fileWorkers[id] = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    /// What an import added, while the dialog "data successfully imported" is open.
    var importResult: VaultImport.Summary?

    /// The words of the fingerprint phrase while its dialog is open.
    var fingerprintPhrase: [String]?
    /// The window asks whether it is still seen, after its capture was turned off.
    var asksWhetherWindowIsVisible = false

    struct Question {
        let kind: BWSimpleDialog.Kind
        let title: String
        let text: String
        /// nil for "yes" and "no".
        var acceptTitle: String?
        let onAccept: @MainActor () -> Void
    }

    /// Closes what belongs to an open vault. The app calls it when the vault locks, so that no
    /// item is open and no note about one is left when it is unlocked again.
    func closeItemViews() {
        invalidateFileWork()
        openItemID = nil
        checkedItemIDs = []
        bulkMoveItemIDs = nil
        openMenuItemID = nil
        openCopyMenuItemID = nil
        isNewMenuOpen = false
        // The form holds what the user has typed, secrets too.
        itemForm = nil
        sendForm = nil
        openSendMenuID = nil
        isNewSendMenuOpen = false
        protectedAction = nil
        question = nil
        folderDialog = nil
        assignItemID = nil
        // The generator holds the value it has made.
        generator = nil
        showsGeneratorHistory = false
        passwordHistoryItemID = nil
        attachmentsItemID = nil
        attachmentFile = nil
        decryptionFailureItemID = nil
        settingsTab = nil
        isExporting = false
        isImporting = false
        importResult = nil
        fingerprintPhrase = nil
        isEditingShortcut = false
        toasts.dismissAll()
    }

    /// Runs an action that takes the place of the open form, or closes it. A form with changes
    /// asks first ("unsaved changes", as `wantsToSaveChanges` of the reference): "yes" throws
    /// the changes away and runs the action, "no" leaves the form as it is.
    func leaveForm(_ action: @escaping @MainActor () -> Void) {
        guard itemForm?.isDirty == true || sendForm?.isDirty == true else {
            action()
            return
        }
        question = Question(kind: .warning, title: BWText["unsavedChangesTitle"], text: BWText["unsavedChangesConfirmation"],
                            onAccept: action)
    }

    /// A value of an item is on the clipboard: says so and lets the app react.
    func copied(_ message: String) {
        toasts.show(.success, message: message)
        afterCopy?()
    }

    /// Runs the action now, or after the master password when one of the items asks for it
    /// (`reprompt` of vault-batch-bar.service.ts: one question for all of them).
    func perform(onAnyOf items: [VaultItemSummary], _ action: @escaping @MainActor () -> Void) {
        if items.contains(where: \.asksForMasterPassword) {
            protectedAction = ProtectedAction(run: action)
        } else {
            action()
        }
    }

    /// Runs the action now, or after the master password when the item asks for it.
    func perform(on item: VaultItemSummary, _ action: @escaping @MainActor () -> Void) {
        if item.asksForMasterPassword {
            protectedAction = ProtectedAction(run: action)
        } else {
            action()
        }
    }
}
