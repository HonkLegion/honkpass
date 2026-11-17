import AutoFillBridge
import Foundation

// The launch agent of AutoFill, inside PassVault.app. launchd starts it once the app has
// registered it, when the app or the extension looks for one of its services. It hands the end
// of the app's connection to the extension and holds no login, no key and no file.
do {
    let agent = try AutoFillRendezvousAgent(verified: ())
    agent.activate()
    withExtendedLifetime(agent) { RunLoop.current.run() }
} catch {
    // Not the signed agent: it offers nothing. No word of why, to nobody.
    exit(1)
}
