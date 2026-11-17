import BitwardenSdk
import Engine
import Foundation

// Development only: fills the local Vaultwarden with one synthetic account.
// `package` access keeps this out of the app; the seed tool and the tests use it.

/// A synthetic account of support/vaultwarden: test-account.json, and test-account-two-step.json
/// for the account with two-step login.
package struct SeedAccount: Codable, Sendable {
    package var server: URL
    package var email: String
    package var name: String
    package var masterPassword: String
    /// Where the mail of the development server can be read. Only the two-step account needs it.
    package var mailCatcher: URL?

    package static func load(from file: URL) throws -> SeedAccount {
        try JSONDecoder().decode(SeedAccount.self, from: Data(contentsOf: file))
    }
}

package enum DevelopmentSeed {
    package enum Outcome: Sendable, Equatable {
        case created(items: Int)
        case alreadySeeded(items: Int)
    }

    package static let folderNames = ["Shopping", "Work"]
    package static let trashedItemName = "Example Deleted Login"
    package static var itemNames: [String] { items(folders: [:], sshKey: nil).map(\.name) }

    /// Registers the account when it does not exist and creates the items when the vault is empty.
    package static func run(_ account: SeedAccount) async throws -> Outcome {
        guard HTTPClient.isAcceptable(account.server), account.server.scheme == "http" else {
            throw EngineError.server("The seed writes only to a local development server over plain HTTP.")
        }
        let server = VaultwardenServer()
        let grant: LoginGrant
        do {
            grant = try await logIn(account, server)
        } catch EngineError.invalidCredentials {
            try await register(account, server)
            grant = try await logIn(account, server)
        }
        let vault = try await SDKVault.open(UnlockRequest(userID: grant.userID, email: account.email,
                                                          material: grant.crypto, masterPassword: account.masterPassword))
        let existing = try await vault.decryptVault(syncPayload: server.sync(server: account.server, accessToken: grant.accessToken))
        // A test run that broke off may have left its temporary items behind.
        for item in existing.items where item.name.hasPrefix(temporaryItemPrefix) {
            try await server.write(.deletePermanently, itemID: item.id, server: account.server, accessToken: grant.accessToken)
        }
        for folder in existing.folders where folder.name.hasPrefix(temporaryItemPrefix) {
            try await server.deleteFolder(id: folder.id, server: account.server, accessToken: grant.accessToken)
        }
        let kept = existing.items.filter { !$0.name.hasPrefix(temporaryItemPrefix) }
        if kept.count == itemNames.count { return .alreadySeeded(items: kept.count) }
        guard kept.isEmpty, existing.folders.isEmpty else {
            throw EngineError.server("The test account holds other data. Reset the server: make server-reset")
        }

        let writer = Writer(server: server, vault: vault, base: account.server, accessToken: grant.accessToken)
        var folders: [String: String] = [:]
        for name in folderNames { folders[name] = try await writer.createFolder(name) }
        let sshKey = try vault.client.ssh().generateSshKey(keyAlgorithm: .ed25519)
        let views = items(folders: folders, sshKey: sshKey)
        for view in views {
            let id = try await writer.createCipher(view)
            if view.name == trashedItemName { try await writer.moveToTrash(id) }
        }
        return .created(items: views.count)
    }

    /// The items that a test adds, changes and deletes again, so that the seeded items stay as
    /// they are. Their names start with this; the seed removes what a broken run left behind.
    package static let temporaryItemPrefix = "Example Temporary"
    package static let temporaryItemName = temporaryItemPrefix + " Login"

    /// Adds the temporary item to the folder "Shopping" of the seeded account. Returns its identifier.
    package static func addTemporaryItem(_ account: SeedAccount) async throws -> String {
        guard HTTPClient.isAcceptable(account.server), account.server.scheme == "http" else {
            throw EngineError.server("The seed writes only to a local development server over plain HTTP.")
        }
        let server = VaultwardenServer()
        let grant = try await logIn(account, server)
        let vault = try await SDKVault.open(UnlockRequest(userID: grant.userID, email: account.email,
                                                          material: grant.crypto, masterPassword: account.masterPassword))
        let existing = try await vault.decryptVault(syncPayload: server.sync(server: account.server, accessToken: grant.accessToken))
        guard let folder = existing.folders.first(where: { $0.name == folderNames[0] }) else {
            throw EngineError.server("The test account is not seeded.")
        }
        let login = LoginView(username: "temporary-user", password: "synthetic-temporary-password", passwordRevisionDate: nil,
                              uris: [LoginUriView(uri: "https://temporary.example.com", match: nil, uriChecksum: nil)],
                              totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil)
        let writer = Writer(server: server, vault: vault, base: account.server, accessToken: grant.accessToken)
        return try await writer.createCipher(cipher(
            temporaryItemName, notes: "A synthetic note that must survive every change.", folder: folder.id, login: login,
            fields: [FieldView(name: "Temporary field", value: "synthetic value", type: .text, linkedId: nil),
                     FieldView(name: "Temporary secret", value: "synthetic secret", type: .hidden, linkedId: nil),
                     FieldView(name: "Temporary link", value: nil, type: .linked, linkedId: 100)]))
    }

    // MARK: Organization

    package static let organizationName = "Example Organization"
    package static let collectionNames = ["Example Collection", "Example Team/Servers"]
    /// The items of the organization, each with the collections it is in, and the one item of
    /// the user beside them.
    package static let organizationItems = [("Example Shared Login", [0]), ("Example Shared Note", [0, 1])]
    package static let personalItemOfOrganizationAccount = "Example Own Login"

    /// Registers the account when it does not exist and gives it an organization with two
    /// collections, two items in them and one item of its own. Nothing is changed when the
    /// account has them already.
    ///
    /// The key of the organization is the key of the user, wrapped for the user's own public
    /// key: the SDK makes no key of an organization, and for a synthetic vault any key will do.
    /// A real organization has a key of its own.
    package static func runOrganization(_ account: SeedAccount) async throws -> Outcome {
        guard HTTPClient.isAcceptable(account.server), account.server.scheme == "http" else {
            throw EngineError.server("The seed writes only to a local development server over plain HTTP.")
        }
        let server = VaultwardenServer()
        let grant: LoginGrant
        do {
            grant = try await logIn(account, server)
        } catch EngineError.invalidCredentials {
            try await register(account, server)
            grant = try await logIn(account, server)
        }
        let vault = try await SDKVault.open(UnlockRequest(userID: grant.userID, email: account.email,
                                                          material: grant.crypto, masterPassword: account.masterPassword))
        let existing = try await vault.decryptVault(syncPayload: server.sync(server: account.server, accessToken: grant.accessToken))
        for item in existing.items where item.name.hasPrefix(temporaryItemPrefix) {
            try await server.write(.deletePermanently, itemID: item.id, server: account.server, accessToken: grant.accessToken)
        }
        let kept = existing.items.filter { !$0.name.hasPrefix(temporaryItemPrefix) }
        if kept.count == organizationItems.count + 1, existing.organizations.count == 1 { return .alreadySeeded(items: kept.count) }
        guard kept.isEmpty, existing.organizations.isEmpty else {
            throw EngineError.server("The organization account holds other data. Reset the server: make server-reset")
        }

        let writer = Writer(server: server, vault: vault, base: account.server, accessToken: grant.accessToken)
        func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
            let request = try body.map {
                try HTTPClient.jsonRequest(method, account.server, path, body: JSONSerialization.data(withJSONObject: $0),
                                           accessToken: grant.accessToken)
            } ?? HTTPClient.request(method, account.server, path, accessToken: grant.accessToken)
            let (data, status) = try await server.http.send(request)
            guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        }
        func encrypted(_ name: String) throws -> String {
            do {
                return try vault.client.vault().folders().encrypt(folder: FolderView(id: nil, name: name, revisionDate: Date())).name
            } catch {
                throw EngineError.unexpected("The SDK could not encrypt a name.")
            }
        }
        guard let publicKey = JSON.string(try await send("GET", "api/users/\(grant.userID)/public-key"), "PublicKey") else {
            throw EngineError.server("The server gave no public key of the account.")
        }
        let wrappedKey: String
        do {
            wrappedKey = try vault.client.crypto().enrollAdminPasswordReset(publicKey: publicKey)
        } catch {
            throw EngineError.unexpected("The SDK could not wrap the key of the organization.")
        }
        let organization = try await send("POST", "api/organizations", [
            "name": organizationName, "billingEmail": account.email, "key": wrappedKey,
            "collectionName": try encrypted(collectionNames[0]), "planType": 0,
        ])
        guard let organizationID = JSON.string(organization, "Id") else { throw EngineError.server("The server made no organization.") }
        let second = try await send("POST", "api/organizations/\(organizationID)/collections", [
            "name": try encrypted(collectionNames[1]), "groups": [[String: Any]](), "users": [[String: Any]](),
        ])
        // The vault with the organization in it: its key, and the collection the server made with it.
        let seeded = try await vault.decryptVault(syncPayload: server.sync(server: account.server, accessToken: grant.accessToken))
        guard let first = seeded.collections.first(where: { $0.name == collectionNames[0] })?.id, let secondID = JSON.string(second, "Id") else {
            throw EngineError.server("The organization has no collections.")
        }
        let collections = [first, secondID.lowercased()]
        _ = try await writer.createCipher(cipher(personalItemOfOrganizationAccount, login: LoginView(
            username: "own-user", password: "synthetic-own-password", passwordRevisionDate: nil,
            uris: [LoginUriView(uri: "https://own.example.com", match: nil, uriChecksum: nil)], totp: nil,
            autofillOnPageLoad: nil, fido2Credentials: nil)))
        for (name, places) in organizationItems {
            let login = name.hasSuffix("Login") ? LoginView(
                username: "shared-user", password: "synthetic-shared-password", passwordRevisionDate: nil,
                uris: [LoginUriView(uri: "https://shared.example.com", match: nil, uriChecksum: nil)], totp: nil,
                autofillOnPageLoad: nil, fido2Credentials: nil) : nil
            let view = cipher(name, notes: login == nil ? "A synthetic note of the organization." : nil, login: login,
                              secureNote: login == nil ? SecureNoteView(type: .generic) : nil, organizationID: organizationID)
            try await writer.createCipher(view, in: places.map { collections[$0] })
        }
        return .created(items: organizationItems.count + 1)
    }

    // MARK: Two-step login

    package enum TwoStepOutcome: Sendable, Equatable {
        case created
        case alreadySeeded
    }

    /// Registers the account when it does not exist and gives it two-step login by authenticator
    /// app and by email. The code of the email comes from the mail catcher of the server.
    package static func runTwoStep(_ account: SeedAccount) async throws -> TwoStepOutcome {
        guard HTTPClient.isAcceptable(account.server), account.server.scheme == "http" else {
            throw EngineError.server("The seed writes only to a local development server over plain HTTP.")
        }
        guard let catcher = account.mailCatcher.map(MailCatcher.init(base:)) else {
            throw EngineError.server("The two-step account needs the address of the mail catcher.")
        }
        let server = VaultwardenServer()
        var outcome: LoginOutcome
        do {
            outcome = try await logInOutcome(account, server)
        } catch EngineError.invalidCredentials {
            try await register(account, server)
            outcome = try await logInOutcome(account, server)
        }
        switch outcome {
        case .needsTwoStep(let challenge):
            guard Set(challenge.methods) == [.authenticator, .email] else {
                throw EngineError.server("The two-step account has other methods. Reset the server: make server-reset")
            }
            return .alreadySeeded
        case .granted(let grant):
            let hash = try await passwordHash(account, server)
            let setup = TwoStepSetup(server: server, base: account.server, accessToken: grant.accessToken, passwordHash: hash)
            try await setup.enableAuthenticator()
            try await setup.enableEmail(account.email, catcher: catcher)
            return .created
        }
    }

    /// The current code of the authenticator app of the two-step account. It logs in with a code
    /// from the mail catcher and reads the key of the authenticator from the account.
    package static func authenticatorCode(_ account: SeedAccount) async throws -> String {
        guard let catcher = account.mailCatcher.map(MailCatcher.init(base:)) else {
            throw EngineError.server("The two-step account needs the address of the mail catcher.")
        }
        let server = VaultwardenServer()
        let prelogin = try await server.prelogin(server: account.server, email: account.email)
        let hash = try await BitwardenCrypto().serverPasswordHash(password: account.masterPassword, prelogin: prelogin)
        var request = LoginRequest(server: account.server, email: account.email, passwordHash: hash, prelogin: prelogin,
                                   deviceIdentifier: seedDeviceIdentifier)
        try await catcher.deleteMail(to: account.email)
        try await server.sendTwoStepEmail(request)
        request.twoStep = TwoStepProof(kind: .method(.email), token: try await catcher.latestCode(to: account.email), remember: false)
        guard case .granted(let grant) = try await server.logIn(request) else {
            throw EngineError.server("The two-step account did not log in with the code of its mail.")
        }
        let setup = TwoStepSetup(server: server, base: account.server, accessToken: grant.accessToken, passwordHash: hash)
        return try TwoStepSetup.code(for: try await setup.authenticatorKey().key)
    }

    /// The calls of the web vault's two-step settings.
    private struct TwoStepSetup {
        let server: VaultwardenServer
        let base: URL
        let accessToken: String
        let passwordHash: String

        func authenticatorKey() async throws -> (key: String, verification: String) {
            let object = try await post("api/two-factor/get-authenticator", ["masterPasswordHash": passwordHash])
            guard let authenticator = JSON.field(object, "authenticator") as? [String: Any],
                  let key = JSON.string(authenticator, "key"), let verification = JSON.string(object, "userVerificationToken") else {
                throw EngineError.server("The server gave no authenticator key.")
            }
            return (key, verification)
        }

        func enableAuthenticator() async throws {
            let (key, verification) = try await authenticatorKey()
            _ = try await post("api/two-factor/authenticator",
                               ["key": key, "token": try Self.code(for: key), "userVerificationToken": verification])
        }

        func enableEmail(_ email: String, catcher: MailCatcher) async throws {
            let object = try await post("api/two-factor/get-email", ["masterPasswordHash": passwordHash])
            guard let verification = JSON.string(object, "userVerificationToken") else {
                throw EngineError.server("The server gave no verification token for the email method.")
            }
            try await catcher.deleteMail(to: email)
            _ = try await post("api/two-factor/send-email", ["email": email, "userVerificationToken": verification])
            let code = try await catcher.latestCode(to: email)
            _ = try await send("PUT", "api/two-factor/email", ["email": email, "token": code, "userVerificationToken": verification])
        }

        /// The SDK computes the code, as for the verification codes of items.
        static func code(for key: String) throws -> String {
            do {
                return try SDK.makeClient().vault().generateTotp(key: key, time: Date()).code
            } catch {
                throw EngineError.unexpected("The SDK could not compute the authenticator code.")
            }
        }

        private func post(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
            try await send("POST", path, body)
        }

        private func send(_ method: String, _ path: String, _ body: [String: String]) async throws -> [String: Any] {
            let request = try HTTPClient.jsonRequest(method, base, path, body: JSONSerialization.data(withJSONObject: body),
                                                     accessToken: accessToken)
            let (data, status) = try await server.http.send(request)
            guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        }
    }

    // MARK: Account

    private static func logIn(_ account: SeedAccount, _ server: VaultwardenServer) async throws -> LoginGrant {
        guard case .granted(let grant) = try await logInOutcome(account, server) else {
            throw EngineError.server("The account \(account.email) has two-step login. Reset the server: make server-reset")
        }
        return grant
    }

    private static func logInOutcome(_ account: SeedAccount, _ server: VaultwardenServer) async throws -> LoginOutcome {
        let prelogin = try await server.prelogin(server: account.server, email: account.email)
        let hash = try await BitwardenCrypto().serverPasswordHash(password: account.masterPassword, prelogin: prelogin)
        return try await server.logIn(LoginRequest(server: account.server, email: account.email, passwordHash: hash,
                                                   prelogin: prelogin, deviceIdentifier: seedDeviceIdentifier))
    }

    private static func passwordHash(_ account: SeedAccount, _ server: VaultwardenServer) async throws -> String {
        let prelogin = try await server.prelogin(server: account.server, email: account.email)
        return try await BitwardenCrypto().serverPasswordHash(password: account.masterPassword, prelogin: prelogin)
    }

    /// A fixed device, so repeated seeding does not fill the account's device list.
    private static let seedDeviceIdentifier = "5eed0000-0000-4000-8000-000000000001"

    private static func register(_ account: SeedAccount, _ server: VaultwardenServer) async throws {
        let iterations: UInt32 = 600_000
        let keys: RegisterKeyResponse
        do {
            keys = try SDK.makeClient().auth().makeRegisterKeys(email: account.email, password: account.masterPassword,
                                                                 kdf: .pbkdf2(iterations: iterations))
        } catch {
            throw EngineError.unexpected("The SDK could not make the registration keys.")
        }

        let start = try JSONSerialization.data(withJSONObject: ["email": account.email, "name": account.name])
        let (tokenData, tokenStatus) = try await server.http.send(
            HTTPClient.jsonRequest("POST", account.server, "identity/accounts/register/send-verification-email", body: start))
        guard tokenStatus == 200, let tokenText = String(data: tokenData, encoding: .utf8) else {
            throw HTTPClient.refusal(tokenData, status: tokenStatus)
        }
        // Without mail delivery the server answers with the verification token itself.
        let token = tokenText.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))

        let finish = try JSONSerialization.data(withJSONObject: [
            "email": account.email, "name": account.name, "emailVerificationToken": token,
            "masterPasswordHash": keys.masterPasswordHash, "userSymmetricKey": keys.encryptedUserKey,
            "userAsymmetricKeys": ["publicKey": keys.keys.public, "encryptedPrivateKey": keys.keys.private],
            "kdf": 0, "kdfIterations": Int(iterations),
        ] as [String: Any])
        let (data, status) = try await server.http.send(
            HTTPClient.jsonRequest("POST", account.server, "identity/accounts/register/finish", body: finish))
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    // MARK: Writes

    private struct Writer {
        let server: VaultwardenServer
        let vault: SDKVault
        let base: URL
        let accessToken: String

        func createFolder(_ name: String) async throws -> String {
            let folder: Folder
            do {
                folder = try vault.client.vault().folders().encrypt(folder: FolderView(id: nil, name: name, revisionDate: Date()))
            } catch {
                throw EngineError.unexpected("The SDK could not encrypt a folder.")
            }
            let body = try JSONSerialization.data(withJSONObject: ["name": folder.name])
            return try await createdID(HTTPClient.jsonRequest("POST", base, "api/folders", body: body, accessToken: accessToken))
        }

        func createCipher(_ view: CipherView) async throws -> String {
            let body: String?
            do {
                let context = try await vault.client.vault().ciphers().encrypt(cipherView: view)
                body = vault.client.vault().ciphers().cipherRequestJson(context: context)
            } catch {
                throw EngineError.unexpected("The SDK could not encrypt an item.")
            }
            guard let body else { throw EngineError.unexpected("The SDK made no request for an item.") }
            return try await createdID(HTTPClient.jsonRequest("POST", base, "api/ciphers", body: Data(body.utf8), accessToken: accessToken))
        }

        /// An item of an organization, in its collections.
        func createCipher(_ view: CipherView, in collectionIDs: [String]) async throws {
            let body: String?
            do {
                let context = try await vault.client.vault().ciphers().encrypt(cipherView: view)
                body = vault.client.vault().ciphers().cipherRequestJson(context: context)
            } catch {
                throw EngineError.unexpected("The SDK could not encrypt an item of the organization.")
            }
            guard let body, let cipher = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
                throw EngineError.unexpected("The SDK made no request for an item.")
            }
            let request = try JSONSerialization.data(withJSONObject: ["cipher": cipher, "collectionIds": collectionIDs])
            _ = try await createdID(HTTPClient.jsonRequest("POST", base, "api/ciphers/create", body: request, accessToken: accessToken))
        }

        func moveToTrash(_ id: String) async throws {
            var request = try HTTPClient.request("PUT", base, "api/ciphers/\(id)/delete", accessToken: accessToken)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, status) = try await server.http.send(request)
            guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        }

        private func createdID(_ request: URLRequest) async throws -> String {
            let (data, status) = try await server.http.send(request)
            guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = JSON.string(object, "Id") else { throw EngineError.server("The server returned no identifier.") }
            return id
        }
    }

    // MARK: Content

    /// One item of every type and every list state: favourite, in a folder, with custom fields, in the trash.
    /// All values are synthetic.
    private static func items(folders: [String: String], sshKey: SshKeyView?) -> [CipherView] {
        func login(_ username: String?, _ password: String?, uris: [String] = [], totp: String? = nil) -> LoginView {
            LoginView(username: username, password: password, passwordRevisionDate: nil,
                      uris: uris.isEmpty ? nil : uris.map { LoginUriView(uri: $0, match: nil, uriChecksum: nil) },
                      totp: totp, autofillOnPageLoad: nil, fido2Credentials: nil)
        }
        return [
            cipher("Example Mail", favorite: true,
                   login: login("test.user@example.com", "synthetic-mail-password", uris: ["https://mail.example.com"],
                                totp: "otpauth://totp/Example:test.user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")),
            cipher("Example Shop", notes: "Synthetic note of the shop login.", folder: folders["Shopping"],
                   login: login("test-shopper", "synthetic-shop-password",
                                uris: ["https://shop.example.com/login", "https://checkout.example.com"]),
                   fields: [
                       FieldView(name: "Customer number", value: "C-000123", type: .text, linkedId: nil),
                       FieldView(name: "Security answer", value: "synthetic answer", type: .hidden, linkedId: nil),
                       FieldView(name: "Newsletter", value: "true", type: .boolean, linkedId: nil),
                   ]),
            cipher("Example Intranet", folder: folders["Work"], reprompt: .password,
                   login: login("tuser", "synthetic-intranet-password", uris: ["http://intranet.example.local"])),
            cipher("Example Login Without Password", login: login("only-a-username", nil)),
            cipher("Example Card",
                   card: CardView(cardholderName: "Test User", expMonth: "12", expYear: "2030", code: "123",
                                  brand: "Visa", number: "4242424242424242")),
            cipher("Example Identity",
                   identity: IdentityView(title: "Mr", firstName: "Test", middleName: nil, lastName: "User",
                                          address1: "1 Example Street", address2: nil, address3: nil, city: "Prague",
                                          state: nil, postalCode: "110 00", country: "CZ", company: "Example Ltd",
                                          email: "test.user@example.com", phone: "+420 000 000 000", ssn: nil,
                                          username: "testuser", passportNumber: nil, licenseNumber: nil)),
            cipher("Example Note", notes: "A synthetic secure note.\nIt has two lines.", folder: folders["Work"],
                   secureNote: SecureNoteView(type: .generic)),
            cipher("Example SSH Key",
                   sshKey: sshKey ?? SshKeyView(privateKey: "", publicKey: "", fingerprint: "")),
            cipher(trashedItemName, login: login("deleted-user", "synthetic-deleted-password", uris: ["https://old.example.com"])),
        ]
    }

    private static func cipher(_ name: String, notes: String? = nil, favorite: Bool = false, folder: String? = nil,
                               reprompt: CipherRepromptType = .none, login: LoginView? = nil, identity: IdentityView? = nil,
                               card: CardView? = nil, secureNote: SecureNoteView? = nil, sshKey: SshKeyView? = nil,
                               fields: [FieldView]? = nil, organizationID: String? = nil) -> CipherView {
        let type: CipherType = login != nil ? .login : card != nil ? .card : identity != nil ? .identity
            : sshKey != nil ? .sshKey : .secureNote
        let date = Date()
        return CipherView(
            id: nil, organizationId: organizationID, folderId: folder, collectionIds: [], key: nil, name: name, notes: notes,
            type: type, login: login, identity: identity, card: card, secureNote: secureNote, sshKey: sshKey,
            bankAccount: nil, driversLicense: nil, passport: nil, favorite: favorite, reprompt: reprompt,
            organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true, localData: nil,
            attachments: nil, attachmentDecryptionFailures: nil, fields: fields, passwordHistory: nil,
            creationDate: date, deletedDate: nil, revisionDate: date, archivedDate: nil, partial: false)
    }
}
