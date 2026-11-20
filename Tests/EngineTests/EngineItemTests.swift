import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineItemTests {
    @Test func quittingClearsOnlyThePendingClipboardValue() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.copy(.password, of: "item-1")
        await engine.clearPendingClipboard()
        #expect(await handles.clipboard.text == nil)
        try await engine.copy(.password, of: "item-1")
        await handles.clipboard.copy("new synthetic text", isSensitive: false)
        await engine.clearPendingClipboard()
        #expect(await handles.clipboard.text == "new synthetic text")
    }

    @Test func anItemOpensOnlyWhileTheVaultIsUnlocked() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let item = try await engine.item(id: "item-1")
        #expect(item.name == "Example Mail")
        #expect(item.value(of: .password) == "fake-password-item-1")

        await engine.lock()
        #expect(await engineError { _ = try await engine.item(id: "item-1") } == .invalidState)
        #expect(await engineError { try await engine.copy(.password, of: "item-1") } == .invalidState)
    }

    @Test func aLeakedPasswordIsAskedOnlyWhenTheUserAsksAndWhileUnlocked() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        // Logging in, syncing and opening items ask the service nothing.
        _ = try await engine.item(id: "item-1")
        #expect(await handles.leaks.checkCount == 0)

        #expect(try await engine.timesLeaked(password: "password") == 52_256_179)
        #expect(try await engine.timesLeaked(password: "a-fake-password-nobody-knows") == 0)
        #expect(await engineError { _ = try await engine.timesLeaked(password: "") } == .invalidState)
        #expect(await handles.leaks.checkCount == 2)

        // A service that does not answer is an error, never "not leaked".
        await handles.leaks.goOffline()
        #expect(await engineError { _ = try await engine.timesLeaked(password: "password") } == .serverUnreachable)

        await engine.lock()
        #expect(await engineError { _ = try await engine.timesLeaked(password: "password") } == .invalidState)
        #expect(await handles.leaks.checkCount == 3)
    }

    @Test func anUnknownItemOrFieldIsNotFound() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(await engineError { _ = try await engine.item(id: "missing") } == .notFound)
        // The demo shop login has no verification code.
        #expect(await engineError { try await engine.copy(.verificationCode, of: "item-2") } == .notFound)
        #expect(await engineError { try await engine.copy(.cardNumber, of: "item-1") } == .notFound)
    }

    @Test func aCopiedValueLeavesTheClipboardAfterFiveMinutes() async throws {
        let clock = ManualClock()
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)

        try await engine.copy(.password, of: "item-1")
        #expect(await handles.clipboard.text == "fake-password-item-1")
        #expect(await handles.clipboard.wasSensitive)
        await clock.waitForSleeper()

        clock.advance(by: .seconds(299))
        for _ in 0..<20 { await Task.yield() }
        #expect(await handles.clipboard.text == "fake-password-item-1")

        clock.advance(by: .seconds(1))
        for _ in 0..<200 where await handles.clipboard.text != nil { await Task.yield() }
        #expect(await handles.clipboard.text == nil)
    }

    @Test func thePartsOfAnSSHKeyAndOfAnIdentityAreCopied() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        try await engine.copy(.sshPublicKey, of: "item-6")
        #expect(await handles.clipboard.text == "fake-public-key")
        #expect(await handles.clipboard.wasSensitive)
        try await engine.copy(.sshFingerprint, of: "item-6")
        #expect(await handles.clipboard.text == "SHA256:fake")
        try await engine.copy(.sshKey, of: "item-6")
        #expect(await handles.clipboard.text == "fake-private-key")
        try await engine.copy(.identityEmail, of: "item-4")
        #expect(await handles.clipboard.text == "fake.person@example.com")
        #expect(await handles.clipboard.wasSensitive)
        // A field the item does not have is not copied, and a field of another type neither.
        #expect(await engineError { try await engine.copy(.identityPhone, of: "item-4") } == .notFound)
        #expect(await engineError { try await engine.copy(.sshPublicKey, of: "item-4") } == .notFound)
        #expect(await handles.clipboard.text == "fake.person@example.com")
        // A user name is no secret, of a login or of an identity.
        #expect(ItemField.identityUsername.isPublic && ItemField.username.isPublic && !ItemField.identityEmail.isPublic)
    }

    @Test func aLaterCopyIsNotClearedByTheTimerOfAnEarlierOne() async throws {
        let clock = ManualClock()
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)

        try await engine.copy(.password, of: "item-1")
        await clock.waitForSleeper()
        clock.advance(by: .seconds(200))
        try await engine.copy(.username, of: "item-1")
        #expect(await !handles.clipboard.wasSensitive)
        await clock.waitForSleeper()

        clock.advance(by: .seconds(200))
        for _ in 0..<20 { await Task.yield() }
        #expect(await handles.clipboard.text == "demo@passvault.test")
    }

    @Test func aTextOfAnOpenItemIsCopiedUnderTheSameRules() async throws {
        let clock = ManualClock()
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)

        try await engine.copy(text: "C-000123", isSensitive: false)
        #expect(await handles.clipboard.text == "C-000123")
        #expect(await !handles.clipboard.wasSensitive)
        await clock.waitForSleeper()
        clock.advance(by: .seconds(300))
        for _ in 0..<200 where await handles.clipboard.text != nil { await Task.yield() }
        #expect(await handles.clipboard.text == nil)

        await engine.lock()
        #expect(await engineError { try await engine.copy(text: "secret", isSensitive: true) } == .invalidState)
        #expect(await handles.clipboard.text == nil)
    }

    @Test func aWebsitePictureIsFetchedOnceForEachHost() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await engine.websiteIcon(host: "mail.example") == Data("fake-icon-mail.example".utf8))
        #expect(await engine.websiteIcon(host: "mail.example") != nil)
        #expect(await engine.websiteIcon(host: "unknown.test") == nil)
        #expect(await engine.websiteIcon(host: "unknown.test") == nil)
        #expect(await handles.server.iconRequests == ["mail.example", "unknown.test"])

        await engine.lock()
        #expect(await engine.websiteIcon(host: "other.example") == nil)
        #expect(await handles.server.iconRequests.count == 2)
    }

    @Test func theVerificationCodeAndTheMasterPasswordCheck() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(try await engine.verificationCode(for: "item-1") == VerificationCode(code: "123456", period: 30))
        #expect(await engine.isMasterPassword(FakeAccount.demo.masterPassword))
        #expect(await !engine.isMasterPassword("wrong"))
    }
}
