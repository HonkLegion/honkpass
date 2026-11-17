import AppKit
import DesignKit
import Engine

/// One system glass surface, native controls and no private key material.
@MainActor
final class SSHApprovalPanel: NSPanel {
    private enum UnlockMethod { case biometrics, pin, masterPassword }
    private let model: AppModel
    private let answer: (UUID, Bool) -> Void
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private var stack = NSStackView()
    private var focusControls: [NSControl] = []
    private var secretField: NSSecureTextField?
    private var allowButton: NSButton?
    private var denyButton: NSButton?
    private var closeButton: NSButton?
    private var pendingLabel: NSTextField?
    private var problemLabel: NSTextField?
    private var unlockTask: Task<Void, Never>?
    private var method = UnlockMethod.masterPassword
    private var deliberateFocus = false
    private var sentDecision = false
    private var renderedApproval: SSHApproval?
    private var renderedAccountID: String?
    private var renderedOptions: [Bool] = []
    #if DEBUG
    private var fingerprintControls: [NSView] = []

    func hasCenteredFingerprint() -> Bool {
        guard fingerprintControls.count == 2, let contentView else { return false }
        contentView.layoutSubtreeIfNeeded()
        let frames = fingerprintControls.compactMap { control -> NSRect? in
            guard let parent = control.superview else { return nil }
            return parent.convert(control.alignmentRect(forFrame: control.frame), to: contentView)
        }
        guard frames.count == 2 else { return false }
        let group = frames[0].union(frames[1])
        let centered = abs(group.midX - contentView.bounds.midX) <= 1
        if !centered { print("SSH public layout: window=\(contentView.bounds), controls=\(frames)") }
        return centered
    }
    #endif
    private(set) var requestID: UUID?
    private(set) var isUnlocking = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(model: AppModel, answer: @escaping (UUID, Bool) -> Void) {
        self.model = model
        self.answer = answer
        super.init(contentRect: NSRect(x: 0, y: 0, width: Metric.sshPromptWidth, height: 360),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        title = BWText["sshkeyApprovalTitle"]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        glass.style = .regular
        glass.cornerRadius = Metric.sshPromptCornerRadius
        glass.frame = NSRect(x: 0, y: 0, width: Metric.sshPromptWidth, height: 360)
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        contentView = glass
    }

    @discardableResult func update(requestID id: UUID) -> Bool {
        let state = model.state
        let locked = !state.session.isUnlocked
        let options = [state.biometrics.canUnlock, state.pin.canUnlock]
        let newContext = requestID != id || isUnlocking != locked || renderedAccountID != state.session.account?.id
        let changed = newContext || renderedApproval != state.sshApproval
            || renderedAccountID != state.session.account?.id || renderedOptions != options
        if changed {
            clearSecret()
            requestID = id
            isUnlocking = locked
            renderedApproval = state.sshApproval
            renderedAccountID = state.session.account?.id
            renderedOptions = options
            if newContext || (method == .biometrics && !options[0]) || (method == .pin && !options[1]) {
                method = options[0] ? .biometrics : (options[1] ? .pin : .masterPassword)
            }
            sentDecision = false
            deliberateFocus = false
            rebuild()
        }
        pendingLabel?.stringValue = BWText["honkpassSSHPending", "\(max(0, (state.sshPendingRequestCount ?? 1) - 1))"]
        pendingLabel?.isHidden = (state.sshPendingRequestCount ?? 1) <= 1
        let busy = state.activity != nil || unlockTask != nil || sentDecision
        allowButton?.isEnabled = !busy
        secretField?.isEnabled = !busy
        if isUnlocking { allowButton?.title = busy ? progressTitle : unlockTitle }
        fitContent()
        return changed
    }

    func clearSecret() {
        unlockTask?.cancel()
        unlockTask = nil
        secretField?.stringValue = ""
    }

    func showProgress() {
        clearSecret()
        secretField = nil
        #if DEBUG
        fingerprintControls = []
        #endif
        focusControls = [closeButton].compactMap { $0 }
        makeFirstResponder(nil)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label(BWText["loadingVault"], size: TextStyle.h4.size))
        fitContent()
    }

    func setDecisionPending() {
        sentDecision = true
        focusControls.forEach { $0.isEnabled = false }
    }

    func focusSafely() {
        deliberateFocus = false
        initialFirstResponder = secretField ?? denyButton
        makeFirstResponder(initialFirstResponder)
    }

    override func becomeKey() {
        super.becomeKey()
        focusSafely()
    }

    private func rebuild() {
        secretField?.stringValue = ""
        secretField = nil
        #if DEBUG
        fingerprintControls = []
        #endif
        focusControls = []
        content.subviews.forEach { $0.removeFromSuperview() }
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let inset = Metric.sshPromptInset
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -inset),
        ])
        let close = iconButton("xmark", label: BWText["close"], action: #selector(deny(_:)))
        closeButton = close
        close.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
        ])
        focusControls.append(close)

        let applicationURL = isUnlocking ? model.state.sshUnlockRequest?.requesterApplicationURL
            : model.state.sshApproval?.requesterApplicationURL
        let applicationIcon = applicationURL.flatMap { url -> NSImage? in
            guard url.isFileURL, url.pathExtension == "app" else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let source = NSImageView(image: applicationIcon ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!)
        let defaultIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        let app = NSImageView(image: defaultIcon ?? NSApp.applicationIconImage)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!)
        source.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        source.contentTintColor = NativeColor.label
        arrow.contentTintColor = NativeColor.label
        for image in [source, arrow, app] { image.setAccessibilityElement(false) }
        let marks = row([source, arrow, app], spacing: 24)
        for image in [source, app] {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 56).isActive = true
            image.heightAnchor.constraint(equalToConstant: 56).isActive = true
        }
        arrow.widthAnchor.constraint(equalToConstant: 32).isActive = true
        stack.addArrangedSubview(marks)
        let process = isUnlocking ? model.state.sshUnlockRequest?.processName : model.state.sshApproval?.processName
        let name = process.flatMap { $0.isEmpty ? nil : $0 } ?? BWText["unknownApplication"]
        let request = label(BWText[isUnlocking ? "honkpassSSHUnlockRequest" : "honkpassSSHRequest", name],
                            size: TextStyle.h3.size, weight: .semibold)
        request.alignment = .center
        stack.addArrangedSubview(request)
        request.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if isUnlocking { addUnlockForm() } else if let approval = model.state.sshApproval { addKey(approval) }
        let pending = label("", size: TextStyle.xs.size, secondary: true)
        pendingLabel = pending
        stack.addArrangedSubview(pending)
        let problem = label("", size: TextStyle.sm.size)
        problem.textColor = NativeColor.danger
        problem.isHidden = true
        problemLabel = problem
        stack.addArrangedSubview(problem)
        problem.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let deny = button(BWText["deny"], action: #selector(deny(_:)))
        deny.tintProminence = .none
        let allow = button(isUnlocking ? unlockTitle : BWText["authorize"], action: #selector(allow(_:)))
        allow.bezelColor = NativeColor.accent
        allow.tintProminence = .primary
        denyButton = deny
        allowButton = allow
        focusControls += [deny, allow]
        let actions = row([deny, allow])
        actions.distribution = .fillEqually
        stack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for control in [deny, allow] {
            control.controlSize = .large
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        fitContent()
    }

    private func addKey(_ approval: SSHApproval) {
        let key = label(approval.keyName, size: TextStyle.base.size, weight: .semibold)
        key.maximumNumberOfLines = 2
        key.toolTip = approval.keyName
        stack.addArrangedSubview(key)
        key.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let caption = label(BWText["honkpassSSHFingerprint"], size: TextStyle.xs.size)
        let fingerprint = label(approval.publicKeyFingerprint ?? BWText["honkpassSSHNoFingerprint"], size: TextStyle.xs.size)
        fingerprint.font = BWFont.nativeMonospacedAppKit()
        fingerprint.preferredMaxLayoutWidth = Metric.sshPromptWidth - 2 * Metric.sshPromptInset - 40
        fingerprint.widthAnchor.constraint(lessThanOrEqualToConstant: fingerprint.preferredMaxLayoutWidth).isActive = true
        fingerprint.lineBreakMode = .byCharWrapping
        fingerprint.isSelectable = true
        let copy = iconButton("doc.on.doc", label: BWText["honkpassSSHCopyFingerprint"], action: #selector(copyFingerprint(_:)))
        copy.isEnabled = approval.publicKeyFingerprint != nil
        focusControls.append(copy)
        let details = row([])
        details.distribution = .gravityAreas
        details.setViews([fingerprint, copy], in: .center)
        #if DEBUG
        fingerprintControls = [fingerprint, copy]
        #endif
        let publicKey = NSStackView(views: [caption, details])
        publicKey.translatesAutoresizingMaskIntoConstraints = false
        publicKey.orientation = .vertical
        publicKey.alignment = .centerX
        publicKey.spacing = 4
        stack.addArrangedSubview(publicKey)
        publicKey.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        details.widthAnchor.constraint(equalTo: publicKey.widthAnchor).isActive = true
        details.centerXAnchor.constraint(equalTo: publicKey.centerXAnchor).isActive = true
        let actionKey: String = switch approval.action {
        case .logIn: approval.verifiedHostFingerprint == nil ? "honkpassSSHUnknownPurpose" : "sshActionLogin"
        case .signGit: "honkpassSSHGitSign"
        case .sign: "sshActionSign"
        }
        let purpose = label(BWText["honkpassSSHRequestedPurpose", BWText[actionKey]], size: TextStyle.sm.size)
        stack.addArrangedSubview(purpose)
        purpose.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let account = model.state.session.account {
            let vault = label(BWText["honkpassSSHVault", account.email, account.serverURL.host() ?? ""], size: TextStyle.sm.size)
            stack.addArrangedSubview(vault)
            vault.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let host = approval.verifiedHostFingerprint {
            let server = label(BWText["honkpassSSHVerifiedHost", host], size: TextStyle.xs.size)
            server.isSelectable = true
            stack.addArrangedSubview(server)
            server.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if approval.action == .logIn {
            let unknown = label(BWText["honkpassSSHUnknownDestination"], size: TextStyle.sm.size)
            stack.addArrangedSubview(unknown)
            unknown.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if approval.isForwarding {
            let warning = label(BWText["agentForwardingWarningText"], size: TextStyle.sm.size)
            stack.addArrangedSubview(warning)
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func addUnlockForm() {
        stack.addArrangedSubview(label(model.state.session.account?.email ?? "", size: TextStyle.sm.size, secondary: true))
        if method != .biometrics {
            let field = NSSecureTextField()
            field.placeholderString = BWText[method == .pin ? "pin" : "masterPass"]
            field.setAccessibilityLabel(field.placeholderString)
            field.font = BWFont.nativeAppKit()
            field.target = self
            field.action = #selector(submitSecret(_:))
            secretField = field
            focusControls.append(field)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let options: [(UnlockMethod, String)] = [(.biometrics, "unlockWithTouchId"), (.pin, "unlockWithPin"),
                                                (.masterPassword, "unlockWithMasterPassword")]
        for (option, title) in options where option != method {
            if option == .biometrics && !model.state.biometrics.canUnlock { continue }
            if option == .pin && !model.state.pin.canUnlock { continue }
            let choice = button(BWText[title], action: #selector(changeUnlockMethod(_:)))
            choice.tag = option == .biometrics ? 0 : (option == .pin ? 1 : 2)
            choice.isBordered = false
            focusControls.append(choice)
            stack.addArrangedSubview(choice)
        }
    }

    private var unlockTitle: String {
        switch method {
        case .biometrics: BWText["unlockWithTouchId"]
        case .pin, .masterPassword: BWText["unlock"]
        }
    }

    private var progressTitle: String {
        switch model.state.authenticationPhase {
        case .syncing: BWText["sync"]
        case .loadingVault, .saving: BWText["loadingVault"]
        default: BWText["authenticating"]
        }
    }

    @objc private func allow(_ sender: NSButton) {
        guard sender === allowButton, !sentDecision, let id = requestID else { return }
        if isUnlocking { unlock(id: id) } else { answer(id, true) }
    }

    @objc private func deny(_ sender: NSButton) {
        guard focusControls.contains(where: { $0 === sender }), let id = requestID else { return }
        clearSecret()
        answer(id, false)
    }

    @objc private func submitSecret(_ sender: NSSecureTextField) {
        guard sender === secretField, let id = requestID else { return }
        unlock(id: id)
    }

    private func unlock(id: UUID) {
        guard unlockTask == nil, model.state.activity == nil, model.state.sshUnlockRequest?.id == id,
              !model.state.session.isUnlocked, let accountID = model.state.session.account?.id else { return }
        let secret = secretField?.stringValue ?? ""
        guard method == .biometrics || !secret.isEmpty else { showProblem(BWText["inputRequired"]); return }
        let method = method
        unlockTask = Task { [weak self, model] in
            do {
                switch method {
                case .biometrics: try await model.unlockWithBiometrics(reason: BWText["touchIdConsentMessage"])
                case .pin: try await model.unlock(pin: secret)
                case .masterPassword: try await model.unlock(masterPassword: secret)
                }
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id,
                      model.state.session.account?.id == accountID else { return }
                switch error {
                case EngineError.biometrics(.cancelled), EngineError.cancelled: break
                case EngineError.wrongPin: self.showProblem(BWText["invalidPin"])
                default: self.showProblem(BWText[method == .biometrics ? "couldNotCompleteBiometrics" : "invalidMasterPassword"])
                }
            }
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.unlockTask = nil
            self.secretField?.stringValue = ""
            if model.state.session.isUnlocked && model.state.sshApproval?.id != id {
                self.showProgress()
            } else { self.update(requestID: id) }
        }
        update(requestID: id)
    }

    @objc private func changeUnlockMethod(_ sender: NSButton) {
        guard focusControls.contains(where: { $0 === sender }), unlockTask == nil else { return }
        clearSecret()
        method = sender.tag == 0 ? .biometrics : (sender.tag == 1 ? .pin : .masterPassword)
        rebuild()
        focusSafely()
    }

    @objc private func copyFingerprint(_ sender: NSButton) {
        guard focusControls.contains(where: { $0 === sender }), !isUnlocking,
              model.state.sshApproval?.id == requestID, let value = model.state.sshApproval?.publicKeyFingerprint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    override func performClose(_ sender: Any?) {
        if let id = requestID { clearSecret(); answer(id, false) }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        if event.keyCode == 53 { performClose(nil); return true }
        guard isKeyWindow else { return false }
        if event.keyCode == 48 {
            let controls = focusControls.filter { $0.isEnabled && !$0.isHidden }
            guard !controls.isEmpty else { return true }
            let current = controls.firstIndex { firstResponder === $0 || ($0 as? NSTextField)?.currentEditor() === firstResponder }
            let direction = event.modifierFlags.contains(.shift) ? controls.count - 1 : 1
            let index = ((current ?? controls.count - 1) + direction) % controls.count
            deliberateFocus = makeFirstResponder(controls[index])
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            if isUnlocking, secretField?.currentEditor() === firstResponder { return false }
            if deliberateFocus, let button = focusControls.first(where: { $0 === firstResponder }) as? NSButton {
                button.performClick(nil)
            }
            return true
        }
        return false
    }

    private func showProblem(_ message: String) {
        problemLabel?.stringValue = message
        problemLabel?.isHidden = false
        fitContent()
    }

    private func fitContent() {
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Metric.sshPromptWidth,
                          height: max(Metric.sshPromptMinHeight, stack.fittingSize.height + 2 * Metric.sshPromptInset))
        guard frame.size != size else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func label(_ text: String, size: CGFloat = TextStyle.body.size, weight: NSFont.Weight = .regular,
                       secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.font = BWFont.nativeAppKit(size, weight: weight)
        label.textColor = secondary ? NativeColor.secondaryLabel : NativeColor.label
        label.preferredMaxLayoutWidth = Metric.sshPromptWidth - 2 * Metric.sshPromptInset
        return label
    }

    private func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let row = NSStackView(views: views)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.borderShape = .capsule
        button.font = BWFont.nativeAppKit()
        button.keyEquivalent = ""
        button.setAccessibilityLabel(title)
        return button
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
}
