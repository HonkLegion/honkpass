import AppKit
import Engine

/// A client of the engine. It presents public request data and sends decisions by request ID.
@MainActor
final class SSHApprovalWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let preferences: AppPreferences
    private(set) var window: SSHApprovalPanel?
    private var isClosing = false

    init(model: AppModel, preferences: AppPreferences) {
        self.model = model
        self.preferences = preferences
        super.init()
    }

    func update() {
        let state = model.state
        guard state.settings.sshAgent.isEnabled, state.session.account != nil else { close(); return }
        let id: UUID?
        if state.session.isUnlocked { id = state.sshApproval?.id } else { id = state.sshUnlockRequest?.id }
        guard let id else {
            // The engine retains this request while it validates the newly unlocked key.
            if let window, window.isUnlocking, state.session.isUnlocked,
               state.sshUnlockRequest?.id == window.requestID {
                window.clearSecret()
                window.showProgress()
            } else { close() }
            return
        }
        let panel: SSHApprovalPanel
        if let window { panel = window } else {
            panel = SSHApprovalPanel(model: model) { [weak self] id, allowed in self?.answer(id: id, allowed: allowed) }
            panel.delegate = self
            panel.sharingType = preferences.allowsScreenshots ? .readOnly : .none
            window = panel
        }
        let changed = panel.update(requestID: id)
        if !panel.isVisible {
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        if changed { panel.focusSafely() }
    }

    private func answer(id: UUID, allowed: Bool) {
        guard let panel = window, panel.requestID == id else { return }
        if allowed {
            guard model.state.session.isUnlocked else { return }
            guard model.state.sshApproval?.id == id else { return }
            panel.setDecisionPending()
            Task { [model] in await model.answerSSHApproval(id: id, isAllowed: allowed) }
        } else {
            guard model.state.sshUnlockRequest?.id == id || model.state.sshApproval?.id == id else { return }
            panel.setDecisionPending()
            Task { [model] in await model.cancelSSHRequest(id: id) }
        }
    }

    private func close() {
        isClosing = true
        window?.clearSecret()
        window?.close()
        window = nil
        isClosing = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing, let panel = notification.object as? SSHApprovalPanel, panel === window else { return }
        let id = panel.requestID
        panel.clearSecret()
        window = nil
        if let id { Task { [model] in await model.cancelSSHRequest(id: id) } }
    }
}
