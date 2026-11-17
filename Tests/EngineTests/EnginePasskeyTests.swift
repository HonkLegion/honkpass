import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Passkeys through the engine, as the AutoFill extension asks for them. The authenticator is
/// the fake one: what the real one of the SDK signs is tried with the built app.
@Suite struct EnginePasskeyTests {
    private let hash = Data("fake-client-data-hash".utf8)
    private let handle = Data("user-1".utf8)

    private func registration(_ rpID: String = "passkey.example", into itemID: String? = nil, excluded: [Data] = [],
                              verification: PasskeyUserVerification = .preferred, isVerified: Bool = true) -> PasskeyRegistrationRequest {
        PasskeyRegistrationRequest(rpID: rpID, userName: "demo-passkey", userHandle: handle, clientDataHash: hash, algorithms: [-7],
                                   excludedCredentialIDs: excluded, userVerification: verification, isUserVerified: isVerified,
                                   itemID: itemID)
    }

    private func made(_ response: AutoFillResponse) throws -> PasskeyRegistration {
        guard case .passkeyRegistration(let registration) = response else {
            Issue.record("expected a new passkey, got \(response)")
            throw EngineError.notFound
        }
        return registration
    }

    @Test func aPasskeyIsMadeInANewLoginAndSignsForItsWebsite() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        // No login of the website: there is nothing to choose from, and the passkey gets a new login.
        #expect(await engine.autoFill(.passkeyTargets(rpID: "passkey.example", userHandle: handle)) == .logins([]))
        let registration = try made(await engine.autoFill(.registerPasskey(registration())))
        #expect(registration.rpID == "passkey.example" && !registration.attestationObject.isEmpty)

        let login = try #require(await engine.state.vault.items.first { !$0.passkeys.isEmpty })
        #expect(login.name == "passkey.example" && login.subtitle == "demo-passkey")
        #expect(login.websites.map(\.address) == ["https://passkey.example"])
        #expect(login.passkeys == [VaultPasskey(credentialID: registration.credentialID, rpID: "passkey.example",
                                                userName: "demo-passkey", userHandle: handle)])

        // The system gets an entry for it, and the extension can list it for its website only.
        var stored: [AutoFillIdentity] = []
        for _ in 0..<200 where !stored.contains(where: { $0.kind == .passkey }) {
            try? await Task.sleep(for: .milliseconds(10))
            stored = await handles.identities.identities
        }
        #expect(stored.filter { $0.kind == .passkey } == [
            AutoFillIdentity(kind: .passkey, itemID: login.id, website: "passkey.example", username: "demo-passkey",
                             credentialID: registration.credentialID, userHandle: handle),
        ])
        let listed = AutoFillPasskey(itemID: login.id, credentialID: registration.credentialID, name: "passkey.example",
                                     username: "demo-passkey")
        #expect(await engine.autoFill(.passkeys(rpID: "passkey.example", allowedCredentialIDs: [])) == .passkeys([listed]))
        #expect(await engine.autoFill(.passkeys(rpID: "passkey.example", allowedCredentialIDs: [registration.credentialID]))
            == .passkeys([listed]))
        #expect(await engine.autoFill(.passkeys(rpID: "passkey.example", allowedCredentialIDs: [Data("another".utf8)])) == .passkeys([]))
        #expect(await engine.autoFill(.passkeys(rpID: "other.example", allowedCredentialIDs: [])) == .passkeys([]))

        // It signs what the website sent, and says whether the user was verified.
        let request = PasskeyAssertionRequest(rpID: "passkey.example", clientDataHash: hash, itemID: login.id,
                                              userVerification: .required, isUserVerified: true)
        #expect(await engine.autoFill(.passkeyAssertion(request)) == .passkeyAssertion(PasskeyAssertion(
            rpID: "passkey.example", credentialID: registration.credentialID, userHandle: handle,
            authenticatorData: Data("fake-authenticator-data:verified".utf8), signature: Data("fake-signature:".utf8) + hash)))

        // A website that asks for a verified user gets nothing for one who was not.
        var unverified = request
        unverified.isUserVerified = false
        #expect(await engine.autoFill(.passkeyAssertion(unverified)) == .failure(.userNotVerified))
        unverified.userVerification = .preferred
        guard case .passkeyAssertion(let present) = await engine.autoFill(.passkeyAssertion(unverified)) else {
            Issue.record("expected a signature for a user who is present")
            return
        }
        #expect(present.authenticatorData == Data("fake-authenticator-data:present".utf8))

        // Another website, and a login without a passkey.
        var other = request
        other.rpID = "other.example"
        #expect(await engine.autoFill(.passkeyAssertion(other)) == .failure(.notFound))
        other = request
        other.itemID = "item-1"
        #expect(await engine.autoFill(.passkeyAssertion(other)) == .failure(.notFound))
    }

    @Test func aPasskeyGoesIntoALoginOfTheWebsiteAndTakesThePlaceOfItsOwn() async throws {
        let (engine, _) = try await makeUnlockedEngine()

        // The login of the website is offered; it has no passkey yet.
        #expect(await engine.autoFill(.passkeyTargets(rpID: "item-2.example", userHandle: handle))
            == .logins([AutoFillLogin(itemID: "item-2", name: "Example Shop", username: "demo-shopper")]))
        let first = try made(await engine.autoFill(.registerPasskey(registration("item-2.example", into: "item-2"))))
        #expect(await engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.map(\.credentialID) == [first.credentialID])
        // The login keeps what it had.
        let item = try await engine.item(id: "item-2")
        #expect(item.value(of: .username) == "demo-shopper" && item.value(of: .password) != nil)

        // The same user can have it replaced; a passkey of another user leaves the login alone.
        #expect(await engine.autoFill(.passkeyTargets(rpID: "item-2.example", userHandle: handle))
            == .logins([AutoFillLogin(itemID: "item-2", name: "Example Shop", username: "demo-shopper", hasPasskey: true)]))
        #expect(await engine.autoFill(.passkeyTargets(rpID: "item-2.example", userHandle: Data("user-2".utf8))) == .logins([]))
        let second = try made(await engine.autoFill(.registerPasskey(registration("item-2.example", into: "item-2"))))
        #expect(second.credentialID != first.credentialID)
        #expect(await engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.map(\.credentialID) == [second.credentialID])

        // A passkey the website excludes is in the vault: no other is made.
        #expect(await engine.autoFill(.registerPasskey(registration("item-2.example", excluded: [second.credentialID])))
            == .failure(.passkeyExists))
        #expect(await engine.autoFill(.registerPasskey(registration(into: "missing"))) == .failure(.notFound))
        #expect(await engine.autoFill(.registerPasskey(registration(verification: .required, isVerified: false)))
            == .failure(.userNotVerified))
    }

    @Test func theFormShowsThePasskeyOfALoginAndCanRemoveIt() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        _ = try made(await engine.autoFill(.registerPasskey(registration("item-2.example", into: "item-2"))))

        guard case .login(let shown) = try await engine.item(id: "item-2").content else {
            Issue.record("expected a login")
            return
        }
        #expect(shown.passkeyCreated != nil)
        var draft = try await engine.draft(of: "item-2")
        guard case .login(var login) = draft.content else {
            Issue.record("expected the form of a login")
            return
        }
        #expect(login.passkeyCreated != nil)

        // A save that leaves the passkey alone keeps it.
        draft.name = "Example Shop 2"
        _ = try await engine.save(draft)
        #expect(await engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.count == 1)

        draft = try await engine.draft(of: "item-2")
        login.passkeyCreated = nil
        draft.content = .login(login)
        _ = try await engine.save(draft)
        #expect(await engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.isEmpty == true)
        #expect(await engine.autoFill(.passkeys(rpID: "item-2.example", allowedCredentialIDs: [])) == .passkeys([]))
    }

    @Test func aLockedVaultAndAProtectedLoginGiveNoPasskey() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let registration = try made(await engine.autoFill(.registerPasskey(registration("item-2.example", into: "item-2"))))
        let request = PasskeyAssertionRequest(rpID: "item-2.example", clientDataHash: hash, itemID: "item-2",
                                              userVerification: .preferred, isUserVerified: true)

        // A login that asks for the master password again: listed as such, never signed with,
        // and not among the entries of the system.
        var draft = try await engine.draft(of: "item-2")
        draft.asksForMasterPassword = true
        _ = try await engine.save(draft)
        #expect(await engine.autoFill(.passkeys(rpID: "item-2.example", allowedCredentialIDs: [])) == .passkeys([
            AutoFillPasskey(itemID: "item-2", credentialID: registration.credentialID, name: "Example Shop",
                            username: "demo-passkey", asksForMasterPassword: true),
        ]))
        #expect(await engine.autoFill(.passkeyAssertion(request)) == .failure(.masterPasswordRequired))
        #expect(await engine.autoFill(.registerPasskey(self.registration("item-2.example", into: "item-2")))
            == .failure(.masterPasswordRequired))
        #expect(await engine.state.vault.passkeyIdentities.isEmpty)

        await engine.lock()
        #expect(await engine.autoFill(.passkeys(rpID: "item-2.example", allowedCredentialIDs: [])) == .failure(.locked))
        #expect(await engine.autoFill(.passkeyAssertion(request)) == .failure(.locked))
        #expect(await engine.autoFill(.passkeyTargets(rpID: "item-2.example", userHandle: handle)) == .failure(.locked))
        #expect(await engine.autoFill(.registerPasskey(self.registration())) == .failure(.locked))
    }
}
