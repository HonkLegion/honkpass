import AppKit
import ApplicationServices
import Engine
import Foundation
import os
import VaultModel

/// A pair belongs either to the same nearest web area (possibly an iframe), or to a
/// native form with no web area. Never substitute a containing page for the fields' page.
struct FillFormPage<Page> {
    let page: Page?

    init?(usernamePage: Page?, passwordPage: Page?, equal: (Page, Page) -> Bool) {
        switch (usernamePage, passwordPage) {
        case (nil, nil): page = nil
        case (.some(let first), .some(let second)) where equal(first, second): page = first
        default: return nil
        }
    }

    func matches(_ other: Page?, equal: (Page, Page) -> Bool) -> Bool {
        switch (page, other) {
        case (nil, nil): true
        case (.some(let first), .some(let second)): equal(first, second)
        default: false
        }
    }
}

/// The field that has the cursor in the app in front, through the Accessibility API of macOS.
/// Values use Accessibility. Web password fields use process-targeted Unicode input so
/// WebKit sends edit events. Nothing goes through the clipboard or global keyboard stream.
/// It needs the Accessibility permission, which only the user can give.
///
/// A capture is taken when quick access opens and holds for a minute. A write checks again
/// that the same app is in front and the same field has the cursor, and tries once.
public actor MacActiveField: ActiveFieldPort {
    private struct LoginForm {
        let username: AXUIElement
        let password: AXUIElement
        var verificationCode: AXUIElement?
        var fields: [AXUIElement] { [username, password] + (verificationCode.map { [$0] } ?? []) }
    }

    private struct Capture {
        let target: FillTarget
        let processID: pid_t
        let launched: Date?
        let field: AXUIElement
        let taken: Date
        /// The exact page that supplied the origin, checked again before each value is sent.
        let webArea: AXUIElement?
        /// The two fields of the login form the field is in. nil for a field of no such form.
        let form: LoginForm?
    }

    private var capture: Capture?

    /// Why a field was not found or not written: the names of apps and of the kinds of their
    /// fields, and the error numbers of the Accessibility API. Never a value of a field.
    private static let log = Logger(subsystem: "PassVault", category: "fill")

    /// How long the system waits for an answer of the other app.
    private static let patience: Float = 0.2
    private static let lifetime: TimeInterval = 60
    /// The largest text that is written.
    private static let maximumBytes = 32 * 1024
    /// Parts of the system that ask for passwords of their own: never a target.
    private static let systemApps: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent",
        "com.apple.systempreferences", "com.apple.LocalAuthentication.UIAgent",
    ]

    public init() {}

    public func isAllowed() async -> Bool {
        AXIsProcessTrusted()
    }

    public func askToBeAllowed() async {
        // The dialog of the system. It shows once; later calls show nothing, so the place in the
        // settings where the permission is given is opened too.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        Self.log.notice("permission: the system was asked; allowed already: \(isTrusted)")
        guard !isTrusted else { return }
        if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            await MainActor.run { _ = NSWorkspace.shared.open(settings) }
        }
    }

    public func capture() async -> FillTarget? {
        capture = nil
        guard AXIsProcessTrusted() else {
            Self.log.notice("capture: the system does not allow PassVault to use other apps")
            return nil
        }
        guard let app = Self.appInFront() else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            Self.log.notice("capture: the app in front is no target: \(front, privacy: .public)")
            return nil
        }
        let name = app.bundleIdentifier ?? "unknown"
        guard let field = Self.fieldWithCursor(of: app.processIdentifier, appName: name) else {
            // The app names no element with the cursor at all. Chromium answers so until it
            // has built what it tells the Accessibility of the system: its window is looked at.
            return captureForm(of: app, focused: nil, appName: name)
        }
        guard Self.takesText(field, appName: name) else {
            // No field has the cursor: the login form of the page or the window in front.
            return captureForm(of: app, focused: field, appName: name)
        }
        let page = Self.webArea(above: field)
        let codeKind = Self.codeKind(field)
        let form: LoginForm? = (codeKind == .other ? Self.loginForm(around: field) : nil).flatMap { pair in
            guard let shared = Self.formPage(pair), shared.matches(page, equal: { CFEqual($0, $1) }) else { return nil }
            return pair
        }
        Self.log.notice("capture: a field of \(name, privacy: .public) was found; a login form around it: \(form != nil)")
        let origin = Self.origin(of: app, page: page)
        let target = FillTarget(appName: app.localizedName ?? app.bundleIdentifier ?? "", bundleID: app.bundleIdentifier,
                                app: origin.app, website: origin.website,
                                isSecure: Self.text(field, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String),
                                takesLogin: form != nil, isVerificationCode: codeKind == .verification,
                                takesVerificationCode: form?.verificationCode != nil, isUnclassifiedCode: codeKind == .ambiguous)
        capture = Capture(target: target, processID: app.processIdentifier, launched: app.launchDate, field: field, taken: Date(), webArea: page,
                          form: form)
        return target
    }

    /// The capture of a page or a window in which no field has the cursor. The form is looked
    /// for in the web page in front, or in the window of an app that shows no page. A browser
    /// that shows PassVault no page is asked to: it builds what it tells the Accessibility of
    /// the system only once somebody asks for it, and the next look finds the page.
    private func captureForm(of app: NSRunningApplication, focused: AXUIElement?, appName name: String) -> FillTarget? {
        let window = focused.flatMap { Self.window(of: $0, processID: app.processIdentifier) }
            ?? Self.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
        guard let window else {
            Self.log.notice("page: \(name, privacy: .public) names no window in front")
            if Self.isBrowser(app) { Self.askForAccessibility(of: app.processIdentifier, appName: name) }
            return nil
        }
        let deadline = Date().addingTimeInterval(Self.pageTime)
        var budget = Self.pageFields
        let page = focused.flatMap { Self.text($0, kAXRoleAttribute) == "AXWebArea" ? $0 : nil }
            ?? Self.webArea(under: window, budget: &budget, deadline: deadline)
        if page == nil, Self.isBrowser(app) {
            Self.askForAccessibility(of: app.processIdentifier, appName: name)
            return nil
        }
        // The look ends at the first pair: a page is larger than a form, and need not be read whole.
        var fields: [(element: AXUIElement, isSecure: Bool)] = []
        _ = Self.collectTextFields(under: page ?? window, into: &fields, budget: &budget, deadline: deadline, untilPair: true)
        let loginFields = fields.filter { Self.codeKind($0.element) == .other }
        guard let pair = LoginFormFields.first(isSecure: loginFields.map(\.isSecure)) else {
            Self.log.notice("page: no login form in what \(name, privacy: .public) shows; text fields seen: \(fields.count)")
            return nil
        }
        let basicForm = LoginForm(username: loginFields[pair.username].element, password: loginFields[pair.password].element)
        let fullForm = Self.loginForm(around: basicForm.username)
        let form = fullForm.flatMap { CFEqual($0.password, basicForm.password) ? $0 : nil } ?? basicForm
        guard let shared = Self.formPage(form) else { return nil }
        Self.log.notice("capture: a login form of \(name, privacy: .public) was found without a cursor in a field")
        let origin = Self.origin(of: app, page: shared.page)
        let target = FillTarget(appName: app.localizedName ?? app.bundleIdentifier ?? "", bundleID: app.bundleIdentifier,
                                app: origin.app, website: origin.website, takesLogin: true, takesValue: false,
                                takesVerificationCode: form.verificationCode != nil)
        // Such a capture is held to its window: there is no field with the cursor to hold it to.
        capture = Capture(target: target, processID: app.processIdentifier, launched: app.launchDate, field: window, taken: Date(), webArea: shared.page,
                          form: form)
        return target
    }

    public func write(_ text: String, to target: FillTarget, authorize: FillAuthorization) async throws {
        guard target.takesValue else { throw EngineError.fill(.noField) }
        let capture = try stillValid(target, bytes: text.utf8.count)
        let name = capture.target.bundleID ?? "unknown"
        // Once only: an answer that comes late does not say that the value was not set.
        let result = try await setValue(text, in: capture.field, capture: capture, authorize: authorize)
        guard result == .success else {
            Self.log.notice("write: \(name, privacy: .public) did not take the value, error \(result.rawValue)")
            throw EngineError.fill(.refused)
        }
        Self.log.notice("write: the value was set in \(name, privacy: .public)")
    }

    public func writeLogin(username: String, password: String, verificationCode: String?, to target: FillTarget,
                           authorize: FillAuthorization) async throws {
        let capture = try stillValid(target, bytes: max(username.utf8.count, password.utf8.count, verificationCode?.utf8.count ?? 0))
        let name = capture.target.bundleID ?? "unknown"
        guard let form = capture.form, Self.takesText(form.username, appName: name), Self.takesText(form.password, appName: name) else {
            throw EngineError.fill(.noField)
        }
        // Each value once. A form that took the first and not the second is told as refused:
        // the user sees which field is empty. The cursor goes into each field before its value:
        // a web page of WebKit says "done" for a field without the cursor and leaves it empty.
        // The cursor ends in the password, as after typing.
        var values = [(form.username, username), (form.password, password)]
        if let verificationCode {
            guard let field = form.verificationCode, Self.isVerificationCode(field), Self.takesText(field, appName: name) else {
                throw EngineError.fill(.noField)
            }
            values.append((field, verificationCode))
        }
        for (field, value) in values {
            let focus = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focus != .success {
                Self.log.notice("write: \(name, privacy: .public) did not put the cursor into a field of the login, error \(focus.rawValue)")
            }
            try? await Task.sleep(for: .milliseconds(60))
            try Self.checkOrigin(of: capture)
            let result = try await setValue(value, in: field, capture: capture, authorize: authorize)
            guard result == .success else {
                Self.log.notice("write: \(name, privacy: .public) did not take a value of the login, error \(result.rawValue)")
                throw EngineError.fill(.refused)
            }
        }
        Self.log.notice("write: the user name and the password were set in \(name, privacy: .public)")
    }

    /// WebKit's direct AXValue assignment can bypass input events for password fields.
    /// Process-targeted text input reaches its editor. AXSelectedText reports success but
    /// WebKit implements it as a no-op. Check the session, origin and exact focused element
    /// before every batch. Never retry an ambiguous write or send global keyboard events.
    private func setValue(_ value: String, in field: AXUIElement, capture: Capture,
                          authorize: FillAuthorization) async throws -> AXError {
        try await authorize()
        try Self.checkOrigin(of: capture)
        guard let focused = Self.fieldWithCursor(of: capture.processID, appName: capture.target.bundleID ?? "unknown"),
              CFEqual(focused, field) else { throw EngineError.fill(.targetChanged) }
        if capture.webArea != nil, Self.text(field, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            var rangeSettable = DarwinBoolean(false)
            var count: CFTypeRef?
            guard let chunks = BrowserInputText.chunks(value), !chunks.isEmpty,
                  AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success,
                  rangeSettable.boolValue,
                  AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
                  let length = count as? Int, length >= 0, length <= Self.maximumBytes else { throw EngineError.fill(.refused) }
            var range = CFRange(location: 0, length: length)
            guard let selection = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selection) == .success else {
                throw EngineError.fill(.refused)
            }
            var inserted = 0
            for chunk in chunks {
                try await authorize()
                try Self.checkOrigin(of: capture)
                guard let focused = Self.fieldWithCursor(of: capture.processID, appName: capture.target.bundleID ?? "unknown"),
                      CFEqual(focused, field) else { throw EngineError.fill(.targetChanged) }
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw EngineError.fill(.refused)
                }
                let units = Array(chunk.utf16)
                down.flags = []
                up.flags = []
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                down.postToPid(capture.processID)
                up.postToPid(capture.processID)
                inserted += units.count
                // Posting is asynchronous. Do not move focus to the next field until the
                // editor acknowledges the insertion. Read only length and caret metadata.
                let deadline = Date().addingTimeInterval(0.5)
                while true {
                    try await Task.sleep(for: .milliseconds(15))
                    try await authorize()
                    try Self.checkOrigin(of: capture)
                    guard let focused = Self.fieldWithCursor(of: capture.processID, appName: capture.target.bundleID ?? "unknown"),
                          CFEqual(focused, field) else { throw EngineError.fill(.targetChanged) }
                    var selected: CFTypeRef?
                    var count: CFTypeRef?
                    var caret = CFRange()
                    if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
                       let selected, CFGetTypeID(selected) == AXValueGetTypeID(),
                       AXValueGetValue(selected as! AXValue, .cfRange, &caret),
                       AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
                       count as? Int == inserted, caret.location == inserted, caret.length == 0 { break }
                    guard Date() < deadline else { throw EngineError.fill(.refused) }
                }
            }
            return .success
        }
        return AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString)
    }

    /// The capture of a target, when it can still be written to: the same app is in front and
    /// the same field has the cursor. One capture serves one write.
    private func stillValid(_ target: FillTarget, bytes: Int) throws -> Capture {
        guard AXIsProcessTrusted() else { throw EngineError.fill(.notAllowed) }
        guard let capture, capture.target.id == target.id else {
            Self.log.notice("write: the capture is not the one that was asked for")
            throw EngineError.fill(.targetChanged)
        }
        self.capture = nil
        let name = capture.target.bundleID ?? "unknown"
        guard Date().timeIntervalSince(capture.taken) < Self.lifetime, bytes <= Self.maximumBytes else {
            Self.log.notice("write: the capture is too old or the text too long")
            throw EngineError.fill(.targetChanged)
        }
        guard let app = Self.appInFront(), app.processIdentifier == capture.processID, app.launchDate == capture.launched else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            Self.log.notice("write: another app is in front now: \(front, privacy: .public)")
            throw EngineError.fill(.targetChanged)
        }
        try Self.checkOrigin(of: capture)
        guard capture.target.takesValue else {
            // A form without a cursor in a field: the same window has to be in front.
            guard let window = Self.element(AXUIElementCreateApplication(capture.processID), kAXFocusedWindowAttribute),
                  CFEqual(window, capture.field) else {
                Self.log.notice("write: another window of \(name, privacy: .public) is in front now")
                throw EngineError.fill(.targetChanged)
            }
            return capture
        }
        guard let field = Self.fieldWithCursor(of: capture.processID, appName: name) else { throw EngineError.fill(.targetChanged) }
        guard CFEqual(field, capture.field) else {
            Self.log.notice("write: another field of \(name, privacy: .public) has the cursor now")
            throw EngineError.fill(.targetChanged)
        }
        guard Self.takesText(field, appName: name) else { throw EngineError.fill(.noField) }
        return capture
    }

    // MARK: The login form

    /// The most fields of a form that are looked at, and the longest the look may take. A form
    /// that is larger, or an app that answers slower, has no login form for PassVault.
    private static let formFields = 300
    private static let formTime: TimeInterval = 0.3
    private static let formLevels = 8
    /// The same for a whole page or window, where no field has the cursor to start from.
    private static let pageFields = 2000
    private static let pageTime: TimeInterval = 0.6

    /// The window an element is in, or the element itself when it is a window.
    private static func window(of focused: AXUIElement, processID: pid_t) -> AXUIElement? {
        if text(focused, kAXRoleAttribute) == (kAXWindowRole as String) { return focused }
        if let window = element(focused, kAXWindowAttribute) { return window }
        return element(AXUIElementCreateApplication(processID), kAXFocusedWindowAttribute)
    }

    /// The first web page under an element, in the order of the tree.
    private static func webArea(under element: AXUIElement, budget: inout Int, deadline: Date) -> AXUIElement? {
        budget -= 1
        guard budget >= 0, Date() < deadline else { return nil }
        if text(element, kAXRoleAttribute) == "AXWebArea" { return element }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = webArea(under: child, budget: &budget, deadline: deadline) { return found }
        }
        return nil
    }

    /// An app that opens web addresses: a browser.
    private static func isBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL, let page = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: page).contains { $0.standardizedFileURL == bundle.standardizedFileURL }
    }

    /// Both focused-field and whole-form captures pass through this same origin policy.
    private static func origin(of app: NSRunningApplication, page: AXUIElement?) -> FillOrigin {
        FillOrigin(bundleID: app.bundleIdentifier, signature: AppSignature.ofProcess(app.processIdentifier),
                   isRegisteredBrowser: app.bundleURL.map { AppSignature.isBrowser(at: $0) } ?? false,
                   reportedWebsite: page.flatMap(pageAddress))
    }

    private static func formPage(_ form: LoginForm) -> FillFormPage<AXUIElement>? {
        FillFormPage(usernamePage: webArea(above: form.username), passwordPage: webArea(above: form.password),
                     equal: { CFEqual($0, $1) })
    }

    private static func checkOrigin(of capture: Capture) throws {
        guard let app = appInFront(), app.processIdentifier == capture.processID, app.launchDate == capture.launched else {
            throw EngineError.fill(.targetChanged)
        }
        let current = origin(of: app, page: capture.webArea)
        guard current.website == capture.target.website, current.app == capture.target.app else {
            throw EngineError.fill(.targetChanged)
        }
        if capture.target.website != nil {
            guard let page = capture.webArea else { throw EngineError.fill(.targetChanged) }
            let fields = capture.form?.fields ?? [capture.field]
            for field in fields {
                guard let currentPage = webArea(above: field), CFEqual(currentPage, page) else {
                    throw EngineError.fill(.targetChanged)
                }
            }
        }
    }

    /// Asks a browser to tell the Accessibility of the system about its pages. Browsers build
    /// that only for a client that asks: by the attribute Chromium and Electron have for it,
    /// or by the one a screen reader sets, which Firefox takes.
    private static func askForAccessibility(of processID: pid_t, appName name: String) {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, patience)
        // Both: Electron takes the first, Chromium the second, and neither says which it took.
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        log.notice("page: \(name, privacy: .public) shows no web page; it was asked to tell of its pages: \(manual.rawValue), \(enhanced.rawValue)")
    }

    /// The user name field and the password field of the form the field with the cursor is in.
    /// The form is the nearest part of the window above the field that holds such a pair; the
    /// search does not leave the web page or the window of the field. Only the kind of each
    /// element is read, never a value.
    private static func loginForm(around field: AXUIElement) -> LoginForm? {
        let deadline = Date().addingTimeInterval(formTime)
        var part = field
        for _ in 0..<formLevels {
            guard let parent = element(part, kAXParentAttribute) else { return nil }
            part = parent
            var budget = formFields
            var fields: [(element: AXUIElement, isSecure: Bool)] = []
            guard collectTextFields(under: part, into: &fields, budget: &budget, deadline: deadline) else { return nil }
            let loginFields = fields.filter { codeKind($0.element) == .other }
            if let cursor = loginFields.firstIndex(where: { CFEqual($0.element, field) }),
               let pair = LoginFormFields.pair(isSecure: loginFields.map(\.isSecure), cursor: cursor) {
                var form = LoginForm(username: loginFields[pair.username].element, password: loginFields[pair.password].element)
                if let page = formPage(form) {
                    let codes = fields.map(\.element).filter {
                        isVerificationCode($0) && page.matches(webArea(above: $0), equal: { CFEqual($0, $1) })
                    }
                    if codes.count == 1 { form.verificationCode = codes[0] }
                }
                return form
            }
            // The form is a part of one page and of one window.
            let role = text(part, kAXRoleAttribute)
            if role == "AXWebArea" || role == (kAXWindowRole as String) { return nil }
        }
        return nil
    }

    private static func isVerificationCode(_ field: AXUIElement) -> Bool {
        codeKind(field) == .verification
    }

    private static func codeKind(_ field: AXUIElement) -> VerificationCodeField.Kind {
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            .compactMap { text(field, $0) }
        if let label = element(field, kAXTitleUIElementAttribute),
           text(label, kAXRoleAttribute) == (kAXStaticTextRole as String),
           let title = text(label, kAXValueAttribute) {
            labels.append(title)
        }
        return VerificationCodeField.classify(identifier: text(field, "AXDOMIdentifier") ?? text(field, kAXIdentifierAttribute),
                                              labels: labels)
    }

    /// The text fields under an element, in the order of the tree. false when the look ended
    /// before the part was read whole: it is larger than the search may be, the app answers too
    /// slowly, or, with `untilPair`, a hidden field with an open one before it was reached.
    private static func collectTextFields(under element: AXUIElement, into fields: inout [(element: AXUIElement, isSecure: Bool)],
                                          budget: inout Int, deadline: Date, untilPair: Bool = false) -> Bool {
        budget -= 1
        guard budget >= 0, Date() < deadline else { return false }
        if text(element, kAXRoleAttribute) == (kAXTextFieldRole as String) {
            // Only a field that a value can be set in: one that is turned off is no part of the pair.
            var canBeSet = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &canBeSet) == .success, canBeSet.boolValue {
                let isSecure = text(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
                let hasOpenBefore = fields.contains { !$0.isSecure }
                fields.append((element, isSecure))
                if untilPair, isSecure, hasOpenBefore, !isVerificationCode(element) { return false }
            }
            return true
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return true }
        for child in children where !collectTextFields(under: child, into: &fields, budget: &budget, deadline: deadline, untilPair: untilPair) {
            return false
        }
        return true
    }

    // MARK: Accessibility

    /// The app the user works in. Not PassVault, whose own fields it fills by itself, and not a
    /// part of the system that asks for a password.
    private static func appInFront() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !systemApps.contains(app.bundleIdentifier ?? "") else { return nil }
        return app
    }

    private static func fieldWithCursor(of processID: pid_t, appName: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, patience)
        var value: CFTypeRef?
        let fromApp = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        if fromApp == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! AXUIElement) }
        // Some browsers tell the field with the cursor only through the element of the whole system.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, patience)
        value = nil
        let fromSystem = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard fromSystem == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            log.notice("field: \(appName, privacy: .public) names no element with the cursor: error \(fromApp.rawValue) from the app, \(fromSystem.rawValue) from the system")
            return nil
        }
        let field = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(field, &owner) == .success, owner == processID else {
            log.notice("field: the element with the cursor belongs to another app than \(appName, privacy: .public)")
            return nil
        }
        return field
    }

    /// A text field, a text area or a combo box that is enabled and whose value can be set.
    private static func takesText(_ field: AXUIElement, appName: String) -> Bool {
        let role = text(field, kAXRoleAttribute) ?? "none"
        guard [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) else {
            let subrole = text(field, kAXSubroleAttribute) ?? "none"
            log.notice("field: the element with the cursor in \(appName, privacy: .public) is no text field: \(role, privacy: .public), \(subrole, privacy: .public)")
            return false
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &value) == .success,
           let isEnabled = value as? Bool, !isEnabled {
            log.notice("field: the \(role, privacy: .public) of \(appName, privacy: .public) is disabled")
            return false
        }
        var canBeSet: DarwinBoolean = false
        let answer = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &canBeSet)
        guard answer == .success, canBeSet.boolValue else {
            log.notice("field: the value of the \(role, privacy: .public) of \(appName, privacy: .public) cannot be set: error \(answer.rawValue)")
            return false
        }
        return true
    }

    /// The address of the web page the field is on: the web area above it tells it in a browser.
    private static func webArea(above field: AXUIElement) -> AXUIElement? {
        var current = field
        for _ in 0..<48 {
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            if text(parent, kAXRoleAttribute) == "AXWebArea" {
                return parent
            }
            current = parent
        }
        return nil
    }

    private static func pageAddress(_ page: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(page, "AXURL" as CFString, &value) == .success else { return nil }
        return (value as? URL)?.absoluteString ?? (value as? String)
    }

    private static func element(_ of: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func text(_ of: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
