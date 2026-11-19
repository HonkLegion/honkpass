import AppKit
import DesignKit
import Engine
import Observation
import QuartzCore
import SwiftUI
import VaultModel

enum QuickItemAction: Hashable {
    case copy(ItemField), openWindow, browser, fill, openMain

    static let loginFields: [ItemField] = [.username, .password, .verificationCode]

    static func offered(for item: VaultItemSummary) -> [Self] {
        let fields: [ItemField]
        switch item.type {
        case .login: fields = loginFields
        case .card: fields = [.cardNumber, .cardSecurityCode]
        case .identity: fields = [.identityUsername, .identityEmail, .identityPhone, .identityAddress]
        case .secureNote: fields = [.notes]
        case .sshKey: fields = item.fields.contains(.sshKey) ? [.sshKey, .sshPublicKey, .sshFingerprint] : []
        }
        var options = fields.filter { item.fields.contains($0) || item.type == .sshKey }.map(Self.copy)
        options.append(.openWindow)
        if item.type == .login, item.fields.contains(.website) { options.append(.browser) }
        if !QuickAccessState.fillFields(of: item).isEmpty { options.append(.fill) }
        options.append(.openMain)
        return options
    }

    var shortcut: String? {
        switch self {
        case .copy(.username): "⌘U"
        case .copy(.password): "⌘P"
        case .copy(.verificationCode): "⌘T"
        case .copy: nil
        case .openWindow: "⌘O"
        case .browser: "⌥↩"
        case .fill: "⇧↩"
        case .openMain: "⇧⌘O"
        }
    }

    func title(target: FillTarget?) -> String {
        switch self {
        case .copy(let field):
            let key = switch field {
            case .username, .identityUsername: "copyUsername"
            case .password: "copyPassword"
            case .verificationCode: "copyVerificationCode"
            case .cardNumber: "copyNumber"
            case .cardSecurityCode: "copySecurityCode"
            case .identityEmail: "copyEmail"
            case .identityPhone: "copyPhone"
            case .identityAddress: "copyAddress"
            case .sshKey: "copyPrivateKey"
            case .sshPublicKey: "copyPublicKey"
            case .sshFingerprint: "copyFingerprint"
            case .notes: "copyNote"
            case .website: "copyWebsite"
            }
            return BWText[key]
        case .openWindow: return BWText["honkpassQuickNewWindow"]
        case .openMain: return BWText["honkpassQuickOpenMain"]
        case .browser: return BWText["honkpassQuickOpenBrowser"]
        case .fill: return target.map { BWText["honkpassQuickFillTarget", $0.appName] } ?? BWText["fill"]
        }
    }
}

/// What the quick access window shows: the search text and the row the keyboard is on.
@MainActor @Observable
final class QuickAccessState {
    /// Hidden panels must not build or update a second vault list on unlock.
    var isPresented = false
    var hasKeyboard = false
    var search = "" {
        didSet { if search != oldValue { selectedRowID = nil; detailRowID = nil } }
    }
    /// The row the arrow keys are on (`QuickAccessSection.Row.id`). nil is the first row.
    var selectedRowID: String?
    var detailRowID: String?
    var markedAction: QuickItemAction?

    func showActions(for row: QuickAccessSection.Row) {
        selectedRowID = row.id
        detailRowID = row.id
        markedAction = QuickItemAction.offered(for: row.item).first
    }
    /// A new number puts the cursor into the search field.
    var focusRequest = 0
    /// The field that had the cursor in the app in front when the panel opened: where "fill"
    /// puts a value. nil without such a field or without the permission of the system.
    var target: FillTarget?
    /// The row whose menu of fields to fill is open.
    var fillMenuRowID: String?
    /// The fill that waits for the answer to "confirm autofill".
    var pendingFill: PendingFill?
    /// The system asks for Touch ID for the panel: its question has the keyboard meanwhile.
    var isAskingForTouchID = false

    struct PendingFill: Equatable {
        let item: VaultItemSummary
        /// The field that is filled. nil is the login: its user name and its password, into
        /// the two fields of a login form.
        let field: ItemField?
    }

    /// The answers to the question before a fill, as the dialog of the browser extension has them.
    enum FillAnswer: Equatable {
        /// Fill, and add the page in front to the websites of the login.
        case saveAndFill
        case saveAppAndFill
        case fill
        case cancel
    }

    /// The answer Return gives: the one the keyboard is on. It starts on the fill alone, so
    /// that a website is never added by a key pressed too soon.
    var markedFillAnswer = FillAnswer.fill

    /// The answers the question offers now. A website can be added to a login when the app in
    /// front tells its page.
    var fillAnswers: [FillAnswer] {
        guard let pending = pendingFill else { return [] }
        var answers: [FillAnswer] = []
        if target?.website != nil, pending.item.type == .login { answers.append(.saveAndFill) }
        if let target, target.website == nil, let app = target.app, target.bundleID == app.bundleID,
           pending.item.type == .login, !pending.item.isReadOnly, !pending.item.isUndecryptable,
           !pending.item.isInTrash, !pending.item.isArchived,
           !pending.item.websites.contains(where: { $0.app == app }) { answers.append(.saveAppAndFill) }
        return answers + [.fill, .cancel]
    }

    /// Whether "fill" of an item fills a login form: the cursor is in such a form, and the
    /// item is a login with a user name and a password.
    func fillsLoginForm(with item: VaultItemSummary) -> Bool {
        target?.takesLogin == true && item.type == .login && item.fields.isSuperset(of: [.username, .password])
    }

    /// The fields of an item that "fill" offers: the ones a form asks for.
    nonisolated static func fillFields(of item: VaultItemSummary) -> [ItemField] {
        let all: [ItemField] = switch item.type {
        case .login: [.username, .password, .verificationCode]
        case .card: [.cardNumber, .cardSecurityCode]
        case .identity: [.identityUsername, .identityEmail, .identityPhone, .identityAddress]
        case .secureNote, .sshKey: []
        }
        return all.filter(item.fields.contains)
    }

    func reset() {
        search = ""
        selectedRowID = nil
        detailRowID = nil
        markedAction = nil
        fillMenuRowID = nil
        pendingFill = nil
        focusRequest += 1
    }
}

/// The quick access window: a floating panel over whatever the user works in. It is one more
/// client of the engine; closing it changes nothing there. The panel does not activate
/// PassVault, so the app the user works in stays in front (PLAN.md, M3).
@MainActor
final class QuickAccessPanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: Metric.quickAccessWidth, height: Metric.quickAccessHeight)

    let state = QuickAccessState()
    /// What the rows of the panel need of a window of items: their open menus, the toasts and
    /// the question for the master password of an item that asks for it.
    let navigation = VaultNavigation()
    private let panel: QuickAccessPanel
    private let glass = NSGlassEffectView()
    private let glassContent = NSView()
    private var hostedContent: NSView?
    private let model: AppModel
    private let showMainWindow: @MainActor () -> Void
    private let openItem: @MainActor (String) -> Void
    private let openItemWindow: @MainActor (String) -> Void
    private var resizeTask: Task<Void, Never>?
    /// When a click elsewhere closed the panel. A click on the menu bar item may close the panel
    /// this way a moment before it asks to toggle it; it must not open it again then.
    private var closedByClickElsewhere: Date?
    /// The field of the app in front is being looked at; the panel shows right after.
    private var isOpening = false
    /// A click elsewhere closes the panel. The smoke test turns this off: it shares the screen
    /// with whatever the user does meanwhile, and a click of the user must not end its checks.
    var closesWithoutKeyboard = true

    /// - Parameters:
    ///   - showMainWindow: brings the main window forward, for the states locked and logged out.
    ///   - openItem: shows an item in the main window.
    ///   - inMainWindow: runs an action of an item in the main window and shows it: a form or
    ///     a question, which the panel has no room for.
    init(model: AppModel, showMainWindow: @escaping @MainActor () -> Void, openItem: @escaping @MainActor (String) -> Void,
         openItemWindow: @escaping @MainActor (String) -> Void,
         inMainWindow: @escaping @MainActor (@MainActor (ItemActions) -> Void) -> Void) {
        panel = QuickAccessPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.model = model
        self.showMainWindow = showMainWindow
        self.openItem = openItem
        self.openItemWindow = openItemWindow
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        let actions = QuickAccessView.Actions(
            showMainWindow: { [weak self] in
                self?.close()
                showMainWindow()
            },
            perform: { [weak self] action, row in self?.perform(action, on: row) },
            inMainWindow: { [weak self] action in
                self?.close()
                inMainWindow(action)
            },
            key: { [weak self] key in self?.press(key) ?? false },
            requestFill: { [weak self] field, item in self?.requestFill(field, of: item) },
            answerFill: { [weak self] answer in self?.answerFill(answer) },
            unlockWithTouchID: { [weak self] in self?.unlockWithTouchID() },
            resize: { [weak self] height, animated in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.state.isPresented else { return }
                    self.resize(to: height, animated: animated)
                }
            })
        let content = NSHostingView(rootView: QuickAccessView(model: model, state: state, navigation: navigation,
                                                              actions: actions))
        content.sizingOptions = []
        glass.style = .regular
        glass.cornerRadius = Metric.quickAccessCornerRadius
        glass.frame = NSRect(origin: .zero, size: Self.size)
        glassContent.frame = glass.bounds
        glassContent.autoresizingMask = [.width, .height]
        content.frame = glassContent.bounds
        content.autoresizingMask = [.width, .height]
        hostedContent = content
        glassContent.addSubview(content)
        glass.contentView = glassContent
        panel.contentView = glass
    }

    var isShown: Bool { panel.isVisible || isOpening }
    var window: NSWindow { panel }

    /// Keep the top edge stable as results shrink or an authorization question opens.
    private func resize(to height: CGFloat, animated: Bool) {
        resizeTask?.cancel()
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let height = min(height, max(0, (visible?.height ?? height) - 12))
        let start = panel.frame
        guard abs(start.height - height) > 0.5 else { return }
        var frame = start
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let visible { frame.origin.y = max(frame.minY, visible.minY + 6) }
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            fitContentToPanel()
            return
        }
        let target = frame
        resizeTask = Task { @MainActor [weak self] in
            let began = CACurrentMediaTime()
            while let self, !Task.isCancelled, self.panel.isVisible {
                let t = min(1, (CACurrentMediaTime() - began) / 0.22)
                let progress = 1 - pow(1 - t, 3)
                var next = start
                next.size.height += (target.height - start.height) * progress
                next.origin.y += (target.minY - start.minY) * progress
                self.panel.setFrame(next, display: true)
                self.fitContentToPanel()
                if t == 1 { return }
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    private func fitContentToPanel() {
        // NSHostingView's frame must follow a resize requested during a SwiftUI update.
        // Keep both material and content at the window's origin, including shrinking results.
        glass.frame = NSRect(origin: .zero, size: panel.frame.size)
        glassContent.frame = glass.bounds
        hostedContent?.frame = glassContent.bounds
    }

    #if DEBUG
    var hasFittingContent: Bool {
        glass.frame == NSRect(origin: .zero, size: panel.frame.size)
            && glassContent.frame == glass.bounds && hostedContent?.frame == glassContent.bounds
    }
    #endif

    func toggle() {
        if isShown {
            close()
        } else if let closedByClickElsewhere, Date().timeIntervalSince(closedByClickElsewhere) < 0.3 {
            self.closedByClickElsewhere = nil
        } else {
            show()
        }
    }

    /// All entry points use the same upper-center position on the screen under the pointer.
    /// Capture the target field before the panel takes the keyboard.
    func show() {
        guard !isOpening, !panel.isVisible else { return }
        isOpening = true
        Task { @MainActor in
            let target = await model.fillTarget()
            guard isOpening else { return }
            isOpening = false
            present(target: target)
        }
    }

    private func present(target: FillTarget?) {
        state.reset()
        state.target = target
        closedByClickElsewhere = nil
        let count = model.state.vault.quickAccessRows(search: "", page: target?.website, app: target?.app).count
        let size = NSSize(width: Self.size.width,
                          height: QuickAccessStyle.panelHeight(rowCount: count, isUnlocked: model.state.session.isUnlocked))
        if let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
            // Spotlight-style placement, independent of the command that opened the panel.
            let top = visible.maxY - max((visible.height - size.height) * 0.2, 0)
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                           display: false)
        }
        fitContentToPanel()
        state.isPresented = true
        panel.orderFrontRegardless()
        panel.makeKey()
        if target == nil { lookForFieldAgain() }
        askForTouchIDWhenLocked()
    }

    /// A panel that opens on a locked vault looks whether Touch ID can open it now, since a
    /// sensor comes and goes with a keyboard, and asks at once when the account has "ask for
    /// Touch ID on app start": the panel starts each time it opens, as the popup of the
    /// browser extension does.
    private func askForTouchIDWhenLocked() {
        guard case .locked = model.state.session else { return }
        Task { @MainActor in
            await model.refreshBiometrics()
            guard panel.isVisible, model.state.settings.asksForBiometricsOnStart else { return }
            unlockWithTouchID()
        }
    }

    /// Touch ID opens the vault from the panel. The question of the system takes the keyboard;
    /// the panel stays where it is and has the keyboard again afterwards, on the search field
    /// of the open vault. A question that the user closed leaves the panel as it is.
    func unlockWithTouchID() {
        guard !state.isAskingForTouchID, case .locked = model.state.session, model.state.biometrics.canUnlock else { return }
        state.isAskingForTouchID = true
        Task { @MainActor in
            do {
                try await model.unlockWithBiometrics(reason: BWText["touchIdConsentMessage"])
            } catch EngineError.biometrics(.cancelled), EngineError.cancelled, EngineError.invalidState, EngineError.busy {
                // The user closed the question, or the vault was opened another way meanwhile.
            } catch {
                navigation.toasts.show(.error, title: BWText["biometricsFailedTitle"], message: BWText["couldNotCompleteBiometrics"])
            }
            state.isAskingForTouchID = false
            guard panel.isVisible else { return }
            panel.makeKey()
            if model.state.session.isUnlocked {
                state.focusRequest += 1
                if state.target == nil { lookForFieldAgain() }
            }
        }
    }

    /// An app that nobody asked before, a browser above all, builds what it tells about its
    /// fields only when it is asked, and answers the first question too late or with no field.
    /// So the panel asks again while it is open, and "fill" appears a moment later.
    private func lookForFieldAgain() {
        Task { @MainActor in
            for pause in [150, 350, 700] {
                try? await Task.sleep(for: .milliseconds(pause))
                guard panel.isVisible, state.target == nil, model.state.session.isUnlocked else { return }
                if let target = await model.fillTarget(), panel.isVisible, state.target == nil {
                    state.target = target
                    return
                }
            }
        }
    }

    func close() {
        resizeTask?.cancel()
        isOpening = false
        state.isPresented = false
        state.hasKeyboard = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        state.reset()
        state.target = nil
        navigation.closeItemViews()
    }

    /// Fills the captured field with a field of an item, or the captured login form with the
    /// user name and the password of a login (`field` nil). The panel goes away first, so that
    /// the keyboard is with the other app again; when the value did not get there, the panel
    /// comes back and says so. Without the permission the system is asked for it.
    /// - Parameter addingPage: the page in front becomes a website of the login once it is filled.
    private func fill(_ field: ItemField?, of item: VaultItemSummary, addingPage: Bool = false, addingApp: Bool = false) {
        let target = state.target
        let anchorless = panel.frame
        close()
        Task { @MainActor in
            guard await model.isFillAllowed() else {
                await model.askForFillPermission()
                return
            }
            do {
                guard let target else { throw EngineError.fill(.noField) }
                let session = try await model.vaultSession()
                // The other app has the keyboard again before its field is written.
                try await Task.sleep(for: .milliseconds(100))
                try await model.checkVaultSession(session)
                if addingApp {
                    let saved = try await model.fillAndSaveApp(field, of: item.id, into: target)
                    if !saved {
                        try await model.checkVaultSession(session)
                        present(target: nil)
                        navigation.toasts.show(.warning, message: BWText["honkpassAppSaveFailed"])
                    }
                } else if let field {
                    try await model.fill(field, of: item.id, into: target)
                } else {
                    try await model.fillLogin(of: item.id, into: target)
                }
                if addingPage, let page = target.website {
                    // The login is filled already. A website that could not be saved is said
                    // where the user sees it next: the question comes again for this page.
                    do {
                        try await model.addWebsite(page, toLogin: item.id, session: session)
                    } catch {
                        navigation.toasts.show(.error, message: BWText["errorOccurred"])
                    }
                }
            } catch EngineError.cancelled, EngineError.sessionExpired, EngineError.invalidState {
            } catch {
                present(target: nil)
                // The search was reset. Restore the position, but keep the new list's height.
                var restored = panel.frame
                restored.origin = NSPoint(x: anchorless.minX, y: anchorless.maxY - restored.height)
                panel.setFrame(restored, display: true)
                navigation.toasts.show(.error, message: BWText["autofillError"])
            }
        }
    }

    private var rows: [QuickAccessSection.Row] {
        model.state.vault.quickAccessRows(search: state.search, page: state.target?.website, app: state.target?.app)
    }

    /// The row the keys act on: the chosen one while it is listed, else the first.
    private var selectedRow: QuickAccessSection.Row? {
        let rows = rows
        return rows.first { $0.id == state.selectedRowID } ?? rows.first
    }

    /// A menu of a row is open, or a question: they have the keyboard, and the keys of the
    /// panel wait.
    var isBusy: Bool {
        navigation.openMenuItemID != nil || navigation.openCopyMenuItemID != nil || navigation.protectedAction != nil
            || state.fillMenuRowID != nil || state.pendingFill != nil
    }

    enum Key {
        case up, down, left, right, enter, escape
    }

    /// What a key does in the panel, whichever of its views has the keyboard: the arrows go
    /// through the rows of all lists and stop at the ends; Return offers the fields of the row
    /// when there is a field to fill, and shows the item in the main window when there is none;
    /// Escape empties a search that has a text, and closes the panel when there is none.
    /// Returns false while a menu or a question has the keyboard.
    func press(_ key: Key) -> Bool {
        // The question before a fill: Return fills and Escape does not, wherever the keyboard is.
        if state.pendingFill != nil, navigation.protectedAction == nil {
            let answers = state.fillAnswers
            switch key {
            case .enter: answerFill(state.markedFillAnswer)
            case .escape: answerFill(.cancel)
            case .left, .right: return false
            case .up, .down:
                // The arrows move over the answers of the question.
                let current = answers.firstIndex(of: state.markedFillAnswer) ?? 0
                state.markedFillAnswer = answers[min(max(current + (key == .down ? 1 : -1), 0), answers.count - 1)]
            }
            return true
        }
        guard !isBusy else { return false }
        if let detailID = state.detailRowID, let row = selectedRow, row.id == detailID {
            let options = QuickItemAction.offered(for: row.item)
            let index = state.markedAction.flatMap { options.firstIndex(of: $0) } ?? 0
            switch key {
            case .escape, .left:
                state.detailRowID = nil
                state.focusRequest += 1
            case .up, .down: state.markedAction = options[min(max(index + (key == .down ? 1 : -1), 0), options.count - 1)]
            case .enter: perform(options[index], on: row)
            case .right: return false
            }
            return true
        }
        switch key {
        case .right:
            guard model.state.session.isUnlocked, state.search.isEmpty, let row = selectedRow else { return false }
            state.showActions(for: row)
        case .left: return false
        case .escape:
            // The search has the keys of the panel, whichever view has the keyboard: as in the
            // field itself (handleInputKeydown of bit-search), the first Escape is its own.
            if model.state.session.isUnlocked, !state.search.isEmpty {
                state.search = ""
                state.focusRequest += 1
            } else {
                close()
            }
        case .enter:
            guard model.state.session.isUnlocked else {
                // Return is the first button of the state: Touch ID where it can open the
                // vault, else the main window.
                if case .locked = model.state.session, model.state.biometrics.canUnlock {
                    unlockWithTouchID()
                } else {
                    close()
                    showMainWindow()
                }
                return true
            }
            guard let row = selectedRow else { return true }
            // A page without a cursor in a field takes a login and no single value.
            if state.fillsLoginForm(with: row.item)
                || (state.target?.takesValue == true && !QuickAccessState.fillFields(of: row.item).isEmpty) {
                chooseFill(row)
            } else {
                perform(.openMain, on: row)
            }
        case .up, .down:
            let rows = rows
            guard model.state.session.isUnlocked, !rows.isEmpty else { return true }
            let current = rows.firstIndex { $0.id == selectedRow?.id } ?? 0
            state.selectedRowID = rows[min(max(current + (key == .down ? 1 : -1), 0), rows.count - 1)].id
        }
        return true
    }

    /// A text typed while no view of the panel has the keyboard: it goes to the search, and the
    /// search field takes the keyboard again.
    fileprivate func type(_ text: String) {
        guard model.state.session.isUnlocked, !isBusy else { return }
        state.search += text
        state.focusRequest += 1
    }

    private func perform(_ action: QuickItemAction, on row: QuickAccessSection.Row) {
        guard state.isPresented, model.state.session.isUnlocked, !isBusy,
              let current = model.state.vault.items.first(where: { $0.id == row.item.id }),
              !current.isInTrash, !current.isArchived, !current.isUndecryptable,
              QuickItemAction.offered(for: current).contains(action) else { return }
        switch action {
        case .copy(let field): ItemCopier(model: model, navigation: navigation).copy(field, of: current)
        case .browser: ItemCopier(model: model, navigation: navigation).launch(current)
        case .fill: chooseFill(row)
        case .openWindow, .openMain:
            navigation.perform(on: current) { [weak self] in
                guard let self, state.isPresented, model.state.session.isUnlocked else { return }
                close()
                if action == .openWindow { openItemWindow(current.id) } else { openItem(current.id) }
            }
        }
    }

    fileprivate func actionShortcut(_ action: QuickItemAction) -> Bool {
        // The main window can have a different item selected behind this panel.
        // Always consume panel shortcuts, even when its own action is unavailable.
        if !isBusy, model.state.session.isUnlocked, let row = selectedRow {
            perform(action, on: row)
        }
        return true
    }

    /// The shortcut that fills without the panel, as the autotype shortcut of the reference.
    /// The one login of the page or of the app in front is filled at once: into its form, or
    /// into the one field that has the cursor. With no such login, with several, with one that
    /// asks for the master password, in an app that tells no page and has no login, or when the
    /// fill fails, the panel opens and the user chooses there.
    func fillFromShortcut() {
        Task { @MainActor in
            guard model.state.session.isUnlocked else { return show() }
            guard await model.isFillAllowed() else {
                await model.askForFillPermission()
                return
            }
            // A browser that was just asked to tell of its pages needs a moment for it.
            var target = await model.fillTarget()
            for pause in [200, 400, 600] where target == nil {
                try? await Task.sleep(for: .milliseconds(pause))
                target = await model.fillTarget()
            }
            if let target, target.website != nil || target.app != nil {
                let logins = model.state.vault.logins(ofPage: target.website, app: target.app)
                    .filter { !$0.isInTrash && !$0.isArchived }
                if logins.count == 1, let login = logins.first, !login.asksForMasterPassword {
                    do {
                        if target.takesLogin, login.fields.isSuperset(of: [.username, .password]) {
                            try await model.fillLogin(of: login.id, into: target)
                            return
                        }
                        if target.takesValue, let field = target.suggestedLoginField, login.fields.contains(field) {
                            try await model.fill(field, of: login.id, into: target)
                            return
                        }
                    } catch {
                        // The panel says nothing of it: it opens, and the user fills from there.
                    }
                }
            }
            show()
        }
    }

    /// "Fill" of a row: the login into a login form; else the one field the item has, or the
    /// menu of its fields.
    func chooseFill(_ row: QuickAccessSection.Row) {
        let fields = QuickAccessState.fillFields(of: row.item)
        if state.target?.isVerificationCode == true, fields.contains(.verificationCode) {
            requestFill(.verificationCode, of: row.item)
        } else if state.fillsLoginForm(with: row.item) {
            requestFill(nil, of: row.item)
        } else if state.target?.isUnclassifiedCode != true, fields.count == 1, let only = fields.first {
            requestFill(only, of: row.item)
        } else if !fields.isEmpty {
            state.fillMenuRowID = row.id
        }
    }

    /// The answer to "confirm autofill". A protected field of an item that asks for the master
    /// password waits for it before it is filled.
    func answerFill(_ accepted: Bool) {
        answerFill(accepted ? .fill : .cancel)
    }

    func answerFill(_ answer: QuickAccessState.FillAnswer) {
        guard let pending = state.pendingFill, state.fillAnswers.contains(answer) else { return }
        state.pendingFill = nil
        state.markedFillAnswer = .fill
        guard answer != .cancel else { return }
        let run = { @MainActor [weak self] in
            guard let self else { return }
            self.fill(pending.field, of: pending.item, addingPage: answer == .saveAndFill, addingApp: answer == .saveAppAndFill)
        }
        if pending.field?.isPublic == true { run() } else { navigation.perform(on: pending.item, run) }
    }

    /// A field was chosen. A login of the web page or of the app in front is filled at once,
    /// after the master password when the item asks for it. Into any other field the user
    /// confirms first.
    /// Without a field the fill goes on and ends with the permission of the system or with the
    /// word that nothing could be filled.
    func requestFill(_ field: ItemField?, of item: VaultItemSummary) {
        state.fillMenuRowID = nil
        guard let target = state.target else { return fill(field, of: item) }
        if model.state.vault.logins(ofPage: target.website, app: target.app).contains(where: { $0.id == item.id }) {
            let run = { @MainActor [weak self] in
                guard let self else { return }
                self.fill(field, of: item)
            }
            // A login holds its password: it waits for the master password as the password alone does.
            if field?.isPublic == true { run() } else { navigation.perform(on: item, run) }
        } else {
            state.pendingFill = .init(item: item, field: field)
        }
    }

    /// The copy shortcuts of the application menu, here for the row the keyboard is on: Command
    /// with U, P and T for the user name, the password and the verification code of a login.
    /// Returns false for another key.
    fileprivate func copyShortcut(_ key: String) -> Bool {
        let field: ItemField? = switch key {
        case "u": .username
        case "p": .password
        case "t": .verificationCode
        default: nil
        }
        guard let field else { return false }
        return actionShortcut(.copy(field))
    }

    /// A click elsewhere takes the keyboard from the panel: it closes.
    func windowDidBecomeKey(_ notification: Notification) {
        state.hasKeyboard = true
    }

    func windowDidResignKey(_ notification: Notification) {
        state.hasKeyboard = false
        // Only a panel that is on the screen: the notice of an earlier closing can come late,
        // while the panel is about to open again. The question of the system for Touch ID
        // takes the keyboard too, and the panel waits for its answer.
        guard closesWithoutKeyboard, panel.isVisible, !state.isAskingForTouchID else { return }
        close()
        closedByClickElsewhere = Date()
    }
}

/// A panel without a title bar that takes the keyboard all the same.
final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape, when no view of the content took it.
    override func cancelOperation(_ sender: Any?) {
        _ = (delegate as? QuickAccessPanelController)?.press(.escape)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let controller = delegate as? QuickAccessPanelController,
           event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
            let key: QuickAccessPanelController.Key? = switch event.keyCode {
            case 124: .right
            case 123 where controller.state.detailRowID != nil: .left
            case 53 where controller.state.detailRowID != nil: .escape
            default: nil
            }
            if let key, controller.press(key) { return }
        }
        super.sendEvent(event)
    }

    /// The copy shortcuts come before the application menu, whose items of the same keys copy
    /// from the item that is open in the main window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let controller = delegate as? QuickAccessPanelController {
            let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.charactersIgnoringModifiers?.lowercased() == "o" {
                if mods == .command, controller.actionShortcut(.openWindow) { return true }
                if mods == [.command, .shift], controller.actionShortcut(.openMain) { return true }
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if mods == .option, controller.actionShortcut(.browser) { return true }
                if mods == .shift, controller.actionShortcut(.fill) { return true }
            }
        }
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           (delegate as? QuickAccessPanelController)?.copyShortcut(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A key that no view of the content took: none of them has the keyboard, as in the states
    /// without a search field, or after a menu closed. The panel does with it what its content
    /// would have done.
    override func keyDown(with event: NSEvent) {
        guard let controller = delegate as? QuickAccessPanelController else { return super.keyDown(with: event) }
        let key: QuickAccessPanelController.Key? = switch event.keyCode {
        case 36, 76: .enter
        case 53: .escape
        case 125: .down
        case 126: .up
        case 123: .left
        case 124: .right
        default: nil
        }
        if let key {
            if !controller.press(key) { super.keyDown(with: event) }
        } else if let text = event.characters, !text.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            controller.type(text)
        } else {
            super.keyDown(with: event)
        }
    }
}
