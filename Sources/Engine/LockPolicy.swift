import Foundation

/// When the vault times out. The options are the ones Bitwarden desktop offers.
public enum VaultTimeout: Sendable, Codable, Equatable {
    /// No user activity in PassVault for this many minutes.
    case afterInactivity(minutes: Int)
    case onSystemIdle
    case onSleep
    case onSystemLock
    /// Only a new start of PassVault needs a new unlock.
    case onRestart
    case never
}

public enum TimeoutAction: String, Sendable, Codable {
    case lock, logOut
}

public struct LockPolicy: Sendable, Codable, Equatable {
    public var timeout: VaultTimeout
    public var action: TimeoutAction

    /// The default of Bitwarden desktop (docs/reference/settings-security-*.png).
    public static let `default` = LockPolicy(timeout: .onRestart, action: .lock)

    public init(timeout: VaultTimeout, action: TimeoutAction) {
        self.timeout = timeout
        self.action = action
    }

    /// Whether a system event makes the vault time out under this policy.
    func timesOut(on event: SystemEvent) -> Bool {
        switch (timeout, event) {
        case (.onSystemLock, .screenLocked), (.onSleep, .willSleep), (.onSystemIdle, .systemIdle): true
        default: false
        }
    }
}
