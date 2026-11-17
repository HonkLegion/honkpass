import Foundation

/// A way to give the second step of a log-in that PassVault can use.
public enum TwoStepMethod: String, Sendable, Codable, Hashable, CaseIterable {
    /// A code from an authenticator app.
    case authenticator
    /// A code the server sends to an address of the account.
    case email
    /// A security key or a passkey (FIDO2 WebAuthn). A browser of the system reads it on the
    /// connector page of the account's server; its answer is the code of this method.
    case webAuthn
}

/// What the server asks for after the right master password of an account with two-step login.
public struct TwoStepChallenge: Sendable, Codable, Equatable {
    /// The methods of the account that PassVault can use. Never empty in `EngineState.twoStep`.
    public var methods: [TwoStepMethod]
    /// The address the server sends codes to, as the server shows it: "te*******@example.com".
    public var emailHint: String?
    /// What the server asks a security key to sign, as it sent it: the request of WebAuthn,
    /// in JSON. It holds no secret.
    public var webAuthnRequest: String?

    public init(methods: [TwoStepMethod], emailHint: String? = nil, webAuthnRequest: String? = nil) {
        self.methods = methods
        self.emailHint = emailHint
        self.webAuthnRequest = webAuthnRequest
    }
}

/// The page of the web vault that lets a browser read a security key for an app
/// ("webauthn-mobile-connector.html", which the mobile apps of Bitwarden open the same way):
/// the app opens it in a browser session of the system and takes the answer from the address
/// the page goes to at its end.
public enum WebAuthnConnector {
    /// The page ends at "bitwarden://webauthn-callback". The session of the system takes that
    /// address itself; PassVault does not register the scheme.
    public static let callbackScheme = "bitwarden"
    private static let callbackAddress = "bitwarden://webauthn-callback"

    /// The address of the page for a request of the server, with the texts it shows.
    /// nil for a server that is no web address.
    public static func url(server: URL, request: String, header: String, button: String, returnButton: String) -> URL? {
        guard ["http", "https"].contains(server.scheme?.lowercased() ?? "") else { return nil }
        // The page decodes its texts as parts of an address.
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text }
        let data: [String: Any] = ["callbackUri": callbackAddress, "data": request, "headerText": encoded(header),
                                   "btnText": encoded(button), "btnReturnText": encoded(returnButton)]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              var address = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        var path = address.path
        while path.hasSuffix("/") { path.removeLast() }
        address.path = path + "/webauthn-mobile-connector.html"
        address.fragment = nil
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func query(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        address.percentEncodedQuery = "data=" + query(json.base64EncodedString()) + "&parent=" + query(callbackAddress) + "&v=2"
        return address.url
    }

    /// How the page ended.
    public enum Outcome: Sendable, Equatable {
        /// The answer of the security key: the code of the method.
        case token(String)
        /// The browser read no key: the user gave up, it took too long, or the browser cannot.
        case failed
    }

    /// Reads the address the page went to. Anything but an answer of a key is a failure.
    public static func outcome(ofCallback url: URL) -> Outcome {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "webauthn-callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "data" })?.value, token.utf8.count <= 65_536,
              let object = (try? JSONSerialization.jsonObject(with: Data(token.utf8))) as? [String: Any],
              object["response"] is [String: Any], object["id"] is String else { return .failed }
        return .token(token)
    }
}

/// The second step of a log-in request.
public struct TwoStepProof: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A code of this method.
        case method(TwoStepMethod)
        /// The token the server gave this installation when the user asked not to be asked again.
        case rememberedDevice
    }

    public var kind: Kind
    public var token: String
    /// Ask the server for a token that replaces the second step on this installation for a while.
    public var remember: Bool

    public init(kind: Kind, token: String, remember: Bool) {
        self.kind = kind
        self.token = token
        self.remember = remember
    }
}

/// How the server answers a log-in request with the right master password.
public enum LoginOutcome: Sendable {
    case granted(LoginGrant)
    /// The account has two-step login and the request had no second step the server accepts.
    case needsTwoStep(TwoStepChallenge)
}
