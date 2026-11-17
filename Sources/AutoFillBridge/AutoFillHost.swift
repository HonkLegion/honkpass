import Foundation
import os
import VaultModel

/// The app's end of AutoFill. It listens on a connection that has no name, accepts the
/// Credential Provider extension by its signature, and hands the end of that connection to the
/// launch agent, where the extension asks for it. A question that comes in goes to the engine;
/// the answer goes back and is kept nowhere here.
public final class AutoFillHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        /// Not started, or stopped.
        case stopped
        /// The app is not signed by a team: it can neither prove itself nor check another.
        case notSigned
        /// The agent did not take the end of the connection: it is not registered, not
        /// allowed by the user, or does not start.
        case agentUnavailable
        /// The extension can find the app.
        case ready
    }

    private static let maximumConnections = 16
    private static let patience: Duration = .seconds(5)
    private static let log = Logger(subsystem: "PassVault", category: "autofill")

    private let answering: any AutoFillAnswering
    /// nil only in a test, which runs unsigned and checks nobody.
    private let peers: AutoFillPeers?
    private let lock = NSLock()
    private var listener: NSXPCListener?
    private var agent: NSXPCConnection?
    private var connections = 0
    private var state = Status.stopped
    /// Counts the starts, so that an older one that ends late changes nothing.
    private var turn = 0

    /// Whether the extension can find the app now.
    public var status: Status {
        lock.withLock { state }
    }

    public init(answering: any AutoFillAnswering, peers: AutoFillPeers) {
        self.answering = answering
        self.peers = peers
    }

    /// A host that checks no signature and uses no agent: for the tests of the wire.
    init(uncheckedAnswering answering: any AutoFillAnswering) {
        self.answering = answering
        peers = nil
    }

    /// Starts listening and hands the end of the connection to the agent.
    @discardableResult
    public func start() async -> Status {
        stop()
        let listener = NSXPCListener.anonymous()
        if let peers { listener.setConnectionCodeSigningRequirement(peers.requirement(for: .provider)) }
        listener.delegate = self
        listener.resume()
        let turn = lock.withLock { () -> Int in
            self.listener = listener
            self.turn += 1
            return self.turn
        }
        let result = if let peers { await publish(Endpoint(value: listener.endpoint), peers: peers) } else { Status.ready }
        return lock.withLock {
            if self.turn == turn { state = result }
            return state
        }
    }

    public func stop() {
        let (listener, agent) = lock.withLock { () -> (NSXPCListener?, NSXPCConnection?) in
            defer {
                self.listener = nil
                self.agent = nil
                state = .stopped
                turn += 1
            }
            return (self.listener, self.agent)
        }
        // The agent drops the end when the connection that handed it in goes away.
        agent?.invalidate()
        listener?.invalidate()
    }

    /// The end of the listening connection, for a test that connects to it directly.
    var endpoint: NSXPCListenerEndpoint? {
        lock.withLock { listener?.endpoint }
    }

    private func publish(_ endpoint: Endpoint, peers: AutoFillPeers) async -> Status {
        let connection = NSXPCConnection(machServiceName: peers.service(.publish), options: [])
        connection.setCodeSigningRequirement(peers.requirement(for: .agent))
        connection.remoteObjectInterface = NSXPCInterface(with: EndpointPublishing.self)
        let name = ObjectIdentifier(connection)
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            Task { await self.handInAgain(endpoint, overConnection: name) }
        }
        connection.resume()
        lock.withLock { agent = connection }
        let accepted = await handIn(endpoint, over: connection)
        if !accepted {
            connection.invalidate()
            lock.withLock { if agent === connection { agent = nil } }
        }
        return accepted ? .ready : .agentUnavailable
    }

    private func handIn(_ endpoint: Endpoint, over connection: NSXPCConnection) async -> Bool {
        await Once.value(orAfter: Self.patience, false) { (once: Once<Bool>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) } as? any EndpointPublishing
            guard let proxy else { return once.resume(false) }
            proxy.publish(endpoint.value) { once.resume($0) }
        }
    }

    /// The agent ended, and what it held went with it. The system starts it again for the
    /// next message, which hands the end in once more. This is tried once for each time the
    /// agent had the end: an agent that ends again at once is left alone until the next start.
    private func handInAgain(_ endpoint: Endpoint, overConnection name: ObjectIdentifier) async {
        let current = lock.withLock { () -> (turn: Int, connection: NSXPCConnection)? in
            guard let agent, ObjectIdentifier(agent) == name, state == .ready else { return nil }
            state = .agentUnavailable
            return (turn, agent)
        }
        guard let (turn, connection) = current else { return }
        let accepted = await handIn(endpoint, over: connection)
        Self.log.info("The agent ended and was started again; it took the end of the connection: \(accepted, privacy: .public)")
        lock.withLock {
            guard self.turn == turn, agent === connection else { return }
            if accepted {
                state = .ready
            } else {
                agent = nil
                connection.invalidate()
            }
        }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The same user, and not more callers at once than the system ever starts.
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        let hasRoom = lock.withLock { () -> Bool in
            guard connections < Self.maximumConnections else { return false }
            connections += 1
            return true
        }
        guard hasRoom else { return false }
        connection.exportedInterface = NSXPCInterface(with: AutoFillWire.self)
        connection.exportedObject = Answerer(answering: answering)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connections -= 1 }
        }
        connection.resume()
        return true
    }
}

/// The object the extension talks to: it reads a question, asks the engine and writes the answer.
private final class Answerer: NSObject, AutoFillWire, Sendable {
    private let answering: any AutoFillAnswering

    init(answering: any AutoFillAnswering) {
        self.answering = answering
    }

    func ask(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let question = Wire.decode(AutoFillRequest.self, from: request) else { return reply(nil) }
        let answering = answering
        Task { reply(Wire.encode(await answering.answer(question))) }
    }
}

/// One answer for one waiting caller, whoever brings it first: the reply, the error of the
/// connection, or the end of the patience.
final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    private init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    /// Runs `start`, which answers through the `Once` it is given, and returns that answer, or
    /// `fallback` when none came in time.
    static func value(orAfter patience: Duration, _ fallback: Value, _ start: (Once<Value>) -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task {
                try? await Task.sleep(for: patience)
                once.resume(fallback)
            }
            start(once)
        }
    }
}
