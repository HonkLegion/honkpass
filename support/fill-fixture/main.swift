import AppKit
import WebKit

// A window with a login form, for the check of filling through Accessibility
// (`PassVault --fake-backend --fill-check`, App/PassVault/FillCheck.swift). It stands for an
// app of the user: a field before the form, the user name, the password, and a field after
// it. With `check`, it exits after three consecutive matches or a timeout. Its output
// contains only pass/fail results, never field contents.
//
// Arguments: `password` puts the cursor into the password, `nowhere` into no field; without
// either it is in the user name. `web` shows the form as a web page (WebKit, as in Safari), not
// as fields of AppKit; its output also says how many characters of the page are selected.
// Build: swiftc -o /tmp/PassVaultFillFixture support/fill-fixture/main.swift
final class Fixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
    private let search = NSTextField(frame: NSRect(x: 20, y: 270, width: 380, height: 24))
    private let username = NSTextField(frame: NSRect(x: 20, y: 60, width: 380, height: 24))
    private let password = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 380, height: 24))
    private let note = NSTextField(frame: NSRect(x: 20, y: 30, width: 380, height: 24))
    private var web: WKWebView?
    private let arguments = CommandLine.arguments
    private var successfulChecks = 0
    private var checks = 0
    private var codeID: String {
        arguments.contains("microsoft-code") ? "idTxtBx_SAOTCC_OTC" : (arguments.contains("ambiguous-code") ? "token" : "totp")
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Fixture</title></head><body>
    <h1>Log in</h1>
    <input id="search" type="text" placeholder="Search">
    <form><label>User name <input id="user" type="text"></label>
    <label>Password <input id="password" type="password"></label>
    <label>Verification code <input id="totp" name="totp" type="text" autocomplete="one-time-code" inputmode="numeric"></label>
    <label><input type="checkbox"> Remember this device</label>
    <button type="button">Log in</button></form>
    <p>Forgot the password?</p>
    <input id="note" type="text" placeholder="Note">
    </body></html>
    """

    private static let controlledScript = """
    <script>
    const fields = ['user', 'password', 'totp'];
    const state = Object.fromEntries(fields.map(id => [id, document.getElementById(id).value]));
    fields.forEach(id => document.getElementById(id).addEventListener('input', event => {
        state[id] = event.target.value;
    }));
    setInterval(() => fields.forEach(id => {
        const input = document.getElementById(id);
        if (input.value !== state[id]) input.value = state[id];
    }), 100);
    </script>
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "PassVault fill fixture"
        if arguments.contains("web") {
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
            web.navigationDelegate = self
            window.contentView?.addSubview(web)
            var setup = ""
            if arguments.contains("replace") {
                setup += "document.getElementById('user').value='old-synthetic-user';document.getElementById('password').value='old-synthetic-password';"
            }
            if arguments.contains("redirect") {
                setup += "document.getElementById('password').addEventListener('input', () => document.getElementById('note').focus());"
            }
            if arguments.contains("duplicate-code") {
                setup += "const duplicate=document.createElement('input');duplicate.id='otp';document.querySelector('form').append(duplicate);"
            }
            if arguments.contains("foreign-code") {
                setup += "const other=document.createElement('form');other.append(document.getElementById('totp'));document.body.append(other);"
            }
            var html = Self.page + "<script>\(setup)</script>" + (arguments.contains("controlled") ? Self.controlledScript : "")
            if arguments.contains("microsoft-code") || arguments.contains("ambiguous-code") {
                html = html.replacingOccurrences(of: "Verification code <input", with: "Code <input")
                    .replacingOccurrences(of: "id=\"totp\" name=\"totp\" type=\"text\" autocomplete=\"one-time-code\"",
                                          with: "id=\"\(codeID)\" name=\"\(codeID)\" type=\"tel\" autocomplete=\"off\" maxlength=\"6\"")
                    .replacingOccurrences(of: "'totp'", with: "'\(codeID)'")
            }
            web.loadHTMLString(html,
                               baseURL: URL(string: "https://fixture.example/login"))
            self.web = web
        } else {
            search.placeholderString = "Search"
            username.placeholderString = "User name"
            password.placeholderString = "Password"
            note.placeholderString = "Note"
            // The fields lie in a box, as the fields of a form lie in a part of a window.
            let form = NSBox(frame: NSRect(x: 0, y: 120, width: 420, height: 110))
            form.boxType = .custom
            form.borderWidth = 0
            form.contentView?.addSubview(username)
            form.contentView?.addSubview(password)
            [search, form, note].forEach { window.contentView?.addSubview($0) }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if web == nil { placeCursor() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in report() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            for _ in 0..<100 where !NSApp.isActive || !window.isKeyWindow {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Activation completes asynchronously. Focus after the window is active.
            try? await Task.sleep(for: .milliseconds(100))
            placeCursor()
        }
    }

    private func placeCursor() {
        if let web {
            window.makeFirstResponder(web)
            let field = arguments.contains("code-only") ? codeID : (arguments.contains("password") ? "password" : (arguments.contains("nowhere") ? nil : "user"))
            if let field { web.evaluateJavaScript("document.getElementById('\(field)').focus()") }
        } else if arguments.contains("nowhere") {
            window.makeFirstResponder(nil)
        } else {
            window.makeFirstResponder(arguments.contains("password") ? password : username)
        }
    }

    private func report() {
        if let web {
            let script = "['search','user','password','note','\(codeID)'].map(id => document.getElementById(id).value).concat([String(window.getSelection().toString().length)])"
            web.evaluateJavaScript(script) { result, _ in
                guard let parts = result as? [String], parts.count == 6 else { return }
                self.check(username: parts[1], password: parts[2], code: parts[4],
                           untouched: parts[0].isEmpty && parts[3].isEmpty && parts[5] == "0")
            }
        } else {
            check(username: username.stringValue, password: password.stringValue, code: "",
                  untouched: search.stringValue.isEmpty && note.stringValue.isEmpty)
        }
    }

    private func check(username: String, password: String, code: String, untouched: Bool) {
        let codeOnly = arguments.contains("code-only")
        let withCode = codeOnly || arguments.contains("code")
        let expectedUser = codeOnly ? "" : (withCode ? "demo@passvault.test" : "demo-shopper")
        let expectedPassword = arguments.contains("long")
            ? "synthetic-" + String(repeating: "a", count: 67) + "é👨‍👩‍👧‍👦e\u{301}!"
            : (codeOnly ? "" : (withCode ? "fake-password-item-1" : "fake-password-item-2"))
        let expectedCode = withCode && !arguments.contains("duplicate-code") && !arguments.contains("foreign-code")
            && !arguments.contains("ambiguous-code") ? "123456" : ""
        let passwordMatches = arguments.contains("redirect") ? (!password.isEmpty && expectedPassword.hasPrefix(password)) : password == expectedPassword
        let matches = username == expectedUser && passwordMatches && code == expectedCode && untouched
        successfulChecks = matches ? successfulChecks + 1 : 0
        checks += 1
        if successfulChecks >= 3 && (!arguments.contains("ambiguous-code") || checks >= 6) {
            print("FILL FIXTURE OK: expected values survived three renders; unrelated fields stayed empty")
            fflush(stdout)
            if arguments.contains("check") { exit(0) }
        } else if checks >= 30, arguments.contains("check") {
            print("FILL FIXTURE FAILED: user=\(username == expectedUser) password=\(passwordMatches) code=\(code == expectedCode) untouched=\(untouched)")
            fflush(stdout)
            exit(1)
        }
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.setActivationPolicy(.regular)
app.run()
