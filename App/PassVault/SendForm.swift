import AppKit
import DesignKit
import Engine
import Foundation
import Observation
import VaultModel

/// The open panel of a Send: what it shows and what the user has typed so far. It is view
/// state; the engine gets a draft when the user saves, and the lock throws the form away.
/// Source: libs/tools/send/send-ui/src/send-form and add-edit/send-add-edit-dialog.component.ts.
@MainActor @Observable
final class SendForm {
    /// When the Send is deleted: the day it has, or so many hours after the save
    /// (`DatePreset` of send-details.component.ts).
    enum Deletion: Hashable {
        case current
        case hours(Int)
    }

    /// Who opens the link (`AuthType` of the reference, without "specific people").
    enum Access: Hashable {
        case anyone, password
    }

    /// The Send of the vault the panel shows; nil for a new one.
    private(set) var original: VaultSend?
    let type: SendType
    /// A Send of the vault opens as a view; "edit" makes it a form. A new Send is a form at once.
    var isEditing: Bool
    var name: String
    var text: String
    var hidesText: Bool
    var file: URL?
    var deletion: Deletion
    var access: Access
    /// The password the Send gets. A Send that has one shows stars instead.
    var password = ""
    var revealsPassword = false
    var maxAccessCount: String
    var hidesEmail: Bool
    var notes: String
    var isSaving = false
    /// A save found something missing: the fields say so until they are filled.
    var showsErrors = false
    /// What the form held when it became one.
    private var start: [String] = []

    init(new type: SendType) {
        self.type = type
        isEditing = true
        name = ""
        text = ""
        hidesText = false
        deletion = .hours(168)
        access = .anyone
        maxAccessCount = ""
        hidesEmail = false
        notes = ""
        start = fingerprint
    }

    init(_ send: VaultSend) {
        original = send
        type = send.summary.type
        isEditing = false
        name = send.summary.name
        text = send.text ?? ""
        hidesText = send.hidesText
        deletion = .current
        access = send.summary.hasPassword ? .password : .anyone
        maxAccessCount = send.summary.maxAccessCount.map(String.init) ?? ""
        hidesEmail = send.hidesEmail
        notes = send.notes ?? ""
        start = fingerprint
    }

    private var fingerprint: [String] {
        [name, text, String(hidesText), file?.path ?? "", String(describing: deletion), String(describing: access), password,
         maxAccessCount, String(hidesEmail), notes]
    }

    /// The user has changed something that a close would throw away.
    var isDirty: Bool { isEditing && fingerprint != start }

    /// The Send has a password that the form cannot show.
    var hasStoredPassword: Bool { original?.summary.hasPassword == true }

    var isNameMissing: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isContentMissing: Bool {
        switch type {
        case .text: text.isEmpty
        case .file: original == nil && file == nil
        }
    }
    var isPasswordMissing: Bool { access == .password && !hasStoredPassword && password.isEmpty }
    /// nil for an empty field; a number from 1 on, else the text is not one.
    var maxAccessCountValue: Int?? {
        let text = maxAccessCount.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .some(nil) }
        guard let number = Int(text), number >= 1 else { return nil }
        return .some(number)
    }

    /// The Send of the vault as it is after a save or a change of the vault: the view shows it.
    func show(_ send: VaultSend) {
        let fresh = SendForm(send)
        original = send
        isEditing = false
        name = fresh.name
        text = fresh.text
        hidesText = fresh.hidesText
        file = nil
        deletion = .current
        access = fresh.access
        password = ""
        revealsPassword = false
        maxAccessCount = fresh.maxAccessCount
        hidesEmail = fresh.hidesEmail
        notes = fresh.notes
        showsErrors = false
        start = fingerprint
    }

    /// The view of a Send becomes its form.
    func edit() {
        isEditing = true
        start = fingerprint
    }

    /// Snapshot the fields without filesystem access. File preparation fills the payload later.
    func draft(now: Date) -> SendDraft? {
        guard !isNameMissing, !isContentMissing, !isPasswordMissing, case .some(let limit) = maxAccessCountValue else { return nil }
        let day: Date = switch deletion {
        case .current: original?.summary.deletionDate ?? now.addingTimeInterval(168 * 3_600)
        case .hours(let hours): now.addingTimeInterval(TimeInterval(hours) * 3_600)
        }
        return SendDraft(id: original?.id, type: type, name: name, notes: notes, text: type == .text ? text : "",
                         hidesText: hidesText, file: nil, deletionDate: day, maxAccessCount: limit, hidesEmail: hidesEmail,
                         newPassword: access == .password && !password.isEmpty ? password : nil)
    }
}

/// What the list and the panel of the Sends do with a Send. Source: apps/desktop/src/app/tools/send/send.component.ts
/// and send-add-edit-dialog.component.ts.
@MainActor
struct SendActions {
    let model: AppModel
    let navigation: VaultNavigation

    /// The empty form of a new Send.
    func add(_ type: SendType) {
        navigation.leaveForm { navigation.sendForm = SendForm(new: type) }
    }

    /// Opens a Send of the list: its view, as the reference opens it.
    func open(_ send: VaultSendSummary) {
        let context = VaultFileContext(model: model, navigation: navigation)
        navigation.leaveForm {
            Task {
                do {
                    let session = try await context.session()
                    let value = try await model.send(id: send.id)
                    try await context.check(session)
                    try context.checkCurrent()
                    navigation.sendForm = SendForm(value)
                } catch is CancellationError {
                } catch EngineError.invalidState, EngineError.cancelled {
                    // The vault has locked meanwhile.
                } catch {
                    navigation.toasts.show(.error, message: BWText["errorOccurred"])
                }
            }
        }
    }

    /// `copy` of send.component.ts: the link on the clipboard and the note "Send link copied".
    func copyLink(of id: String) {
        Task {
            do {
                try await model.copySendLink(of: id)
                navigation.copied(BWText["valueCopied", BWText["sendLink"]])
            } catch EngineError.invalidState, EngineError.cancelled {
                // The vault has locked meanwhile.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }

    func removePassword(of id: String) {
        navigation.question = .init(kind: .warning, title: BWText["removePassword"], text: BWText["removePasswordConfirmation"]) {
            run(done: "removedPassword") {
                try await model.removeSendPassword(of: id)
                // The open panel of that Send shows it without its password.
                if let form = navigation.sendForm, form.original?.id == id, !form.isDirty {
                    let value = try await model.send(id: id)
                    guard navigation.sendForm === form, model.state.session.isUnlocked else { return }
                    form.show(value)
                }
            }
        }
    }

    /// - Parameter isPanel: the question of the panel says "permanently".
    func delete(_ id: String, isPanel: Bool = false) {
        navigation.question = .init(kind: .warning, title: BWText["deleteSend"],
                                    text: BWText[isPanel ? "deleteSendPermanentConfirmation" : "deleteSendConfirmation"]) {
            run(done: "deletedSend") {
                try await model.deleteSend(id: id)
                if navigation.sendForm?.original?.id == id { navigation.sendForm = nil }
            }
        }
    }

    /// `submit` of the form: a new Send closes the panel, a changed one goes back to its view
    /// with the note "item saved".
    func save(_ form: SendForm) {
        guard !form.isSaving else { return }
        guard let snapshot = form.draft(now: Date()) else {
            form.showsErrors = true
            return
        }
        let source = form.original == nil && form.type == .file ? form.file : nil
        let context = VaultFileContext(model: model, navigation: navigation)
        form.isSaving = true
        navigation.startFileOperation {
            defer { form.isSaving = false }
            do {
                let session = try await context.session()
                var draft = snapshot
                if let source {
                    let data = try await context.prepare {
                        try await VaultFileIO.read(source, maximumBytes: Engine.maximumAttachmentBytes)
                    }
                    guard !data.isEmpty else { throw VaultFileIO.Failure.tooLarge }
                    draft.file = SendDraft.File(name: source.lastPathComponent, data: data)
                }
                try await context.check(session)
                let id = try await model.saveSend(draft, session: session)
                try await context.check(session)
                guard navigation.sendForm === form else { return }
                if draft.id == nil {
                    navigation.sendForm = nil
                } else {
                    let send = try await model.send(id: id)
                    try await context.check(session)
                    navigation.toasts.show(.success, message: BWText["editedItem"])
                    form.show(send)
                }
            } catch is CancellationError {
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch VaultFileIO.Failure.tooLarge, EngineError.attachmentTooLarge {
                guard (try? context.checkCurrent()) != nil else { return }
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["maxFileSize"])
            } catch EngineError.server(let message) {
                guard (try? context.checkCurrent()) != nil else { return }
                // What the server says, as the reference shows it.
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: message)
            } catch {
                guard (try? context.checkCurrent()) != nil else { return }
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText[source == nil ? "errorOccurred" : "selectFile"])
            }
        }
    }

    private func run(done key: String, _ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await change()
                navigation.toasts.show(.success, message: BWText[key])
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
                // The vault has locked meanwhile, or the engine tells the user that the session is over.
            } catch {
                navigation.toasts.show(.error, message: BWText["errorOccurred"])
            }
        }
    }
}
