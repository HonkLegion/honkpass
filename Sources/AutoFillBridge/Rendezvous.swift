import Foundation

/// What the launch agent keeps: the end of one connection, and who handed it in. It is all
/// the agent knows; no question, no answer and no login passes through it.
final class EndpointRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (endpoint: Endpoint, owner: UUID)?

    /// The newest end takes the place of the one before: the app was started again.
    func publish(_ endpoint: Endpoint, owner: UUID) {
        lock.withLock { held = (endpoint, owner) }
    }

    /// The connection of an owner is gone. Its end goes with it, unless a newer one has
    /// taken its place.
    func withdraw(owner: UUID) {
        lock.withLock { if held?.owner == owner { held = nil } }
    }

    var endpoint: Endpoint? {
        lock.withLock { held?.endpoint }
    }
}

/// The launch agent between the app and the extension. The extension runs in a sandbox and
/// can look up only a service whose name begins with the App Group; the agent offers two
/// such services: one where the app hands in the end of its connection, one where the
/// extension asks for it. Each service accepts only the part it is for, by its signature.
public final class AutoFillRendezvousAgent: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let publishing: NSXPCListener
    private let lookup: NSXPCListener
    private let relay = EndpointRelay()

    /// - Throws: `AutoFillBridgeError.notSigned` when this process is not the signed agent.
    public override init() {
        fatalError("use init(verified:)")
    }

    public init(verified: Void) throws {
        let peers = try AutoFillPeers.current(as: .agent)
        publishing = NSXPCListener(machServiceName: peers.service(.publish))
        lookup = NSXPCListener(machServiceName: peers.service(.lookup))
        super.init()
        publishing.setConnectionCodeSigningRequirement(peers.requirement(for: .app))
        lookup.setConnectionCodeSigningRequirement(peers.requirement(for: .provider))
        publishing.delegate = self
        lookup.delegate = self
    }

    public func activate() {
        publishing.resume()
        lookup.resume()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        if listener === publishing {
            let owner = UUID()
            let relay = relay
            connection.exportedInterface = NSXPCInterface(with: EndpointPublishing.self)
            connection.exportedObject = Publisher(relay: relay, owner: owner)
            connection.invalidationHandler = { relay.withdraw(owner: owner) }
        } else if listener === lookup {
            connection.exportedInterface = NSXPCInterface(with: EndpointLookup.self)
            connection.exportedObject = Lookup(relay: relay)
        } else {
            return false
        }
        connection.resume()
        return true
    }
}

private final class Publisher: NSObject, EndpointPublishing, Sendable {
    private let relay: EndpointRelay
    private let owner: UUID

    init(relay: EndpointRelay, owner: UUID) {
        self.relay = relay
        self.owner = owner
    }

    func publish(_ endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void) {
        relay.publish(Endpoint(value: endpoint), owner: owner)
        reply(true)
    }
}

private final class Lookup: NSObject, EndpointLookup, Sendable {
    private let relay: EndpointRelay

    init(relay: EndpointRelay) {
        self.relay = relay
    }

    func endpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        reply(relay.endpoint?.value)
    }
}
