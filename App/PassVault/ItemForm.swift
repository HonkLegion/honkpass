import Foundation
import Observation
import VaultModel

/// The open form of an item: what the user has typed so far. It is view state; the engine gets the
/// draft when the user saves, and the lock throws the form away with everything in it.
@MainActor @Observable
final class ItemForm {
    enum Mode {
        /// The change of an item of the vault.
        case edit
        /// A new item.
        case new
        /// A new item that starts with the content of another one.
        case copy
    }

    let mode: Mode
    var draft: ItemDraft
    /// What the form held when it opened.
    let original: ItemDraft
    /// The user has changed something that a close would throw away.
    var isDirty: Bool { draft != original }
    var isSaving = false
    /// The name was missing at a save: the field says so until it has one.
    var showsNameError = false
    /// The hidden fields that are shown in clear, by the key of the field.
    var revealed: Set<String> = []
    /// The websites whose match detection is shown, by their position.
    var openMatchDetection: Set<Int> = []
    /// The menu of "add website or app" is open.
    var isAddWebsiteMenuOpen = false
    /// The signature of an app the user chose is being read.
    var isReadingApp = false
    var isAppPickerOpen = false {
        didSet { if isAppPickerOpen != oldValue { appPickerRevision = UUID() } }
    }
    private(set) var appPickerRevision = UUID()
    /// The dialog that adds a custom field, or renames or removes the one at this position.
    var fieldDialog: FieldDialog?
    /// The SSH key on the clipboard is encrypted: the dialog that asks for its password is open.
    var asksForSSHKeyPassword = false
    /// The help behind the question mark of the authenticator key is open.
    var showsVerificationKeyHelp = false

    enum FieldDialog: Equatable {
        case add
        case edit(Int)
    }

    /// Moves a website of the login to another place in the list. Its match detection stays open with it.
    func moveWebsite(from source: Int, to target: Int) {
        guard case .login(var login) = draft.content, login.websites.indices.contains(source),
              login.websites.indices.contains(target), source != target else { return }
        var isOpen = login.websites.indices.map(openMatchDetection.contains)
        login.websites.insert(login.websites.remove(at: source), at: target)
        isOpen.insert(isOpen.remove(at: source), at: target)
        draft.content = .login(login)
        openMatchDetection = Set(isOpen.indices.filter { isOpen[$0] })
    }

    /// The rows of the login that are websites, and the ones that are apps: positions in its
    /// `websites`, where both are kept. The form holds the apps after the websites.
    var websiteRows: [Int] {
        guard case .login(let login) = draft.content else { return [] }
        return login.websites.indices.filter { login.websites[$0].app == nil }
    }

    var appRows: [Int] {
        guard case .login(let login) = draft.content else { return [] }
        return login.websites.indices.filter { login.websites[$0].app != nil }
    }

    /// Adds an empty row for a website, after the websites and before the apps. Returns its position.
    @discardableResult
    func addWebsite() -> Int? {
        guard case .login(var login) = draft.content else { return nil }
        let position = (websiteRows.last ?? -1) + 1
        login.websites.insert(ItemDraft.Website(address: ""), at: position)
        draft.content = .login(login)
        return position
    }

    /// Adds an app to the login, after the ones it has. An app the login has already stays once.
    func addApp(_ app: AppAddress) {
        guard case .login(var login) = draft.content, !login.websites.contains(where: { $0.app == app }) else { return }
        login.websites.append(ItemDraft.Website(app: app))
        draft.content = .login(login)
    }

    func moveCustomField(from source: Int, to target: Int) {
        guard draft.customFields.indices.contains(source), draft.customFields.indices.contains(target), source != target else { return }
        draft.customFields.insert(draft.customFields.remove(at: source), at: target)
    }

    init(mode: Mode, draft: ItemDraft) {
        self.mode = mode
        var draft = draft
        // The form of a new login has one row for a website from the start; a login that is
        // there has the rows of its websites and no empty one (`initNewCipher` and
        // `initFromExistingCipher` of autofill-options.component.ts).
        // The apps of the login have a section of their own: their rows stand after the websites.
        if case .login(var login) = draft.content {
            let pages = login.websites.filter { $0.app == nil }, apps = login.websites.filter { $0.app != nil }
            login.websites = (pages.isEmpty && mode == .new ? [ItemDraft.Website(address: "")] : pages) + apps
            draft.content = .login(login)
        }
        self.draft = draft
        original = draft
    }
}
