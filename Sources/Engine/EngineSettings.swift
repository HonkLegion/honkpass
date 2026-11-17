import Foundation
import VaultModel

/// When a copied value leaves the clipboard. The options are the ones Bitwarden desktop offers.
public enum ClipboardClearing: Sendable, Codable, Hashable {
    case never
    case after(seconds: Int)
}

/// What the user has set for an account on this Mac. The engine keeps it in the account store,
/// where it survives a logout, and acts on it; clients show it and send a changed copy.
public struct EngineSettings: Sendable, Codable, Equatable {
    public var lockPolicy: LockPolicy
    public var clipboardClearing: ClipboardClearing
    /// Ask the icon service of the server for the pictures of websites.
    public var showsWebsiteIcons: Bool
    /// What the generator was last asked for.
    public var generator: GeneratorOptions
    /// The SSH agent: whether SSH clients can use the keys of the vault, and how it asks.
    public var sshAgent: SSHAgentSettings
    /// "Ask for Touch ID on app start": a client asks for Touch ID by itself when it first
    /// shows the locked vault. The engine only keeps the choice.
    public var asksForBiometricsOnStart: Bool

    /// The defaults of Bitwarden desktop (docs/reference/settings-*.png).
    public static let `default` = EngineSettings(lockPolicy: .default, clipboardClearing: .after(seconds: 300),
                                                 showsWebsiteIcons: true)

    public init(lockPolicy: LockPolicy, clipboardClearing: ClipboardClearing, showsWebsiteIcons: Bool,
                generator: GeneratorOptions = GeneratorOptions(), sshAgent: SSHAgentSettings = .default,
                asksForBiometricsOnStart: Bool = false) {
        self.sshAgent = sshAgent
        self.asksForBiometricsOnStart = asksForBiometricsOnStart
        self.lockPolicy = lockPolicy
        self.clipboardClearing = clipboardClearing
        self.showsWebsiteIcons = showsWebsiteIcons
        self.generator = generator
    }

    /// A file of an older version may lack a setting; it then has its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = EngineSettings.default
        lockPolicy = try container.decodeIfPresent(LockPolicy.self, forKey: .lockPolicy) ?? fallback.lockPolicy
        clipboardClearing = try container.decodeIfPresent(ClipboardClearing.self, forKey: .clipboardClearing)
            ?? fallback.clipboardClearing
        showsWebsiteIcons = try container.decodeIfPresent(Bool.self, forKey: .showsWebsiteIcons) ?? fallback.showsWebsiteIcons
        // Options this version cannot read are the defaults again; they hold no secret and no choice of safety.
        generator = (try? container.decodeIfPresent(GeneratorOptions.self, forKey: .generator)) ?? fallback.generator
        // An agent whose settings cannot be read is off.
        sshAgent = (try? container.decodeIfPresent(SSHAgentSettings.self, forKey: .sshAgent)) ?? fallback.sshAgent
        asksForBiometricsOnStart = (try? container.decodeIfPresent(Bool.self, forKey: .asksForBiometricsOnStart))
            ?? fallback.asksForBiometricsOnStart
    }
}
