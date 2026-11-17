import Darwin
import Engine
import Foundation
import Synchronization

/// The socket of the SSH agent: a file in the home folder of the user that SSH clients find
/// by `SSH_AUTH_SOCK`. Only the user can open it. It speaks the protocol of the agent and
/// brings every question to the engine; it holds no key and decides nothing.
///
/// Source: desktop_native/ssh_agent/src/server of the reference (listener/unix.rs, connection.rs,
/// peer_info.rs), with the socket code of HonkPass (`SSHAgentSocketListener`).
public final class UnixSSHAgentSocket: SSHAgentPort {
    /// As the reference names its socket in the home folder, after PassVault.
    public static var defaultPath: String { NSHomeDirectory() + "/.passvault-ssh-agent.sock" }

    private struct Running {
        var generation = 0
        var listener: Int32 = -1
        /// The file this process made, so that it removes no other one.
        var file: (device: dev_t, inode: ino_t)?
        var clients: Set<Int32> = []
    }

    private let path: String
    private let state = Mutex(Running())
    /// How many SSH clients are served at once; one more is turned away.
    private static let maximumClients = 16
    /// A client that sends nothing for so long is let go.
    private static let idleSeconds = 600.0

    public init(path: String = UnixSSHAgentSocket.defaultPath) {
        self.path = path
    }

    deinit {
        close(generation: nil)
    }

    public func start(_ requests: any SSHAgentRequests) async throws {
        close(generation: nil)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // The path of a socket has room for 103 bytes.
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineError.unexpected("The path of the SSH agent socket is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        // What an earlier run left is removed, when it is a socket of the user; another file is not touched.
        var found = stat()
        if lstat(path, &found) == 0 {
            guard found.st_mode & S_IFMT == S_IFSOCK, found.st_uid == getuid() else {
                throw EngineError.unexpected("A file that is no socket of the user is in the place of the SSH agent socket.")
            }
            unlink(path)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw EngineError.unexpected("The SSH agent socket could not be made.") }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Nobody connects before `listen`, and by then only the user can.
        guard bound == 0, chmod(path, 0o600) == 0, lstat(path, &found) == 0, listen(listener, 8) == 0 else {
            Darwin.close(listener)
            if bound == 0 { unlink(path) }
            throw EngineError.unexpected("The SSH agent socket could not be opened.")
        }
        let generation = state.withLock { running in
            running.generation += 1
            running.listener = listener
            running.file = (found.st_dev, found.st_ino)
            return running.generation
        }
        Thread.detachNewThread { [weak self] in
            self?.accept(on: listener, generation: generation, requests: requests)
        }
    }

    public func stop() async {
        close(generation: nil)
    }

    /// Closes the socket and lets every client go. With a generation, only if it is still that one.
    private func close(generation: Int?) {
        let (listener, file, clients) = state.withLock { running -> (Int32, (device: dev_t, inode: ino_t)?, Set<Int32>) in
            guard generation == nil || generation == running.generation, running.listener >= 0 else { return (-1, nil, []) }
            let old = (running.listener, running.file, running.clients)
            running.generation += 1
            running.listener = -1
            running.file = nil
            running.clients = []
            return old
        }
        guard listener >= 0 else { return }
        // The file is removed only while it is the one made here.
        var found = stat()
        if let file, lstat(path, &found) == 0, found.st_dev == file.device, found.st_ino == file.inode { unlink(path) }
        Darwin.close(listener)
        // A served client wakes up from its read and ends; its thread closes the socket.
        for client in clients { shutdown(client, SHUT_RDWR) }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    // MARK: Clients

    private func accept(on listener: Int32, generation: Int, requests: any SSHAgentRequests) {
        while isCurrent(generation) {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            guard ready >= 0 || errno == EINTR else { break }
            guard ready > 0 else { continue }
            guard descriptor.revents & Int16(POLLIN) != 0 else { break }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let isTaken = state.withLock { running -> Bool in
                guard running.generation == generation, running.clients.count < Self.maximumClients else { return false }
                running.clients.insert(client)
                return true
            }
            guard isTaken else {
                Darwin.close(client)
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.serve(client, generation: generation, requests: requests)
                // Out of the set first: after the close the number may name another socket.
                self?.state.withLock { _ = $0.clients.remove(client) }
                Darwin.close(client)
            }
        }
    }

    /// One SSH client: its messages in their order, each answered before the next is read.
    private func serve(_ client: Int32, generation: Int, requests: any SSHAgentRequests) {
        // The file lets only the user in; the system says the same of the process at the other end.
        var user: uid_t = 0, group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else { return }
        let process = Self.processContext(ofPeerOf: client)
        var bindings = SSHSessionBindings()
        var buffer = Data()
        while isCurrent(generation) {
            guard let body = readMessage(from: client, buffer: &buffer, generation: generation),
                  let message = SSHAgentMessage(body: body) else { return }
            let reply: Data
            switch message {
            case .identities:
                reply = SSHAgentReply.identities(Self.wait { await requests.sshIdentities() })
            case .sign(let publicKeyBlob, let data, let flags):
                let request = SSHSignRequest(publicKeyBlob: publicKeyBlob, data: data, flags: flags, processName: process.name,
                                             isForwarding: bindings.isForwarding, namespace: SSHWire.namespace(ofSigned: data),
                                             verifiedDestination: bindings.verifiedDestination(publicKey: publicKeyBlob, data: data, flags: flags),
                                             requesterApplicationURL: process.applicationURL)
                reply = waitForSignature(client: client, generation: generation) {
                    await requests.sshSignature(for: request)
                }.map(SSHAgentReply.signature) ?? SSHAgentReply.failure
            case .sessionBind(let hostKeyBlob, let sessionID, let signature, let forwarding):
                reply = bindings.bind(hostKey: hostKeyBlob, sessionID: sessionID, signature: signature, forwarding: forwarding)
                    ? SSHAgentReply.success : SSHAgentReply.failure
            case .unsupported:
                reply = SSHAgentReply.failure
            }
            guard isCurrent(generation), write(reply, to: client) else { return }
        }
    }

    /// The next whole message; nil when the client is gone, idle too long, or sends a message
    /// that is too large.
    private func readMessage(from client: Int32, buffer: inout Data, generation: Int) -> Data? {
        var idle = 0.0
        while true {
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= SSHWire.maximumMessageBytes else { return nil }
                if buffer.count >= 4 + length {
                    let body = Data(buffer.dropFirst(4).prefix(length))
                    buffer = Data(buffer.dropFirst(4 + length))
                    return body
                }
            }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            guard isCurrent(generation), ready >= 0 || errno == EINTR else { return nil }
            guard ready > 0 else {
                idle += 0.25
                if idle >= Self.idleSeconds { return nil }
                continue
            }
            idle = 0
            var chunk = [UInt8](repeating: 0, count: 16 * 1_024)
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    private func write(_ data: Data, to client: Int32) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { bytes in
            while sent < data.count {
                let count = Darwin.write(client, bytes.baseAddress! + sent, data.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    /// Public display metadata from the exact local peer. Never infer an application from its name or parent process.
    private static func processContext(ofPeerOf client: Int32) -> (name: String, applicationURL: URL?) {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return ("", nil) }
        var name = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &name, UInt32(name.count))
        let processName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as four times MAXPATHLEN.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return (processName, nil) }
        var url = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" { return (processName, url) }
            url.deleteLastPathComponent()
        }
        return (processName, nil)
    }

    /// Waits on a thread of its own for an answer of the engine.
    private func waitForSignature(client: Int32, generation: Int,
                                  question: @escaping @Sendable () async -> Data?) -> Data? {
        let answer = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            let value = await question()
            answer.withLock { $0 = value }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            var byte: UInt8 = 0
            let closed = ready > 0 && (descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
                || recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0)
            if !isCurrent(generation) || closed || (ready < 0 && errno != EINTR) {
                task.cancel()
                return nil
            }
        }
        return answer.withLock { $0 }
    }

    private static func wait<Answer: Sendable>(_ question: @escaping @Sendable () async -> Answer) -> Answer {
        let answer = Mutex<Answer?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let value = await question()
            answer.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        return answer.withLock { $0! }
    }
}
