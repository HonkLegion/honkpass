import Engine
import Foundation
import VaultModel

/// Reads the answer of `identity/connect/token` for a password log-in, with or without a second step.
enum TokenResponse {
    /// - Parameter sentCode: the request carried a code for the second step, so a refusal
    ///   without another reason means that the code was wrong.
    static func outcome(from data: Data, status: Int, prelogin: Prelogin, sentCode: Bool) throws -> LoginOutcome {
        guard data.count <= 1_048_576 else { throw EngineError.server("The log-in answer is too large.") }
        if status == 400, let challenge = twoStepChallenge(data) { return .needsTwoStep(challenge) }
        guard status == 200 else {
            let error = failure(data, status: status)
            // Vaultwarden names a wrong code only in a message ("Invalid TOTP code", "Token is invalid").
            if sentCode, status == 400, case .server = error { throw EngineError.invalidTwoStepCode }
            throw error
        }
        return .granted(try grant(from: data, prelogin: prelogin))
    }

    /// The answer "two factor required": the methods of the account that PassVault can use.
    /// `TwoFactorProviders2` maps the number of each method to its details; 0 is the
    /// authenticator app and 1 is email, with the address as the server shows it.
    private static func twoStepChallenge(_ data: Data) -> TwoStepChallenge? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var numbers: [Int] = []
        var emailHint: String?
        var webAuthnRequest: String?
        if let details = JSON.field(object, "TwoFactorProviders2") as? [String: Any] {
            numbers = details.keys.compactMap(Int.init)
            if let email = details["1"] as? [String: Any] { emailHint = JSON.string(email, "Email") }
            // 7 is WebAuthn, with what a security key is to sign: the challenge and the keys the
            // account has. The connector page of the server takes it as it came.
            if let request = details["7"] as? [String: Any], request["challenge"] is String,
               let json = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) {
                webAuthnRequest = String(decoding: json, as: UTF8.self)
            }
        } else if let list = JSON.field(object, "TwoFactorProviders") as? [Any] {
            numbers = list.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
        } else {
            return nil
        }
        // The order in which the reference prefers them: a security key, then the
        // authenticator app, then email (the priorities of two-factor.service.ts).
        var methods: [TwoStepMethod] = []
        if numbers.contains(7), webAuthnRequest != nil { methods.append(.webAuthn) }
        if numbers.contains(0) { methods.append(.authenticator) }
        if numbers.contains(1) { methods.append(.email) }
        return TwoStepChallenge(methods: methods, emailHint: emailHint, webAuthnRequest: webAuthnRequest)
    }

    private static func grant(from data: Data, prelogin: Prelogin) throws -> LoginGrant {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = JSON.integer(object, "expires_in"), (1...31_536_000).contains(expiresIn),
              let userID = userID(fromAccessToken: accessToken) else {
            throw EngineError.server("The log-in answer is not readable.")
        }
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rememberToken = JSON.string(object, "TwoFactorToken").flatMap { $0.isEmpty ? nil : $0 }
        return LoginGrant(userID: userID, accessToken: accessToken, refreshToken: refreshToken,
                          expiresIn: TimeInterval(expiresIn), crypto: try cryptoMaterial(object, prelogin: prelogin),
                          twoStepRememberToken: rememberToken)
    }

    /// The wrapped user key with its derivation settings, and the wrapped account keys.
    private static func cryptoMaterial(_ object: [String: Any], prelogin: Prelogin) throws -> AccountCryptoMaterial {
        let unreadable = EngineError.server("The log-in answer has no usable account keys.")
        var kdf = prelogin.kdf
        var salt = prelogin.salt
        var wrappedUserKey = JSON.string(object, "Key")
        var userKeyID: String?

        // Newer servers describe the master password unlock explicitly. Prefer it.
        if let options = JSON.field(object, "UserDecryptionOptions") as? [String: Any],
           let unlock = JSON.field(options, "MasterPasswordUnlock") as? [String: Any] {
            guard let settings = JSON.field(unlock, "Kdf") as? [String: Any],
                  let type = JSON.integer(settings, "KdfType"),
                  let iterations = JSON.integer(settings, "Iterations").flatMap(UInt32.init(exactly:)), iterations > 0,
                  let key = JSON.string(unlock, "MasterKeyEncryptedUserKey"), !key.isEmpty,
                  let unlockSalt = JSON.string(unlock, "Salt") else { throw unreadable }
            switch type {
            case 0:
                kdf = .pbkdf2(iterations: iterations)
            case 1:
                guard let memory = JSON.integer(settings, "Memory").flatMap(UInt32.init(exactly:)), memory > 0,
                      let parallelism = JSON.integer(settings, "Parallelism").flatMap(UInt32.init(exactly:)), parallelism > 0 else {
                    throw unreadable
                }
                kdf = .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
            default:
                throw unreadable
            }
            salt = unlockSalt
            wrappedUserKey = key
            userKeyID = JSON.string(unlock, "ContainedKeyId")
        }
        guard kdf.isSupported(forNetworkLogin: true) else { throw unreadable }
        guard let wrappedUserKey, !wrappedUserKey.isEmpty else { throw unreadable }
        return AccountCryptoMaterial(kdf: kdf, salt: salt, masterKeyWrappedUserKey: wrappedUserKey,
                                     userKeyID: userKeyID, keys: try accountKeys(object, unreadable: unreadable))
    }

    /// Version 2 exactly when the private key is a COSE EncString (type 7). Version 1 has no
    /// signature or security state. Without `AccountKeys`, the top-level `PrivateKey` is version 1.
    private static func accountKeys(_ object: [String: Any], unreadable: EngineError) throws -> AccountKeys {
        guard let keys = JSON.field(object, "AccountKeys") as? [String: Any] else {
            guard let privateKey = JSON.string(object, "PrivateKey"), encStringType(privateKey) == 2 else { throw unreadable }
            return .v1(privateKey: privateKey)
        }
        guard let pair = JSON.field(keys, "PublicKeyEncryptionKeyPair") as? [String: Any],
              let privateKey = JSON.string(pair, "WrappedPrivateKey"), let type = encStringType(privateKey) else { throw unreadable }
        if type == 7 {
            guard let signature = JSON.field(keys, "SignatureKeyPair") as? [String: Any],
                  let security = JSON.field(keys, "SecurityState") as? [String: Any],
                  let signingKey = JSON.string(signature, "WrappedSigningKey"), encStringType(signingKey) == 7,
                  let signedPublicKey = JSON.string(pair, "SignedPublicKey"), !signedPublicKey.isEmpty,
                  let securityState = JSON.string(security, "SecurityState"), !securityState.isEmpty else { throw unreadable }
            return .v2(privateKey: privateKey, signedPublicKey: signedPublicKey, signingKey: signingKey, securityState: securityState)
        }
        guard type == 2 else { throw unreadable }
        return .v1(privateKey: privateKey)
    }

    /// The numeric type prefix of an EncString ("2.iv|data|mac", "7.cose").
    private static func encStringType(_ value: String) -> Int? {
        guard let dot = value.firstIndex(of: "."), value.index(after: dot) < value.endIndex else { return nil }
        return Int(value[..<dot])
    }

    /// This migration accepts only an access token read from the app's protected Keychain.
    static func legacySession(_ token: String, belongsTo account: Account) -> Bool {
        guard let claims = claims(from: token), let subject = claims["sub"] as? String,
              subject.caseInsensitiveCompare(account.id) == .orderedSame,
              let issuer = claims["iss"] as? String else { return false }
        let base = account.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let email = claims["email"] as? String, email.caseInsensitiveCompare(account.email) != .orderedSame { return false }
        return issuer == base + "|login"
    }

    /// The `sub` claim of the access token. The token is not verified here; the server issued it.
    private static func userID(fromAccessToken token: String) -> String? {
        guard let id = claims(from: token)?["sub"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private static func claims(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private static func failure(_ data: Data, status: Int) -> EngineError {
        guard status == 400, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return HTTPClient.refusal(data, status: status)
        }
        // Bitwarden answers with `invalid_grant`. Vaultwarden leaves `error` empty and has only this message.
        let message = (JSON.string(object, "Message") ?? "").lowercased()
        if (object["error"] as? String) == "invalid_grant" || message.contains("username or password is incorrect") {
            return .invalidCredentials
        }
        return HTTPClient.refusal(data, status: status)
    }
}
