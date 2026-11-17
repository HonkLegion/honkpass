import Foundation
import VaultModel

/// The extension's end of AutoFill. It asks the launch agent where the app listens, connects
/// there, and asks one question. It accepts the agent and the app only by their signatures.
/// Whatever goes wrong on the way is the one answer "unavailable": the extension then offers
/// to open the app.
public final class AutoFillClient: AutoFillAsking, @unchecked Sendable {
    private let peers: AutoFillPeers?
    private let fixedEndpoint: Endpoint?
    private let patience: Duration

    /// - Parameter patience: how long an answer may take. An unlock with a PIN derives a key
    ///   first; the other answers are quick. A request that the system lets wait only for a
    ///   moment, because it shows no window, gets less.
    public init(peers: AutoFillPeers, patience: Duration = .seconds(15)) {
        self.peers = peers
        self.patience = patience
        fixedEndpoint = nil
    }

    /// A client that goes to this end at once and checks no signature: for the tests of the wire.
    init(uncheckedEndpoint endpoint: NSXPCListenerEndpoint) {
        peers = nil
        patience = .seconds(15)
        fixedEndpoint = Endpoint(value: endpoint)
    }

    /// How long the answer to Touch ID may take: the system waits for a person there.
    static let patienceWithAPerson = Duration.seconds(120)

    public func ask(_ request: AutoFillRequest) async -> AutoFillResponse {
        guard let question = Wire.encode(request), let endpoint = await hostEndpoint() else { return .failure(.unavailable) }
        var patience = patience
        if case .unlockWithTouchID = request { patience = max(patience, Self.patienceWithAPerson) }
        let connection = NSXPCConnection(listenerEndpoint: endpoint.value)
        if let peers { connection.setCodeSigningRequirement(peers.requirement(for: .app)) }
        connection.remoteObjectInterface = NSXPCInterface(with: AutoFillWire.self)
        connection.resume()
        defer { connection.invalidate() }
        let answer = await Once.value(orAfter: patience, nil as Data?) { (once: Once<Data?>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? any AutoFillWire
            guard let proxy else { return once.resume(nil) }
            proxy.ask(question) { once.resume($0) }
        }
        return Wire.decode(AutoFillResponse.self, from: answer) ?? .failure(.unavailable)
    }

    /// Where the app listens, by the word of the agent. nil when the agent does not answer or
    /// the app has handed nothing in: it is not running.
    private func hostEndpoint() async -> Endpoint? {
        if let fixedEndpoint { return fixedEndpoint }
        guard let peers else { return nil }
        let connection = NSXPCConnection(machServiceName: peers.service(.lookup), options: [])
        connection.setCodeSigningRequirement(peers.requirement(for: .agent))
        connection.remoteObjectInterface = NSXPCInterface(with: EndpointLookup.self)
        connection.resume()
        defer { connection.invalidate() }
        return await Once.value(orAfter: min(patience, .seconds(5)), nil as Endpoint?) { (once: Once<Endpoint?>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? any EndpointLookup
            guard let proxy else { return once.resume(nil) }
            proxy.endpoint { once.resume($0.map(Endpoint.init(value:))) }
        }
    }
}
