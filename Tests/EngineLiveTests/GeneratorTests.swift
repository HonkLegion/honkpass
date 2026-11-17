import Engine
import EngineLive
import Foundation
import Testing
import VaultModel

/// The generators of the SDK behind the crypto port. They need no server.
@Suite struct GeneratorTests {
    let crypto = BitwardenCrypto()

    @Test func aPasswordHasTheLengthAndTheCharactersThatWereAskedFor() async throws {
        var options = PasswordOptions()
        options.length = 40
        options.special = true
        options.minNumbers = 5
        options.minSpecial = 4
        let password = try await crypto.generate(.password(options))
        #expect(password.count == 40)
        #expect(password.filter(\.isNumber).count >= 5)
        #expect(password.filter { "!@#$%^&*".contains($0) }.count >= 4)
        #expect(password.contains(where: \.isUppercase) && password.contains(where: \.isLowercase))
        #expect(try await crypto.generate(.password(options)) != password)

        options = PasswordOptions()
        options.length = 30
        options.uppercase = false
        options.numbers = false
        options.minNumbers = 0
        let letters = try await crypto.generate(.password(options.normalized))
        #expect(letters.count == 30 && letters.allSatisfy { $0.isLowercase && $0.isASCII })
    }

    @Test func aPassphraseHasItsWordsSeparatorAndNumber() async throws {
        var options = PassphraseOptions()
        options.words = 5
        options.separator = "."
        options.capitalize = true
        options.includeNumber = true
        let words = try await crypto.generate(.passphrase(options)).split(separator: ".")
        #expect(words.count == 5)
        #expect(words.allSatisfy { $0.first?.isUppercase == true })
        #expect(words.filter { $0.contains(where: \.isNumber) }.count == 1)
    }

    @Test func aUserNameIsAWordOrAnAddressOfTheGivenMailbox() async throws {
        var options = UsernameOptions()
        options.capitalize = true
        options.includeNumber = true
        let word = try await crypto.generate(.username(options))
        #expect(word.first?.isUppercase == true && word.contains(where: \.isNumber))

        options.kind = .plusAddressedEmail
        options.email = "test.user@example.com"
        let subaddress = try await crypto.generate(.username(options))
        #expect(subaddress.hasPrefix("test.user+") && subaddress.hasSuffix("@example.com"))

        options.kind = .catchallEmail
        options.domain = "example.com"
        let catchall = try await crypto.generate(.username(options))
        #expect(catchall.hasSuffix("@example.com") && catchall.count > "@example.com".count)
    }

    @Test func aCatchAllAddressCanStartWithTheNameOfAWebsite() async throws {
        var options = UsernameOptions()
        options.kind = .catchallEmail
        options.domain = "example.org"
        #expect(try await crypto.generate(.username(options, website: "shop.example.com")) == "shop.example.com@example.org")
        // Without a website the SDK picks random characters.
        let random = try await crypto.generate(.username(options))
        #expect(random.hasSuffix("@example.org") && !random.hasPrefix("shop.example.com"))
    }

    @Test func aPrivateKeyTextBecomesAnSSHKey() async throws {
        // A key the SDK has just made is the text to import: no key lies in the repository.
        let made = try await crypto.newSSHKey()
        let imported = try await crypto.importSSHKey(made.privateKey, password: nil)
        #expect(imported.publicKey == made.publicKey && imported.fingerprint == made.fingerprint)

        await #expect(throws: EngineError.sshKeyImport(.notAKey)) {
            _ = try await crypto.importSSHKey("just some text", password: nil)
        }
    }

    /// The encrypted key is made by ssh-keygen in a temporary folder and deleted with it.
    @Test func anEncryptedKeyNeedsItsPassword() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passvault-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "synthetic-key")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "synthetic-passphrase", "-C", "synthetic", "-f", file.path]
        try keygen.run()
        keygen.waitUntilExit()
        try #require(keygen.terminationStatus == 0)
        let text = try String(contentsOf: file, encoding: .utf8)
        let publicKey = try String(contentsOf: folder.appending(path: "synthetic-key.pub"), encoding: .utf8)

        await #expect(throws: EngineError.sshKeyImport(.passwordRequired)) {
            _ = try await crypto.importSSHKey(text, password: nil)
        }
        await #expect(throws: EngineError.sshKeyImport(.wrongPassword)) {
            _ = try await crypto.importSSHKey(text, password: "another-passphrase")
        }
        let key = try await crypto.importSSHKey(text, password: "synthetic-passphrase")
        // The public key of ssh-keygen is "ssh-ed25519 <key> <comment>".
        #expect(publicKey.hasPrefix(key.publicKey.split(separator: " ").prefix(2).joined(separator: " ")))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
    }

    @Test func aNewSSHKeyHasItsThreeParts() async throws {
        let key = try await crypto.newSSHKey()
        #expect(key.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(try await crypto.newSSHKey().privateKey != key.privateKey)
    }
}
