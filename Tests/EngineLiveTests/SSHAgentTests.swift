import CryptoKit
import Darwin
import Engine
@testable import EngineLive
import Foundation
import Testing

/// The SSH agent of the live adapters: the messages, the key of the SDK, and the socket with
/// the SSH tools of the system as its clients. The keys are made here and kept nowhere.
@Suite(.serialized) struct SSHAgentTests {
    /// A stand-in for the engine: it offers one key and signs with it.
    private final class OneKey: SSHAgentRequests, @unchecked Sendable {
        let key: OpenSSHEd25519Key
        let allows: Bool
        private let lock = NSLock()
        private var seen: [SSHSignRequest] = []

        init(_ key: OpenSSHEd25519Key, allows: Bool = true) {
            self.key = key
            self.allows = allows
        }

        var requests: [SSHSignRequest] { lock.withLock { seen } }

        func sshIdentities() async -> [SSHAgentIdentity] {
            [SSHAgentIdentity(itemID: "1", name: "Example SSH Key", publicKeyBlob: key.publicKeyBlob)]
        }

        func sshSignature(for request: SSHSignRequest) async -> Data? {
            lock.withLock { seen.append(request) }
            guard allows, request.publicKeyBlob == key.publicKeyBlob else { return nil }
            return key.signature(over: request.data)
        }
    }

    /// A folder for the socket with a short path: the path of a socket has room for 103 bytes.
    private func makeFolder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/pv-ssh-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Runs a tool of the system with the agent as its only source of keys.
    private func run(_ tool: String, _ arguments: [String], socket: String, input: Data? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["SSH_AUTH_SOCK": socket, "PATH": "/usr/bin:/bin", "HOME": "/var/empty"]
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    @Test func aKeyOfTheSDKIsReadAndItsSignatureHolds() async throws {
        let made = try await BitwardenCrypto().newSSHKey()
        let key = try #require(OpenSSHEd25519Key(privateKeyText: made.privateKey))
        // The public part is the one the vault shows, and its fingerprint the one the SDK names.
        #expect(SSHWire.publicKeyBlob(ofLine: made.publicKey) == key.publicKeyBlob)
        #expect(SSHWire.fingerprint(of: key.publicKeyBlob) == made.fingerprint)

        let data = Data("synthetic data to sign".utf8)
        var signature = SSHReader(try #require(key.signature(over: data)))
        #expect(signature.string(maximum: 64) == Data("ssh-ed25519".utf8))
        let rawSignature = signature.string(maximum: 64)
        let raw = try #require(rawSignature)
        var blob = SSHReader(key.publicKeyBlob)
        _ = blob.string(maximum: 64)
        let rawKey = blob.string(maximum: 32)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(rawKey))
        #expect(publicKey.isValidSignature(raw, for: data) && !publicKey.isValidSignature(raw, for: data + Data([0])))

        // What is no such key is no key: a text, a cut key, a key with another byte.
        #expect(OpenSSHEd25519Key(privateKeyText: "not a key") == nil)
        #expect(OpenSSHEd25519Key(privateKeyText: String(made.privateKey.dropLast(60))) == nil)
        let lines = made.privateKey.split(separator: "\n").map(String.init)
        var damaged = lines
        damaged[2] = String(damaged[2].reversed())
        #expect(OpenSSHEd25519Key(privateKeyText: damaged.joined(separator: "\n")) == nil)
        #expect(SSHWire.publicKeyBlob(ofLine: "ssh-rsa " + key.publicKeyBlob.base64EncodedString()) == nil)
    }

    @Test func theMessagesOfTheAgentAreReadWholeOrNotAtAll() throws {
        let key = Data("key".utf8), data = Data("data".utf8)
        #expect(SSHAgentMessage(body: Data([11])) == .identities)
        #expect(SSHAgentMessage(body: Data([11, 0])) == nil)
        let sign = Data([13]) + SSHWire.string(key) + SSHWire.string(data) + SSHWire.word(0)
        #expect(SSHAgentMessage(body: sign) == .sign(publicKeyBlob: key, data: data, flags: 0))
        #expect(SSHAgentMessage(body: sign.dropLast()) == nil && SSHAgentMessage(body: sign + Data([0])) == nil)
        #expect(SSHAgentMessage(body: Data([13]) + SSHWire.string(key) + SSHWire.string(Data()) + SSHWire.word(0)) == nil)
        // Adding a key, removing all keys, locking the agent: not answered.
        for type: UInt8 in [17, 19, 22, 25] { #expect(SSHAgentMessage(body: Data([type]) + data) == .unsupported) }
        #expect(SSHAgentMessage(body: Data()) == nil)

        let bind = Data([27]) + SSHWire.string(Data("session-bind@openssh.com".utf8)) + SSHWire.string(key)
            + SSHWire.string(Data("session".utf8)) + SSHWire.string(Data("signature".utf8))
        #expect(SSHAgentMessage(body: bind + Data([1])) == .sessionBind(hostKeyBlob: key, sessionID: Data("session".utf8),
                                                                      signature: Data("signature".utf8), isForwarding: true))
        #expect(SSHAgentMessage(body: bind + Data([0])) == .sessionBind(hostKeyBlob: key, sessionID: Data("session".utf8),
                                                                      signature: Data("signature".utf8), isForwarding: false))
        #expect(SSHAgentMessage(body: bind + Data([2])) == nil)
        #expect(SSHAgentMessage(body: bind) == nil)
        #expect(SSHAgentMessage(body: Data([27]) + SSHWire.string(Data("another@example".utf8)) + data) == .unsupported)

        // The answers, and the namespace of a signature that is no log-in.
        #expect(SSHAgentReply.failure == Data([0, 0, 0, 1, 5]) && SSHAgentReply.success == Data([0, 0, 0, 1, 6]))
        let listed = SSHAgentReply.identities([SSHAgentIdentity(itemID: "1", name: "Name", publicKeyBlob: key)])
        #expect(listed == SSHWire.framed(Data([12]) + SSHWire.word(1) + SSHWire.string(key) + SSHWire.string(Data("Name".utf8))))
        #expect(SSHAgentReply.signature(data) == SSHWire.framed(Data([14]) + SSHWire.string(data)))
        #expect(SSHWire.namespace(ofSigned: Data("SSHSIG".utf8) + SSHWire.string(Data("git".utf8)) + data) == "git")
        #expect(SSHWire.namespace(ofSigned: SSHWire.string(Data("session".utf8)) + Data([50])) == nil)
    }

    private func hostProof(_ key: Curve25519.Signing.PrivateKey, session: Data) throws -> (key: Data, signature: Data) {
        let algorithm = SSHWire.string(Data("ssh-ed25519".utf8))
        return (algorithm + SSHWire.string(key.publicKey.rawRepresentation), algorithm + SSHWire.string(try key.signature(for: session)))
    }

    private func authentication(session: Data, key: Data, host: Data? = nil, method: String? = nil) -> Data {
        let method = method ?? (host == nil ? "publickey" : "publickey-hostbound-v00@openssh.com")
        var data = SSHWire.string(session) + Data([50]) + SSHWire.string(Data("synthetic-user".utf8))
        data += SSHWire.string(Data("ssh-connection".utf8)) + SSHWire.string(Data(method.utf8)) + Data([1])
        data += SSHWire.string(Data("ssh-ed25519".utf8)) + SSHWire.string(key)
        if let host { data += SSHWire.string(host) }
        return data
    }

    @Test func aVerifiedHostAuthorizesOnlyItsCompleteAuthenticationPayload() throws {
        let host = Curve25519.Signing.PrivateKey(), session = Data(repeating: 7, count: 32)
        let proof = try hostProof(host, session: session)
        let key = Data("synthetic-client-key".utf8)
        var bindings = SSHSessionBindings()
        let accepted = bindings.bind(hostKey: proof.key, sessionID: session, signature: proof.signature, forwarding: false)
        #expect(accepted)
        for hostbound in [false, true] {
            let payload = authentication(session: session, key: key, host: hostbound ? proof.key : nil)
            let verified = try #require(bindings.verifiedDestination(publicKey: key, data: payload, flags: 0))
            #expect(verified.hostFingerprint == SSHWire.fingerprint(of: proof.key) && verified.data == payload && !verified.isForwarding)
            #expect(bindings.verifiedDestination(publicKey: key, data: payload + Data([0]), flags: 0) == nil)
            #expect(bindings.verifiedDestination(publicKey: key, data: payload.dropLast(), flags: 0) == nil)
            #expect(bindings.verifiedDestination(publicKey: key, data: payload, flags: 1) == nil)
            #expect(bindings.verifiedDestination(publicKey: Data("another-key".utf8), data: payload, flags: 0) == nil)
        }
        let invalid = [
            Data("arbitrary data".utf8), Data("SSHSIG".utf8) + SSHWire.string(Data("git".utf8)),
            authentication(session: Data(repeating: 8, count: 32), key: key),
            authentication(session: session, key: key, host: Data("different-host".utf8)),
            authentication(session: session, key: key, method: "other-authentication"),
        ]
        for payload in invalid { #expect(bindings.verifiedDestination(publicKey: key, data: payload, flags: 0) == nil) }
    }

    @Test func forgedUnsupportedAndReboundSessionsNeverSupplyACachedScope() throws {
        let host = Curve25519.Signing.PrivateKey(), session = Data(repeating: 7, count: 32)
        let proof = try hostProof(host, session: session)
        let key = Data("synthetic-client-key".utf8), payload = authentication(session: session, key: Data("synthetic-client-key".utf8))
        let other = try hostProof(Curve25519.Signing.PrivateKey(), session: session)
        let cases: [(Data, Data, Data)] = [
            (proof.key, session, Data()), (proof.key, session, other.signature), (proof.key, Data(), proof.signature),
            (proof.key, Data(repeating: 8, count: 32), proof.signature), (proof.key + Data([0]), session, proof.signature),
            (proof.key, session, proof.signature + Data([0])),
            (SSHWire.string(Data("ssh-rsa".utf8)) + SSHWire.string(Data("unsupported-key".utf8)), session, proof.signature),
        ]
        for (keyBlob, sessionID, signature) in cases {
            var bindings = SSHSessionBindings()
            let accepted = bindings.bind(hostKey: keyBlob, sessionID: sessionID, signature: signature, forwarding: false)
            #expect(!accepted)
            #expect(bindings.verifiedDestination(publicKey: key, data: payload, flags: 0) == nil)
            // A later valid message cannot revive a rejected chain on the same connection.
            let recovered = bindings.bind(hostKey: proof.key, sessionID: session, signature: proof.signature, forwarding: false)
            #expect(!recovered)
        }
        var forwarded = SSHSessionBindings()
        let firstHop = forwarded.bind(hostKey: proof.key, sessionID: session, signature: proof.signature, forwarding: true)
        #expect(firstHop)
        #expect(forwarded.isForwarding)
        #expect(forwarded.verifiedDestination(publicKey: key, data: payload, flags: 0) == nil)
        var duplicate = forwarded
        let repeated = duplicate.bind(hostKey: proof.key, sessionID: session, signature: proof.signature, forwarding: false)
        #expect(!repeated)
        let finalSession = Data(repeating: 8, count: 32), finalHost = Curve25519.Signing.PrivateKey()
        let finalProof = try hostProof(finalHost, session: finalSession)
        let finalHop = forwarded.bind(hostKey: finalProof.key, sessionID: finalSession, signature: finalProof.signature, forwarding: false)
        #expect(finalHop)
        let finalPayload = authentication(session: finalSession, key: key, host: finalProof.key)
        #expect(forwarded.verifiedDestination(publicKey: key, data: finalPayload, flags: 0)?.isForwarding == true)
        // A final authentication binding is terminal, including when the next proof is valid.
        let afterFinal = forwarded.bind(hostKey: proof.key, sessionID: session, signature: proof.signature, forwarding: true)
        #expect(!afterFinal)
        #expect(forwarded.verifiedDestination(publicKey: key, data: finalPayload, flags: 0) == nil)
        var bounded = SSHSessionBindings()
        for byte: UInt8 in 0..<16 {
            let id = Data(repeating: byte, count: 32), next = try hostProof(host, session: Data(repeating: byte, count: 32))
            let accepted = bounded.bind(hostKey: next.key, sessionID: id, signature: next.signature, forwarding: true)
            #expect(accepted)
        }
        let overflow = try hostProof(host, session: Data(repeating: 16, count: 32))
        let tooMany = bounded.bind(hostKey: overflow.key, sessionID: Data(repeating: 16, count: 32), signature: overflow.signature, forwarding: true)
        #expect(!tooMany)
    }

    private func connect(to path: String) throws -> Int32 {
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw SocketFailure() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(client); throw SocketFailure() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return client
    }

    private struct SocketFailure: Error {}

    private actor WaitingSigner: SSHAgentRequests {
        var isWaiting = false
        var wasCancelled = false
        func sshIdentities() async -> [SSHAgentIdentity] { [] }
        func sshSignature(for request: SSHSignRequest) async -> Data? {
            isWaiting = true
            do { try await Task.sleep(for: .seconds(10)) } catch { wasCancelled = true }
            return nil
        }
    }

    @Test func disconnectingTheClientCancelsItsPendingQuestion() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("agent.sock").path
        let signer = WaitingSigner()
        let agent = UnixSSHAgentSocket(path: path)
        try await agent.start(signer)
        let client = try connect(to: path)
        let body = Data([13]) + SSHWire.string(Data("synthetic key".utf8))
            + SSHWire.string(Data("synthetic data".utf8)) + SSHWire.word(0)
        let frame = SSHWire.framed(body)
        #expect(frame.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) } == frame.count)
        for _ in 0..<200 where !(await signer.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await signer.isWaiting)
        Darwin.close(client)
        for _ in 0..<200 where !(await signer.wasCancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await signer.wasCancelled)
        await agent.stop()
    }

    private func exchange(_ body: Data, with client: Int32) throws -> Data {
        let frame = SSHWire.framed(body)
        let sent = frame.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
        guard sent == frame.count else { throw SocketFailure() }
        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                var buffer = [UInt8](repeating: 0, count: count - result.count)
                let received = Darwin.read(client, &buffer, buffer.count)
                guard received > 0 else { throw SocketFailure() }
                result.append(contentsOf: buffer.prefix(received))
            }
            return result
        }
        let count = try read(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count <= SSHWire.maximumMessageBytes else { throw SocketFailure() }
        return try read(count)
    }

    @Test func theSocketCarriesOnlyVerifiedScopesAndKeepsFreshConsentFallbackAvailable() async throws {
        let key = try #require(OpenSSHEd25519Key(privateKeyText: try await BitwardenCrypto().newSSHKey().privateKey))
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "agent.sock").path, socket = UnixSSHAgentSocket(path: folder.appending(path: "agent.sock").path)
        let engine = OneKey(key)
        try await socket.start(engine)
        let client = try connect(to: path)
        defer { Darwin.close(client) }
        let session = Data(repeating: 7, count: 32), proof = try hostProof(Curve25519.Signing.PrivateKey(), session: Data(repeating: 7, count: 32))
        let bind = Data([27]) + SSHWire.string(Data("session-bind@openssh.com".utf8)) + SSHWire.string(proof.key)
            + SSHWire.string(session) + SSHWire.string(proof.signature) + Data([0])
        #expect(try exchange(bind, with: client) == Data([6]))
        let payload = authentication(session: session, key: key.publicKeyBlob)
        let sign = Data([13]) + SSHWire.string(key.publicKeyBlob) + SSHWire.string(payload) + SSHWire.word(0)
        #expect(try exchange(sign, with: client).first == 14)
        #expect(engine.requests.last?.verifiedDestination?.hostFingerprint == SSHWire.fingerprint(of: proof.key))
        #expect(try exchange(bind, with: client) == Data([5]))
        #expect(try exchange(sign, with: client).first == 14)
        #expect(engine.requests.last?.verifiedDestination == nil)
        let fresh = try connect(to: path)
        defer { Darwin.close(fresh) }
        #expect(try exchange(sign, with: fresh).first == 14)
        #expect(engine.requests.last?.verifiedDestination == nil)
        let unsupported = Data([27]) + SSHWire.string(Data("session-bind@openssh.com".utf8))
            + SSHWire.string(SSHWire.string(Data("ssh-rsa".utf8))) + SSHWire.string(session) + SSHWire.string(Data()) + Data([0])
        #expect(try exchange(unsupported, with: fresh) == Data([5]))
        #expect(try exchange(sign, with: fresh).first == 14)
        #expect(engine.requests.last?.verifiedDestination == nil)
        await socket.stop()
    }

    @Test func theToolsOfTheSystemListTheKeyAndSignWithItThroughTheSocket() async throws {
        let made = try await BitwardenCrypto().newSSHKey()
        let key = try #require(OpenSSHEd25519Key(privateKeyText: made.privateKey))
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "agent.sock").path
        let socket = UnixSSHAgentSocket(path: path)
        let engine = OneKey(key)
        try await socket.start(engine)

        // Only the user can open the socket.
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)

        // `ssh-add -L` lists the key with the name of its item.
        let listed = try run("/usr/bin/ssh-add", ["-L"], socket: path)
        #expect(listed.status == 0)
        #expect(listed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == made.publicKey.split(separator: " ").prefix(2).joined(separator: " ") + " Example SSH Key")
        // The agent takes no key from a client and removes none.
        #expect(try run("/usr/bin/ssh-add", ["-D"], socket: path).status != 0)

        // `ssh-keygen -Y sign` with the public key only: the agent signs, as for a commit of git.
        let publicKeyFile = folder.appending(path: "key.pub"), message = folder.appending(path: "message.txt")
        try Data((made.publicKey + "\n").utf8).write(to: publicKeyFile)
        try Data("synthetic message\n".utf8).write(to: message)
        let signed = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "git", "-U", "-f", publicKeyFile.path, message.path], socket: path)
        #expect(signed.status == 0, "\(signed.output)")
        // The tool checks the signature against the public key.
        let signers = folder.appending(path: "signers")
        try Data(("user@example.test " + made.publicKey + "\n").utf8).write(to: signers)
        let verified = try run("/usr/bin/ssh-keygen", ["-Y", "verify", "-n", "git", "-f", signers.path, "-I", "user@example.test",
                                                       "-s", message.path + ".sig"],
                               socket: path, input: Data("synthetic message\n".utf8))
        #expect(verified.status == 0, "\(verified.output)")
        // The engine learned who asked and for what.
        let request = try #require(engine.requests.last)
        #expect(request.namespace == "git" && request.processName == "ssh-keygen" && !request.isForwarding)
        #expect(request.publicKeyBlob == key.publicKeyBlob && request.flags == 0)

        // A stopped agent leaves no socket, and a client finds none.
        await socket.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try run("/usr/bin/ssh-add", ["-L"], socket: path).status != 0)
    }

    @Test func aRefusalFailsTheToolAndAFileInThePlaceOfTheSocketIsLeftAlone() async throws {
        let made = try await BitwardenCrypto().newSSHKey()
        let key = try #require(OpenSSHEd25519Key(privateKeyText: made.privateKey))
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "agent.sock").path

        // A file that is no socket stays; the agent does not start over it.
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        await #expect(throws: EngineError.self) { try await UnixSSHAgentSocket(path: path).start(OneKey(key)) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("not a socket".utf8))
        try FileManager.default.removeItem(atPath: path)

        // The socket an earlier run left is replaced.
        let first = UnixSSHAgentSocket(path: path)
        try await first.start(OneKey(key))
        let socket = UnixSSHAgentSocket(path: path)
        let engine = OneKey(key, allows: false)
        try await socket.start(engine)
        // The first one must not remove the file of the second when it stops.
        await first.stop()
        #expect(FileManager.default.fileExists(atPath: path))

        let publicKeyFile = folder.appending(path: "key.pub"), message = folder.appending(path: "message.txt")
        try Data((made.publicKey + "\n").utf8).write(to: publicKeyFile)
        try Data("synthetic message\n".utf8).write(to: message)
        let refused = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "file", "-U", "-f", publicKeyFile.path, message.path], socket: path)
        #expect(refused.status != 0 && engine.requests.last?.namespace == "file")
        #expect(!FileManager.default.fileExists(atPath: message.path + ".sig"))
        await socket.stop()
    }
}
