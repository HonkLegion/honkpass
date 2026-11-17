import AppKit
import AuthenticationServices
import Engine

/// Lets a browser of the system read a security key for the second step of a log-in: the
/// connector page of the account's server opens in a session of the system, the browser talks
/// to the key, and the page ends at an address the session gives back.
///
/// The reference shows that page in a frame of its own window, which a web view of an app on
/// macOS cannot do for a server the app is not tied to (PLAN.md, differences).
@MainActor
final class WebAuthnSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var window: NSWindow?

    /// Opens the page and returns how it ended. One session at a time: a new one ends the old.
    func read(_ page: URL, over window: NSWindow?) async -> WebAuthnConnector.Outcome {
        session?.cancel()
        self.window = window
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme(WebAuthnConnector.callbackScheme)) { url, _ in
                continuation.resume(returning: url.map(WebAuthnConnector.outcome(ofCallback:)) ?? .failed)
            }
            session.presentationContextProvider = self
            // Nothing of the browser of the user is needed, and nothing is left in it.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { session.cancel() }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow ?? ASPresentationAnchor() }
    }
}
