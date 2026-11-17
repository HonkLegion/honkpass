import Foundation
import VaultModel

// The SSH agent. The engine decides which keys are offered and whether one may be used; a port
// listens for the SSH clients of the user, and the crypto port makes the signature, so that a
// private key never leaves it.

/// How the agent asks before a key is used (`SshAgentPromptType` of the reference).
public enum SSHAgentPrompt: String, Sendable, Codable, CaseIterable {
    case always, never, rememberUntilLock
}

public struct SSHAgentSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var prompt: SSHAgentPrompt

    /// The defaults of the reference: off, and "always" once it is on.
    public static let `default` = SSHAgentSettings(isEnabled: false, prompt: .always)

    public init(isEnabled: Bool, prompt: SSHAgentPrompt) {
        self.isEnabled = isEnabled
        self.prompt = prompt
    }
}

/// A key the agent offers: the SSH key of an item, by its public part.
public struct SSHAgentIdentity: Sendable, Codable, Equatable {
    public var itemID: String
    /// The name of the item. SSH clients show it as the comment of the key.
    public var name: String
    /// The public key as SSH writes it on the wire.
    public var publicKeyBlob: Data
    public var publicKeyFingerprint: String?

    public init(itemID: String, name: String, publicKeyBlob: Data, publicKeyFingerprint: String? = nil) {
        self.itemID = itemID
        self.name = name
        self.publicKeyBlob = publicKeyBlob
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

/// What an SSH client asks to be signed, and what the port learned about the asking.
public struct SSHSignRequest: Sendable, Equatable {
    public var publicKeyBlob: Data
    public var data: Data
    /// The flags of the request, which choose the kind of signature of an RSA key.
    public var flags: UInt32
    /// The name of the process at the other end of the socket; empty when it is not known.
    public var processName: String
    /// Display-only application bundle resolved from the local socket peer's executable.
    public var requesterApplicationURL: URL?
    /// The client said that the request comes through an agent forwarded to another machine.
    public var isForwarding: Bool
    /// The namespace of a signature that is no log-in: "git", "file", ...
    public var namespace: String?
    /// An untrusted client claim. It never authorizes remembered use of a key.
    public var hostFingerprint: String?
    public var verifiedDestination: SSHVerifiedDestination?

    public init(publicKeyBlob: Data, data: Data, flags: UInt32 = 0, processName: String = "", isForwarding: Bool = false,
                namespace: String? = nil, hostFingerprint: String? = nil, verifiedDestination: SSHVerifiedDestination? = nil,
                requesterApplicationURL: URL? = nil) {
        self.publicKeyBlob = publicKeyBlob
        self.data = data
        self.flags = flags
        self.processName = processName
        self.requesterApplicationURL = requesterApplicationURL
        self.isForwarding = isForwarding
        self.namespace = namespace
        self.hostFingerprint = hostFingerprint
        self.verifiedDestination = verifiedDestination
    }
}

/// A trusted port's proof that this exact signing request authenticates to a host whose
/// session signature it verified. A client-supplied fingerprint or forwarding flag is no
/// proof. The values bind the proof to the request even if a caller later changes the request.
public struct SSHVerifiedDestination: Sendable, Equatable {
    public let hostFingerprint: String
    public let publicKeyBlob: Data
    public let data: Data
    public let isForwarding: Bool

    public init(hostFingerprint: String, publicKeyBlob: Data, data: Data, isForwarding: Bool) {
        self.hostFingerprint = hostFingerprint
        self.publicKeyBlob = publicKeyBlob
        self.data = data
        self.isForwarding = isForwarding
    }
}

struct SSHAuthorization: Hashable {
    let itemID: String
    let publicKeyBlob: Data
    let hostFingerprint: String
    let isForwarding: Bool

    init?(itemID: String, request: SSHSignRequest) {
        guard let verified = request.verifiedDestination, !verified.hostFingerprint.isEmpty,
              verified.publicKeyBlob == request.publicKeyBlob, verified.data == request.data,
              request.flags == 0, verified.isForwarding == request.isForwarding else { return nil }
        self.itemID = itemID
        publicKeyBlob = request.publicKeyBlob
        hostFingerprint = verified.hostFingerprint
        isForwarding = verified.isForwarding
    }
}

/// The question a client shows before a key is used ("confirm SSH key usage").
public struct SSHApproval: Sendable, Codable, Equatable, Identifiable {
    /// What the key is used for (`sshActionLogin`, `sshActionGitSign`, `sshActionSign`).
    public enum Action: String, Sendable, Codable {
        case logIn, signGit, sign
    }

    public let id: UUID
    public var itemID: String
    public var keyName: String
    public var processName: String
    public var requesterApplicationURL: URL?
    public var action: Action
    public var isForwarding: Bool
    public var publicKeyFingerprint: String?
    public var verifiedHostFingerprint: String?

    public init(id: UUID = UUID(), itemID: String, keyName: String, processName: String, action: Action, isForwarding: Bool,
                publicKeyFingerprint: String? = nil, verifiedHostFingerprint: String? = nil, requesterApplicationURL: URL? = nil) {
        self.id = id
        self.itemID = itemID
        self.keyName = keyName
        self.processName = processName
        self.requesterApplicationURL = requesterApplicationURL
        self.action = action
        self.isForwarding = isForwarding
        self.publicKeyFingerprint = publicKeyFingerprint
        self.verifiedHostFingerprint = verifiedHostFingerprint
    }
}

/// Public process metadata only. A locked vault publishes no item or key data.
public struct SSHUnlockRequest: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let processName: String
    public let requesterApplicationURL: URL?

    public init(id: UUID, processName: String, requesterApplicationURL: URL? = nil) {
        self.id = id
        self.processName = processName
        self.requesterApplicationURL = requesterApplicationURL
    }
}

/// What the port asks of the engine for every SSH client.
public protocol SSHAgentRequests: Sendable {
    func sshIdentities() async -> [SSHAgentIdentity]
    /// The signature as SSH writes it on the wire; nil for a key the agent does not offer, a
    /// refusal of the user, and a vault that stays locked.
    func sshSignature(for request: SSHSignRequest) async -> Data?
}

/// The socket the SSH clients of the user talk to. Only the port knows the protocol of the
/// agent; it brings every question to the engine.
public protocol SSHAgentPort: Sendable {
    /// Throws when the socket cannot be made.
    func start(_ requests: any SSHAgentRequests) async throws
    func stop() async
}

/// No SSH agent: for runs that must leave no socket behind.
public struct NoSSHAgent: SSHAgentPort {
    public init() {}
    public func start(_ requests: any SSHAgentRequests) async throws {}
    public func stop() async {}
}

/// The engine as the port sees it. It does not keep the engine alive.
final class EngineSSHAnswers: SSHAgentRequests, @unchecked Sendable {
    private weak var engine: Engine?

    init(_ engine: Engine) {
        self.engine = engine
    }

    func sshIdentities() async -> [SSHAgentIdentity] {
        await engine?.sshIdentities() ?? []
    }

    func sshSignature(for request: SSHSignRequest) async -> Data? {
        await engine?.sshSignature(for: request)
    }
}
