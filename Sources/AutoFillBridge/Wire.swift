import Foundation
import VaultModel

/// The one call between the extension and the app: a question as data, an answer as data.
@objc protocol AutoFillWire {
    func ask(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
}

/// The app hands the agent the end of its connection.
@objc protocol EndpointPublishing {
    func publish(_ endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void)
}

/// The extension asks the agent for that end.
@objc protocol EndpointLookup {
    func endpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

/// How the questions and the answers are written for the wire: JSON, of a bounded size. Both
/// ends are of one build, so the format has no version.
enum Wire {
    /// More than any question or answer needs; a larger message is not read.
    static let maximumBytes = 64 * 1024

    static func encode<Message: Encodable>(_ message: Message) -> Data? {
        guard let data = try? JSONEncoder().encode(message), data.count <= maximumBytes else { return nil }
        return data
    }

    static func decode<Message: Decodable>(_ type: Message.Type, from data: Data?) -> Message? {
        guard let data, data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// An end of a connection is no value that Swift knows to be safe to hand between threads;
/// the system makes it to be handed on.
struct Endpoint: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
}

/// What answers the questions of the extension: the engine, in the app.
/// Whoever the extension can ask: the client of the bridge, or a test that stands in for the app.
public protocol AutoFillAsking: Sendable {
    func ask(_ request: AutoFillRequest) async -> AutoFillResponse
}

public protocol AutoFillAnswering: Sendable {
    func answer(_ request: AutoFillRequest) async -> AutoFillResponse
}
