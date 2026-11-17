import AppKit

/// What the command line asks for. Everything here is for development and tests.
struct LaunchOptions {
    /// `--fake-backend`: in-memory fakes with a synthetic account. No server, no SDK calls.
    let usesFakeBackend: Bool
    /// `--two-step`: the fake account has two-step login by authenticator app and by email.
    let fakeAccountHasTwoStep: Bool
    /// `--smoke-test`: run SmokeTest and exit.
    let runsSmokeTest: Bool
    /// `--fill-check`, with `--fake-backend`: fill the login form of the fixture app through the
    /// real Accessibility port and exit (FillCheck.swift).
    let runsFillCheck: Bool
    /// `--scene <name>`: open one screen in a known state, for a picture (Scenes.swift).
    let scene: String?
    /// `--appearance light|dark`
    let appearance: NSAppearance.Name?
    /// `--window-size <width>x<height>`, in points
    let windowSize: NSSize?
    /// `--language en|cs`
    let language: String?
    /// `--product-name <name>`: the name in the texts. A comparison with the reference uses "Bitwarden".
    let productName: String?
    /// `--server <url>`: sets the self-hosted server, as the server dialog does.
    let server: URL?

    /// A test or picture run: it keeps its account in memory and touches nothing of the user.
    /// Every other start is the start of the user, with the stored session.
    var isDevelopmentRun: Bool { usesFakeBackend || runsSmokeTest || scene != nil }

    init(arguments: [String]) {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        usesFakeBackend = arguments.contains("--fake-backend")
        fakeAccountHasTwoStep = arguments.contains("--two-step")
        runsSmokeTest = arguments.contains("--smoke-test")
        runsFillCheck = arguments.contains("--fill-check")
        scene = value("--scene")
        switch value("--appearance") {
        case "dark": appearance = .darkAqua
        case "light": appearance = .aqua
        default: appearance = nil
        }
        if let parts = value("--window-size")?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 {
            windowSize = NSSize(width: parts[0], height: parts[1])
        } else {
            windowSize = nil
        }
        language = value("--language")
        productName = value("--product-name")
        server = value("--server").flatMap(URL.init(string:))
    }

    /// The test account of the development server, from the environment. Never a real account.
    static var testCredentials: (server: URL, email: String, masterPassword: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["PASSVAULT_SMOKE_SERVER"].flatMap(URL.init(string:)),
              let email = environment["PASSVAULT_SMOKE_EMAIL"],
              let password = environment["PASSVAULT_SMOKE_PASSWORD"] else { return nil }
        return (server, email, password)
    }
}
