import AppKit

/// The start guard. While it is on, the app does not start as the user starts it.
///
/// A run of an agent that controls the Mac turns it on (`make guard`): a tool that looks for
/// PassVault may start the app by itself, and that start would open the stored session of
/// the user. Test and picture runs keep their account in memory and start as before.
enum StartGuard {
    /// The mark of the guard: a file beside the store of the app. `make guard` makes it and
    /// `make guard-off` removes it. The app only looks whether it is there.
    static var mark: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "PassVault", directoryHint: .isDirectory)
            .appending(path: "start-guard", directoryHint: .notDirectory)
    }

    static var isOn: Bool {
        guard let mark else { return false }
        return FileManager.default.fileExists(atPath: mark.path)
    }

    /// Says why the app does not start, and ends it. Nothing of the user was touched: the
    /// engine does not exist yet.
    @MainActor
    static func refuseStart() -> Never {
        FileHandle.standardError.write(Data("HonkPass did not start: the start guard is on (make guard-off).\n".utf8))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "HonkPass did not start"
        alert.informativeText = "The start guard is on, so that a test run cannot open your vault. "
            + "To turn it off, run this in the folder of the HonkPass source: make guard-off"
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(0)
    }
}
