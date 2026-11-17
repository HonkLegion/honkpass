import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineGeneratorTests {
    @Test func theGeneratorGetsOptionsInsideTheirLimits() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        var password = PasswordOptions()
        password.length = 500
        password.special = true
        // The fake generator repeats one character of each kind that is included.
        #expect(try await engine.generate(.password(password)) == String(String(repeating: "Ab3#", count: 32).prefix(128)))

        var passphrase = PassphraseOptions()
        passphrase.words = 1
        passphrase.capitalize = true
        #expect(try await engine.generate(.passphrase(passphrase)) == "Fake-Fake-Fake")

        var username = UsernameOptions()
        #expect(try await engine.generate(.username(username)) == "fakeword")
        username.kind = .catchallEmail
        username.domain = "example.com"
        #expect(try await engine.generate(.username(username)) == "fake@example.com")
    }

    @Test func aCatchAllAddressStartsWithTheNameOfTheWebsiteWhenAskedTo() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        var options = UsernameOptions()
        options.kind = .catchallEmail
        options.domain = "example.org"
        let website = "https://shop.example.com/login"

        // Without the choice "website name" the website does not count.
        #expect(try await engine.generate(.username(options, website: website)) == "fake@example.org")
        options.catchallUsesWebsiteName = true
        #expect(try await engine.generate(.username(options, website: website)) == "shop.example.com@example.org")
        #expect(try await engine.generate(.username(options, website: "shop.example.com")) == "shop.example.com@example.org")
        // The generator that was not opened for an item knows no website: random characters stand in.
        #expect(try await engine.generate(.username(options)) == "fake@example.org")
        #expect(try await engine.generate(.username(options, website: "  ")) == "fake@example.org")

        // Options that an older version saved have no such choice.
        let older = Data(#"{"kind":"catchallEmail","capitalize":true,"includeNumber":false,"email":"","domain":"example.org"}"#.utf8)
        let decoded = try JSONDecoder().decode(UsernameOptions.self, from: older)
        #expect(decoded.kind == .catchallEmail && decoded.capitalize && decoded.domain == "example.org")
        #expect(!decoded.catchallUsesWebsiteName)
    }

    @Test func anSSHKeyIsTakenFromTheClipboardOnlyWhenAskedFor() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await handles.clipboard.readCount == 0)
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard() } == .sshKeyImport(.notAKey))

        await handles.clipboard.copy("fake-ssh-key:mine\n", isSensitive: true)
        let key = try await engine.importSSHKeyFromClipboard()
        #expect(key == SSHKeyContent(privateKey: "fake-private-key-mine", publicKey: "ssh-ed25519 fake-public-key-mine",
                                     fingerprint: "SHA256:fake-mine"))

        // An encrypted key asks for its password, and a wrong one is said to be wrong.
        await handles.clipboard.copy("fake-encrypted-ssh-key:synthetic-passphrase:locked", isSensitive: true)
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard() } == .sshKeyImport(.passwordRequired))
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard(password: "wrong") } == .sshKeyImport(.wrongPassword))
        #expect(try await engine.importSSHKeyFromClipboard(password: "synthetic-passphrase").fingerprint == "SHA256:fake-locked")

        await handles.clipboard.copy("fake-dsa-key", isSensitive: true)
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard() } == .sshKeyImport(.unsupportedKind))
        await handles.clipboard.copy("just some text", isSensitive: false)
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard() } == .sshKeyImport(.notAKey))

        let reads = await handles.clipboard.readCount
        await engine.lock()
        #expect(await engineError { _ = try await engine.importSSHKeyFromClipboard() } == .invalidState)
        #expect(await handles.clipboard.readCount == reads)
    }

    @Test func theGeneratorKeepsWhatItHasMadeTheNewestFirst() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(try await engine.generatorHistory().isEmpty)

        _ = try await engine.generate(.password(PasswordOptions()))
        _ = try await engine.generate(.passphrase(PassphraseOptions()))
        // The same value again is no new entry.
        _ = try await engine.generate(.passphrase(PassphraseOptions()))
        _ = try await engine.generate(.username(UsernameOptions()))

        let history = try await engine.generatorHistory()
        #expect(history.map(\.value) == ["fakeword", "fake-fake-fake-fake-fake-fake", "Ab3Ab3Ab3Ab3Ab"])
        #expect(history.map(\.kind) == [.username, .passphrase, .password])
        #expect(history.allSatisfy { $0.date == fixedDate })
        // The store holds each entry as the crypto port has encrypted it.
        let stored = await handles.store.generatorHistory
        #expect(stored.count == 3 && stored.allSatisfy { $0.starts(with: Data("fake-encrypted-generated:".utf8)) })

        // A lock drops the history from memory; the next unlock reads it from the store.
        await engine.lock()
        #expect(await engineError { _ = try await engine.generatorHistory() } == .invalidState)
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(try await engine.generatorHistory() == history)

        try await engine.clearGeneratorHistory()
        #expect(try await engine.generatorHistory().isEmpty)
        #expect(await handles.store.generatorHistory.isEmpty)
    }

    @Test func theHistoryOfTheGeneratorHasALimitAndGoesWithTheAccount() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var options = PasswordOptions()
        // 248 values that differ: every length with and without special characters.
        for length in PasswordOptions.lengthRange {
            options.length = length
            options.special = false
            _ = try await engine.generate(.password(options))
            options.special = true
            _ = try await engine.generate(.password(options))
        }

        let history = try await engine.generatorHistory()
        #expect(history.count == 200)
        #expect(history.first?.value.count == 128 && history.first?.value.contains("#") == true)
        #expect(await handles.store.generatorHistory.count == 200)

        try await engine.logOut()
        #expect(await handles.store.generatorHistory.isEmpty)
    }

    @Test func nothingIsGeneratedForALockedVault() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        await engine.lock()
        #expect(await engineError { _ = try await engine.generate(.password(PasswordOptions())) } == .invalidState)
        #expect(await engineError { _ = try await engine.newSSHKey() } == .invalidState)
        #expect(await engineError { _ = try await engine.passwordHistory(of: "item-1") } == .invalidState)
    }

    @Test func theGeneratorOptionsAreKeptWithTheSettingsOfTheAccount() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var settings = await engine.state.settings
        #expect(settings.generator == GeneratorOptions())
        settings.generator.kind = .passphrase
        settings.generator.passphrase.words = 8
        settings.generator.password.length = 32
        try await engine.setSettings(settings)

        #expect(await handles.store.settings[FakeAccount.demo.userID]?.generator == settings.generator)
        // A file of an older version has no generator options: they are the defaults.
        let older = Data(#"{"showsWebsiteIcons":false}"#.utf8)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: older)
        #expect(decoded.generator == GeneratorOptions() && !decoded.showsWebsiteIcons)
    }

    @Test func anItemGivesItsEarlierPasswordsAndANewSSHKeyIsMade() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(try await engine.passwordHistory(of: "item-1").map(\.password) == ["fake-old-password-item-1"])
        #expect(try await engine.item(id: "item-1").passwordHistoryCount == 1)
        #expect(try await engine.passwordHistory(of: "item-2").isEmpty)
        #expect(await engineError { _ = try await engine.passwordHistory(of: "missing") } == .notFound)
        #expect(try await engine.newSSHKey().publicKey.hasPrefix("ssh-ed25519 "))
    }
}
