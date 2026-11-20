import Engine
import Darwin
import Foundation
import Synchronization

/// How PassVault presents itself to the server. The version is the Bitwarden client version
/// whose protocol PassVault implements; servers use it to decide which features to offer.
enum ClientIdentity {
    static let clientName = "desktop"
    static let clientVersion = "2026.10.4"
    /// Bitwarden's device type "macOS Desktop".
    static let deviceType = "7"
    static let deviceName = "HonkPass"
    static let userAgent = "HonkPass"
}

/// HTTP without cookies, caches, stored credentials or redirects.
final class HTTPClient: Sendable {
    private let session: URLSession
    /// The requests that carry a file, up or down. A file may have 500 MB, which can take longer
    /// than the 120 seconds the other requests have in all; these have no such limit, as the
    /// requests of the reference have none. A request that hears nothing for its own
    /// `timeoutInterval` still ends.
    private let files: URLSession

    /// The time a request of a file may take in all: the default of URLSession, seven days.
    static let fileResourceTimeout: TimeInterval = 7 * 24 * 60 * 60

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        // A session keeps a copy of its configuration: the second one differs in the limit only.
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        configuration.timeoutIntervalForResource = Self.fileResourceTimeout
        files = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
        files.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, maximumBytes: Int = 8 * 1_024 * 1_024) async throws -> (data: Data, status: Int) {
        try await perform(session.dataTask(with: request), maximumBytes: maximumBytes)
    }

    /// A request that brings a file, or sends one without telling its progress.
    func sendFile(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let limit = request.httpMethod == "GET" ? Engine.maximumAttachmentBytes + 65_536 : 1_048_576
        return try await perform(files.dataTask(with: request), maximumBytes: limit)
    }

    /// A request whose body is a file and goes as an upload: `progress` hears the bytes of the
    /// body that have gone and the bytes of the whole body, as the session sends them.
    func upload(_ request: URLRequest, body: Data,
                progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (data: Data, status: Int) {
        try await perform(files.uploadTask(with: request, from: body), maximumBytes: 1_048_576, progress: progress)
    }

    private func perform(_ task: URLSessionDataTask, maximumBytes: Int,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> (Data, Int) {
        let started = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                task.delegate = BoundedResponse(limit: maximumBytes, progress: progress, completion: continuation)
                started.withLock { active in
                    active = true
                    task.resume()
                    if Task.isCancelled { task.cancel() }
                }
            }
        } onCancel: {
            started.withLock { if $0 { task.cancel() } }
        }
    }

    /// A request to a path below the server URL, with the headers every request carries.
    static func request(_ method: String, _ server: URL, _ path: String, query: [URLQueryItem] = [],
                        accessToken: String? = nil) throws -> URLRequest {
        guard isAcceptable(server),
              var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw EngineError.server("The server URL is not usable. Public servers need HTTPS.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw EngineError.server("The server URL is not usable.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(ClientIdentity.clientName, forHTTPHeaderField: "Bitwarden-Client-Name")
        request.setValue(ClientIdentity.clientVersion, forHTTPHeaderField: "Bitwarden-Client-Version")
        request.setValue(ClientIdentity.deviceType, forHTTPHeaderField: "Device-Type")
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        return request
    }

    static func jsonRequest(_ method: String, _ server: URL, _ path: String, body: Data,
                            accessToken: String? = nil) throws -> URLRequest {
        var request = try request(method, server, path, accessToken: accessToken)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// HTTPS everywhere. Plain HTTP only for this Mac and names of the local network.
    static func isAcceptable(_ server: URL) -> Bool {
        guard let host = server.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              server.user == nil, server.password == nil, server.query == nil, server.fragment == nil else { return false }
        switch server.scheme?.lowercased() {
        case "https": return true
        case "http": return localHTTPHost(host)
        default: return false
        }
    }

    private static func localHTTPHost(_ host: String) -> Bool {
        guard !host.contains("%") else { return false }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            // inet_aton also accepts historical shorthand, hexadecimal and octal spellings.
            guard inet_pton(AF_INET, host, &ipv4) == 1 else { return false }
            let ip = UInt32(bigEndian: ipv4.s_addr)
            return ip >> 24 == 127 || ip >> 24 == 10 || ip >> 20 == 0xac1
                || ip >> 16 == 0xc0a8 || ip >> 16 == 0xa9fe
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
                    || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
            }
        }
        if host.hasSuffix(".local") { return true }
        return !host.isEmpty && host.utf8.contains { (97...122).contains($0) }
            && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// A short text for a refused request. Server messages are shortened and hold no secret.
    static func refusal(_ data: Data, status: Int) -> EngineError {
        var message = "HTTP \(status)"
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let model = JSON.field(object, "ErrorModel") as? [String: Any]
            let text = (model.flatMap { JSON.field($0, "Message") } as? String)
                ?? (JSON.field(object, "Message") as? String)
                ?? (object["error_description"] as? String)
            if let text, !text.isEmpty { message += ": " + String(text.prefix(200)) }
        }
        return .server(message)
    }
}

/// Bound received chunks even when the server omits Content-Length or compresses the body.
private final class BoundedResponse: NSObject, URLSessionDataDelegate, Sendable {
    private let limit: Int
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let completion: CheckedContinuation<(Data, Int), any Error>
    private let received = Mutex<Data?>(Data())

    init(limit: Int, progress: (@Sendable (Int64, Int64) -> Void)?, completion: CheckedContinuation<(Data, Int), any Error>) {
        self.limit = limit
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(limit) {
            received.withLock { $0 = nil }
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = received.withLock { buffer in
            guard let count = buffer?.count, data.count <= limit - count else { buffer = nil; return false }
            buffer?.append(data)
            return true
        }
        if !accepted { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let data = received.withLock { buffer in let result = buffer; buffer = nil; return result }
        if let data, error == nil, let response = task.response as? HTTPURLResponse {
            completion.resume(returning: (data, response.statusCode))
        } else {
            completion.resume(throwing: data == nil ? EngineError.server("The response exceeds the size limit.") : .serverUnreachable)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum JSON {
    /// A field that servers spell in camelCase or PascalCase. JSON null counts as absent.
    static func field(_ object: [String: Any], _ name: String) -> Any? {
        let camel = name.prefix(1).lowercased() + name.dropFirst()
        let pascal = name.prefix(1).uppercased() + name.dropFirst()
        guard let value = object[camel] ?? object[pascal], !(value is NSNull) else { return nil }
        return value
    }

    static func string(_ object: [String: Any], _ name: String) -> String? {
        field(object, name) as? String
    }

    static func integer(_ object: [String: Any], _ name: String) -> Int? {
        guard let number = field(object, name) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let parts = pairs.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
                + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        return Data(parts.joined(separator: "&").utf8)
    }
}
