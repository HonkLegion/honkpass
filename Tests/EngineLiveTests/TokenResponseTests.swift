import Engine
@testable import EngineLive
import Foundation
import Testing

/// The answers of `identity/connect/token`, without a server. All values are synthetic.
@Suite struct TokenResponseTests {
    let prelogin = Prelogin(kdf: .pbkdf2(iterations: 600_000), salt: "test.user@passvault.test")
    let userID = "11111111-2222-4333-8444-555555555555"

    /// An unsigned token with the claims a server puts into its access token.
    private var accessToken: String {
        let claims = Data(#"{"sub":"\#(userID)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(claims).c2lnbmF0dXJl"
    }

    private func outcome(_ fields: [String: Any], status: Int = 200, sentCode: Bool = false) throws -> LoginOutcome {
        try TokenResponse.outcome(from: JSONSerialization.data(withJSONObject: fields), status: status, prelogin: prelogin,
                                  sentCode: sentCode)
    }

    private func grant(_ fields: [String: Any], status: Int = 200) throws -> LoginGrant {
        guard case .granted(let grant) = try outcome(fields, status: status) else {
            throw EngineError.twoStepLoginRequired
        }
        return grant
    }

    private func challenge(_ fields: [String: Any]) throws -> TwoStepChallenge? {
        if case .needsTwoStep(let challenge) = try outcome(fields, status: 400) { return challenge }
        return nil
    }

    private func failure(_ fields: [String: Any], status: Int) -> EngineError? {
        do {
            _ = try grant(fields, status: status)
            return nil
        } catch {
            return error as? EngineError
        }
    }

    private var success: [String: Any] {
        ["access_token": accessToken, "token_type": "Bearer", "expires_in": 7_200, "refresh_token": "refresh"]
    }

    @Test func readsAnAnswerWithTopLevelKeys() throws {
        var fields = success
        fields["Key"] = "2.wrapped-user-key"
        fields["PrivateKey"] = "2.wrapped-private-key"

        let grant = try grant(fields)
        #expect(grant.userID == userID)
        #expect(grant.expiresIn == 7_200)
        #expect(grant.refreshToken == "refresh")
        #expect(grant.crypto == AccountCryptoMaterial(kdf: prelogin.kdf, salt: prelogin.salt,
                                                      masterKeyWrappedUserKey: "2.wrapped-user-key",
                                                      keys: .v1(privateKey: "2.wrapped-private-key")))
    }

    @Test func prefersTheMasterPasswordUnlockData() throws {
        var fields = success
        fields["Key"] = "2.old-key"
        fields["PrivateKey"] = "2.wrapped-private-key"
        fields["UserDecryptionOptions"] = ["MasterPasswordUnlock": [
            "Kdf": ["KdfType": 1, "Iterations": 3, "Memory": 64, "Parallelism": 4],
            "MasterKeyEncryptedUserKey": "2.new-key", "Salt": "salt-from-server",
        ]]

        let crypto = try grant(fields).crypto
        #expect(crypto.kdf == .argon2id(iterations: 3, memory: 64, parallelism: 4))
        #expect(crypto.salt == "salt-from-server")
        #expect(crypto.masterKeyWrappedUserKey == "2.new-key")
    }

    @Test func readsVersionTwoAccountKeys() throws {
        var fields = success
        fields["key"] = "2.wrapped-user-key"
        fields["accountKeys"] = [
            "publicKeyEncryptionKeyPair": ["wrappedPrivateKey": "7.private", "signedPublicKey": "signed-public"],
            "signatureKeyPair": ["wrappedSigningKey": "7.signing"],
            "securityState": ["securityState": "state"],
        ]

        #expect(try grant(fields).crypto.keys == .v2(privateKey: "7.private", signedPublicKey: "signed-public",
                                                      signingKey: "7.signing", securityState: "state"))
    }

    @Test func anAnswerWithoutAccountKeysIsRefused() {
        #expect(failure(success, status: 200) == .server("The log-in answer has no usable account keys."))
    }

    @Test func aTwoStepChallengeNamesTheUsableMethodsAndTheMaskedAddress() throws {
        // The answer of Vaultwarden 1.37 for an account with an authenticator app, email and a security key.
        let answer: [String: Any] = [
            "error": "invalid_grant", "error_description": "Two factor required.",
            "TwoFactorProviders": ["7", "1", "0"],
            "TwoFactorProviders2": ["0": NSNull(), "1": ["Email": "te**********@passvault.test"], "7": ["challenge": "x"]],
        ]
        // The security key comes first, as the reference prefers it, with what it is to sign as the server sent it.
        #expect(try challenge(answer) == TwoStepChallenge(methods: [.webAuthn, .authenticator, .email],
                                                          emailHint: "te**********@passvault.test",
                                                          webAuthnRequest: #"{"challenge":"x"}"#))
        let request: [String: Any] = ["challenge": "Y2hhbGxlbmdl", "rpId": "localhost", "timeout": 60_000,
                                      "allowCredentials": [["id": "a2V5", "type": "public-key"]], "userVerification": "preferred"]
        let withKey = try challenge(["TwoFactorProviders2": ["7": request]])
        let read = try #require(withKey?.webAuthnRequest)
        let back = try #require(try JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        #expect(back["challenge"] as? String == "Y2hhbGxlbmdl" && back["rpId"] as? String == "localhost")
        #expect((back["allowCredentials"] as? [[String: String]])?.first?["id"] == "a2V5")
        #expect(try challenge(["error": "invalid_grant", "TwoFactorProviders2": ["0": NSNull()]])
            == TwoStepChallenge(methods: [.authenticator]))
        // Older servers list the methods only.
        #expect(try challenge(["TwoFactorProviders": [1]]) == TwoStepChallenge(methods: [.email]))
    }

    @Test func aChallengeWithOtherMethodsOnlyHasNoUsableMethod() throws {
        // A YubiKey code, Duo, and a security key of which the server names no challenge.
        #expect(try challenge(["TwoFactorProviders2": ["7": ["rpId": "x"], "3": ["Nfc": true], "2": NSNull()]])
            == TwoStepChallenge(methods: []))
    }

    @Test func aRefusedCodeIsNamedAsSuch() {
        func error(_ fields: [String: Any], sentCode: Bool) -> EngineError? {
            do {
                _ = try outcome(fields, status: 400, sentCode: sentCode)
                return nil
            } catch {
                return error as? EngineError
            }
        }
        let refusal: [String: Any] = ["error": "", "message": "Invalid TOTP code! Server time: 2026-11-13 10:00:00 UTC IP: 127.0.0.1"]
        #expect(error(refusal, sentCode: true) == .invalidTwoStepCode)
        // Without a code in the request the same answer is an unknown refusal.
        #expect(error(refusal, sentCode: false) != .invalidTwoStepCode)
        // A wrong master password is still that, also beside a code.
        #expect(error(["error": "", "message": "Username or password is incorrect. Try again"], sentCode: true) == .invalidCredentials)
    }

    @Test func theTokenOfARememberedDeviceIsTaken() throws {
        var fields = success
        fields["Key"] = "2.wrapped-user-key"
        fields["PrivateKey"] = "2.private"
        fields["TwoFactorToken"] = "remember-token"
        #expect(try grant(fields).twoStepRememberToken == "remember-token")
        fields["TwoFactorToken"] = nil
        #expect(try grant(fields).twoStepRememberToken == nil)
    }

    @Test func wrongCredentialsAreRecognisedFromBitwardenAndVaultwarden() {
        #expect(failure(["error": "invalid_grant", "error_description": "invalid_username_or_password"], status: 400) == .invalidCredentials)
        #expect(failure(["error": "", "message": "Username or password is incorrect. Try again"], status: 400) == .invalidCredentials)
    }

    @Test func otherRefusalsKeepTheServerMessage() {
        #expect(failure(["message": "Too many requests"], status: 429) == .server("HTTP 429: Too many requests"))
    }

    @Test func keyDerivationHasNetworkAndOfflineResourceBounds() {
        let legacy = KeyDerivation.pbkdf2(iterations: 100_000)
        #expect(legacy.isSupported(forNetworkLogin: false))
        #expect(!legacy.isSupported(forNetworkLogin: true))
        #expect(KeyDerivation.argon2id(iterations: 6, memory: 32, parallelism: 4).isSupported(forNetworkLogin: true))
        #expect(!KeyDerivation.argon2id(iterations: 6, memory: .max, parallelism: 4).isSupported(forNetworkLogin: false))
    }

    @Test func plainHTTPIsAcceptedForLocalServersOnly() {
        let accepted = ["https://vault.example.com", "https://vault.example.com/base", "http://localhost:8642",
                        "http://127.0.0.1:8642", "http://192.168.1.10", "http://[::1]", "http://[fd00::1]", "http://nas.local", "http://vaultwarden"]
        let refused = ["http://vault.example.com", "ftp://vault.example.com", "https://user:secret@vault.example.com",
                       "https://vault.example.com/?x=1", "vault.example.com", "http://[2001:db8::1]", "http://3221225985", "http://0xc0000201"]
        for url in accepted { #expect(HTTPClient.isAcceptable(URL(string: url)!), "\(url)") }
        for url in refused { #expect(!HTTPClient.isAcceptable(URL(string: url)!), "\(url)") }
    }
}
