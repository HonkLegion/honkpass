import Foundation
import Security

/// The three signed parts of AutoFill and how each knows the others: the app, which holds
/// the engine; the Credential Provider extension, which the system starts; and the launch
/// agent through which the extension finds the app. A part accepts another only by its code
/// signature: the identifier of that part, signed by the team that signed this one. There is
/// no shared secret and no file.
public struct AutoFillPeers: Sendable, Equatable {
    public enum Part: Sendable, CaseIterable {
        case app, provider, agent

        var suffix: String {
            switch self {
            case .app: ""
            case .provider: ".provider"
            case .agent: ".rendezvous"
            }
        }
    }

    public enum Service: Sendable {
        /// Where the app hands in the end of its connection.
        case publish
        /// Where the extension asks for it.
        case lookup
    }

    /// The team that signed this process.
    public let team: String
    /// The bundle identifier of the app; the other parts add to it.
    public let appIdentifier: String

    /// - Throws: `AutoFillBridgeError.notSigned` for a team or an identifier that could not
    ///   stand in a requirement as it is.
    public init(team: String, appIdentifier: String) throws {
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        guard team.count == 10, team.unicodeScalars.allSatisfy(letters.contains),
              !appIdentifier.isEmpty, appIdentifier.count <= 200, !appIdentifier.hasPrefix("."), !appIdentifier.hasSuffix("."),
              appIdentifier.unicodeScalars.allSatisfy({ letters.contains($0) || $0 == "." || $0 == "-" }) else {
            throw AutoFillBridgeError.notSigned
        }
        self.team = team
        self.appIdentifier = appIdentifier
    }

    public func identifier(of part: Part) -> String {
        appIdentifier + part.suffix
    }

    /// What the code signature of a part has to satisfy: signed for Apple's platforms, with
    /// the identifier of that part, by this team.
    public func requirement(for part: Part) -> String {
        "anchor apple generic and identifier \"\(identifier(of: part))\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The name of a service of the agent. It begins with the App Group of the three parts,
    /// which is what lets a process in a sandbox look it up.
    public func service(_ service: Service) -> String {
        "\(team).\(agentLabel)." + (service == .publish ? "publish" : "lookup")
    }

    /// The label of the launch agent and the name of its property list in the app. Neither
    /// this label nor the names of the services are those of HonkPass, whose identifiers
    /// PassVault has: a Mac may still have the agent of HonkPass registered, which speaks
    /// other messages, and the two must never meet.
    public var agentLabel: String { appIdentifier + ".bridge" }
    public var agentPropertyList: String { agentLabel + ".plist" }

    /// The peers of the running process, which has to be this part and has to be signed by a
    /// team: its own signature is read and checked against the requirement it would ask of
    /// another. A process without a team, as a test run, gets none and fails closed.
    public static func current(as part: Part) throws -> AutoFillPeers {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw AutoFillBridgeError.notSigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw AutoFillBridgeError.notSigned }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let facts = information as? [String: Any],
              let team = facts[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = facts[kSecCodeInfoIdentifier as String] as? String,
              identifier.hasSuffix(part.suffix), identifier.count > part.suffix.count else {
            throw AutoFillBridgeError.notSigned
        }
        let peers = try AutoFillPeers(team: team, appIdentifier: String(identifier.dropLast(part.suffix.count)))
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(peers.requirement(for: part) as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw AutoFillBridgeError.notSigned
        }
        return peers
    }
}

public enum AutoFillBridgeError: Error, Sendable, Equatable {
    /// This process is not signed by a team, so it can neither prove what it is nor ask it of another.
    case notSigned
}
