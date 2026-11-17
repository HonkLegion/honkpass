import AppKit

// With the start guard on, a start as the user starts the app ends here, before the engine
// exists and before anything of the user is read.
if !LaunchOptions(arguments: CommandLine.arguments).isDevelopmentRun, StartGuard.isOn {
    StartGuard.refuseStart()
}

// AppKit owns the life cycle, so the app decides itself when a window exists.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
