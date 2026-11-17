import CryptoKit
import Engine
import Foundation

// The protocol of the SSH agent (draft-ietf-sshm-ssh-agent), as far as the agent of the
// reference speaks it: the list of keys, a signature, and the note of OpenSSH that says which
// server a client logs in to. Everything else is refused.

/// Reads the values of SSH from a block of bytes. A read past the end fails.
struct SSHReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<(start + count)])
    }

    mutating func byte() -> UInt8? {
        bytes(1)?.first
    }

    mutating func word() -> UInt32? {
        bytes(4)?.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// A value with its length before it.
    mutating func string(maximum: Int) -> Data? {
        guard let length = word(), length <= maximum else { return nil }
        return bytes(Int(length))
    }
}

enum SSHWire {
    /// The largest message the agent reads, as OpenSSH: 256 KiB.
    static let maximumMessageBytes = 256 * 1_024
    static let maximumKeyBytes = 8 * 1_024

    static func word(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func string(_ value: Data) -> Data {
        word(UInt32(value.count)) + value
    }

    /// A message with its length before it, as it goes over the socket.
    static func framed(_ body: Data) -> Data {
        string(body)
    }

    /// The public key of a line as `ssh-keygen` writes it: "ssh-ed25519 AAAA... comment".
    /// nil unless the bytes are a key of the kind the line names.
    static func publicKeyBlob(ofLine line: String) -> Data? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), blob.count <= maximumKeyBytes else { return nil }
        var reader = SSHReader(blob)
        guard reader.string(maximum: 64) == Data(parts[0].utf8) else { return nil }
        return blob
    }

    /// "SHA256:" and the hash of a public key, as SSH shows a fingerprint.
    static func fingerprint(of publicKeyBlob: Data) -> String {
        let hash = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
        return "SHA256:" + hash.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// The namespace of data that `ssh-keygen -Y sign` asks a signature for ("git", "file");
    /// nil for the data of a log-in. PROTOCOL.sshsig: "SSHSIG", then the namespace.
    static func namespace(ofSigned data: Data) -> String? {
        let magic = Data("SSHSIG".utf8)
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return nil }
        var reader = SSHReader(data.dropFirst(magic.count))
        guard let namespace = reader.string(maximum: 1_024) else { return nil }
        return String(data: namespace, encoding: .utf8)
    }
}

/// What an SSH client asks of the agent.
enum SSHAgentMessage: Equatable {
    case identities
    case sign(publicKeyBlob: Data, data: Data, flags: UInt32)
    /// "session-bind@openssh.com": the key of the server a client logs in to, and whether the
    /// agent is used from another machine.
    case sessionBind(hostKeyBlob: Data, sessionID: Data, signature: Data, isForwarding: Bool)
    /// A message the agent does not answer: adding and removing keys, locking, other notes.
    case unsupported

    /// nil for a message that is not whole; the connection is then closed.
    init?(body: Data) {
        var reader = SSHReader(body)
        guard let type = reader.byte() else { return nil }
        switch type {
        case 11:
            guard reader.remaining == 0 else { return nil }
            self = .identities
        case 13:
            guard let key = reader.string(maximum: SSHWire.maximumKeyBytes), let data = reader.string(maximum: SSHWire.maximumMessageBytes),
                  let flags = reader.word(), reader.remaining == 0, !data.isEmpty else { return nil }
            self = .sign(publicKeyBlob: key, data: data, flags: flags)
        case 27:
            guard let name = reader.string(maximum: 256) else { return nil }
            guard name == Data("session-bind@openssh.com".utf8) else {
                self = .unsupported
                return
            }
            guard let hostKey = reader.string(maximum: SSHWire.maximumKeyBytes), let sessionID = reader.string(maximum: 1_024),
                  let signature = reader.string(maximum: SSHWire.maximumKeyBytes), let forwarding = reader.byte(),
                  forwarding <= 1, reader.remaining == 0 else { return nil }
            self = .sessionBind(hostKeyBlob: hostKey, sessionID: sessionID, signature: signature, isForwarding: forwarding == 1)
        default:
            self = .unsupported
        }
    }
}

/// Connection-local OpenSSH session bindings. Only Ed25519 host proofs are supported.
/// Unsupported or invalid proofs leave signing available with fresh consent, but no cached
/// authorization can be selected. The forwarding bit is a client claim, not a signed fact.
struct SSHSessionBindings {
    private struct Binding {
        let hostKey: Data
        let sessionID: Data
    }

    private var sessions: Set<Data> = []
    private var destination: Binding?
    private var failed = false
    private(set) var isForwarding = false

    mutating func bind(hostKey: Data, sessionID: Data, signature: Data, forwarding: Bool) -> Bool {
        isForwarding = isForwarding || forwarding
        guard !failed, destination == nil, sessions.count < 16, !sessions.contains(sessionID), !sessionID.isEmpty,
              Self.verifies(hostKey: hostKey, sessionID: sessionID, signature: signature) else {
            // A rejected rebind cannot leave an earlier host usable as an authorization scope.
            failed = true
            destination = nil
            return false
        }
        sessions.insert(sessionID)
        if !forwarding { destination = Binding(hostKey: hostKey, sessionID: sessionID) }
        return true
    }

    private static func verifies(hostKey: Data, sessionID: Data, signature: Data) -> Bool {
        var key = SSHReader(hostKey), signed = SSHReader(signature)
        let algorithm = Data("ssh-ed25519".utf8)
        guard key.string(maximum: 64) == algorithm, let rawKey = key.string(maximum: 32), rawKey.count == 32,
              key.remaining == 0, signed.string(maximum: 64) == algorithm,
              let rawSignature = signed.string(maximum: 64), rawSignature.count == 64, signed.remaining == 0,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else { return false }
        return publicKey.isValidSignature(rawSignature, for: sessionID)
    }

    /// RFC 4252 userauth, including OpenSSH's hostbound variant. The entire payload must
    /// authenticate this key in this verified session; arbitrary data never inherits a host.
    func verifiedDestination(publicKey: Data, data: Data, flags: UInt32) -> SSHVerifiedDestination? {
        guard !failed, let destination, flags == 0 else { return nil }
        var reader = SSHReader(data)
        guard reader.string(maximum: 1_024) == destination.sessionID, reader.byte() == 50,
              let user = reader.string(maximum: 1_024), !user.isEmpty,
              reader.string(maximum: 64) == Data("ssh-connection".utf8),
              let method = reader.string(maximum: 128), reader.byte() == 1,
              reader.string(maximum: 64) == Data("ssh-ed25519".utf8),
              reader.string(maximum: SSHWire.maximumKeyBytes) == publicKey else { return nil }
        if method == Data("publickey-hostbound-v00@openssh.com".utf8) {
            guard reader.string(maximum: SSHWire.maximumKeyBytes) == destination.hostKey else { return nil }
        } else if method != Data("publickey".utf8) {
            return nil
        }
        guard reader.remaining == 0 else { return nil }
        return SSHVerifiedDestination(hostFingerprint: SSHWire.fingerprint(of: destination.hostKey),
                                      publicKeyBlob: publicKey, data: data, isForwarding: isForwarding)
    }
}

/// The answers of the agent, each as it goes over the socket.
enum SSHAgentReply {
    static let failure = SSHWire.framed(Data([5]))
    static let success = SSHWire.framed(Data([6]))

    static func identities(_ identities: [SSHAgentIdentity]) -> Data {
        var body = Data([12]) + SSHWire.word(UInt32(identities.count))
        for identity in identities {
            body += SSHWire.string(identity.publicKeyBlob) + SSHWire.string(Data(identity.name.utf8.prefix(512)))
        }
        return SSHWire.framed(body)
    }

    static func signature(_ signatureBlob: Data) -> Data {
        SSHWire.framed(Data([14]) + SSHWire.string(signatureBlob))
    }
}

/// An Ed25519 key as OpenSSH writes a private key that has no password (PROTOCOL.key). The
/// vault holds its keys in this form; the SDK takes the password off a key when it is added.
struct OpenSSHEd25519Key {
    static let keyType = Data("ssh-ed25519".utf8)
    let publicKeyBlob: Data
    private let seed: Data

    /// nil for anything that is not exactly one such key.
    init?(privateKeyText text: String) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 3, lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----", lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()), data.count <= 32 * 1_024 else { return nil }
        var file = SSHReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        // Cipher "none", key derivation "none" with no options, one key.
        guard file.bytes(magic.count) == magic, file.string(maximum: 64) == Data("none".utf8),
              file.string(maximum: 64) == Data("none".utf8), file.string(maximum: 1_024)?.isEmpty == true, file.word() == 1,
              let publicBlob = file.string(maximum: 128), let privateBlock = file.string(maximum: 32 * 1_024),
              file.remaining == 0, !privateBlock.isEmpty, privateBlock.count % 8 == 0 else { return nil }
        var publicPart = SSHReader(publicBlob)
        guard publicPart.string(maximum: 64) == Self.keyType, let publicKey = publicPart.string(maximum: 32), publicKey.count == 32,
              publicPart.remaining == 0 else { return nil }
        var block = SSHReader(privateBlock)
        // The same number twice, the kind, the public key, then the seed with the public key after it.
        guard let check = block.word(), block.word() == check, block.string(maximum: 64) == Self.keyType,
              block.string(maximum: 32) == publicKey, let privateKey = block.string(maximum: 64), privateKey.count == 64,
              Data(privateKey.suffix(32)) == publicKey, block.string(maximum: 1_024) != nil, block.remaining < 8 else { return nil }
        // The block is filled up with the bytes 1, 2, 3, ...
        for index in 0..<block.remaining {
            guard block.byte() == UInt8(index + 1) else { return nil }
        }
        let seed = Data(privateKey.prefix(32))
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed), key.publicKey.rawRepresentation == publicKey else {
            return nil
        }
        publicKeyBlob = publicBlob
        self.seed = seed
    }

    /// The signature over the data as SSH writes it on the wire. CryptoKit of the system signs;
    /// the signature is checked against the public key before it is given out.
    func signature(over data: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed), let signature = try? key.signature(for: data),
              signature.count == 64, key.publicKey.isValidSignature(signature, for: data) else { return nil }
        return SSHWire.string(Self.keyType) + SSHWire.string(signature)
    }
}
