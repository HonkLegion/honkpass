import Engine
import Foundation
import Observation

/// Where the user is in the log-in screens. It is view state only: the engine keeps nothing
/// of it until the user sends the master password. The step of the master password asks
/// the server once whether it knows this device for the address.
///
/// The server and the remembered email survive a restart. They are no secrets.
/// PassVault shares its preferences domain with HonkPass, so the keys carry its name.
@MainActor @Observable
final class LogInFlow {
    enum Step {
        case email, masterPassword
        /// "Request password hint", which the link "get master password hint" opens.
        case hint
    }

    var step = Step.email
    var email: String
    var rememberEmail: Bool {
        didSet { rememberEmailIfWanted() }
    }
    /// The self-hosted server. PassVault has no cloud regions.
    var serverURL: URL? {
        didSet { defaults?.set(serverURL?.absoluteString, forKey: Key.server) }
    }
    var isServerDialogOpen = false
    /// The method chosen for the second step of the log-in; nil is the one the reference prefers.
    var twoStepMethod: TwoStepMethod?
    var isTwoStepMethodDialogOpen = false
    /// The second step ended by the user: with a log-in, or by going back. An end by itself
    /// is the engine giving up a log-in that waited too long.
    var twoStepEndedByUser = false

    /// nil in test and picture runs, which must leave no trace in the user's preferences.
    @ObservationIgnored private let defaults: UserDefaults?

    private enum Key {
        static let server = "PassVault.serverURL"
        static let email = "PassVault.rememberedEmail"
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        serverURL = defaults?.string(forKey: Key.server).flatMap(URL.init(string:))
        let remembered = defaults?.string(forKey: Key.email)
        email = remembered ?? ""
        rememberEmail = remembered != nil
    }

    /// The second step is over: the log-in is done, or the window is back at its first screen.
    func twoStepEnded() {
        twoStepEndedByUser = true
        twoStepMethod = nil
        isTwoStepMethodDialogOpen = false
        step = .email
    }

    /// Called when the user leaves the email step.
    func rememberEmailIfWanted() {
        defaults?.set(rememberEmail && !email.isEmpty ? email : nil, forKey: Key.email)
    }
}
