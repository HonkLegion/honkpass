import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// The SSH agent through the engine, on fakes: the fake port has no socket, a test asks through
/// it what an SSH client would ask.
@Suite struct EngineSSHAgentTests {
    private let keyID = "item-6"
    private var keyBlob: Data { Data("fake-ssh-blob-item-6".utf8) }

    /// An unlocked engine whose agent is on, with the questions of an SSH client.
    private func makeAgent(prompt: SSHAgentPrompt, clock: any Clock<Duration> = ContinuousClock()) async throws
        -> (engine: Engine, handles: FakeHandles, client: any SSHAgentRequests) {
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)
        var settings = await engine.state.settings
        settings.sshAgent = SSHAgentSettings(isEnabled: true, prompt: prompt)
        try await engine.setSettings(settings)
        try await eventually { await handles.sshAgent.isRunning }
        let client = try #require(await handles.sshAgent.requests)
        try await eventually { await client.sshIdentities().count == 1 }
        return (engine, handles, client)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimedOut()
    }

    private func request(_ namespace: String? = nil, host: String? = nil, forwarded: Bool = false, key: Data? = nil,
                         verified: Bool = false, applicationURL: URL? = nil) -> SSHSignRequest {
        let data = Data("to-sign".utf8), blob = key ?? keyBlob
        let proof = verified ? host.map { SSHVerifiedDestination(hostFingerprint: $0, publicKeyBlob: blob, data: data, isForwarding: forwarded) } : nil
        return SSHSignRequest(publicKeyBlob: blob, data: data, processName: "ssh", isForwarding: forwarded,
                              namespace: namespace, hostFingerprint: host, verifiedDestination: proof,
                              requesterApplicationURL: applicationURL)
    }

    @Test func aKeyThatRequiresTheMasterPasswordIsNotAvailableToTheAgent() async throws {
        let (engine, handles, client) = try await makeAgent(prompt: .never)
        var contents = FakeAccount.demo.contents
        let index = try #require(contents.items.firstIndex { $0.id == keyID })
        contents.items[index] = VaultItemSummary(id: keyID, type: .sshKey, name: "Synthetic key", asksForMasterPassword: true)
        await handles.server.setContents(contents)
        try await engine.sync()
        #expect(await client.sshIdentities().isEmpty)
        #expect(await client.sshSignature(for: request()) == nil)
    }

    private var signature: Data { Data("fake-signature:item-6:to-sign".utf8) }

    @Test(arguments: [false, true])
    func anUpdateWaitsForPendingSSHConsent(isLocked: Bool) async throws {
        let (engine, _, client) = try await makeAgent(prompt: .always)
        if isLocked { await engine.lock() }
        let signing = Task { await client.sshSignature(for: request()) }
        defer { signing.cancel() }
        let state = try await nextState(of: engine) {
            isLocked ? $0.sshUnlockRequest != nil : $0.sshApproval != nil
        }
        let id = try #require(state.sshUnlockRequest?.id ?? state.sshApproval?.id)
        #expect(await engineError { try await engine.prepareForAppUpdate() } == .busy)
        #expect(await engine.state.isPreparingAppUpdate == false)
        #expect(await engine.state.session.isUnlocked == !isLocked)
        await engine.cancelSSHRequest(id: id)
        #expect(await signing.value == nil)
        try await engine.prepareForAppUpdate()
        #expect(await engine.state.isPreparingAppUpdate)
    }

    @Test func anUpdateHoldRefusesNewSSHRequestsWithoutOpeningAnUnlockPrompt() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .always)
        try await engine.prepareForAppUpdate()
        #expect(await client.sshSignature(for: request()) == nil)
        let state = await engine.state
        #expect(state.sshUnlockRequest == nil && state.sshApproval == nil && state.sshPendingRequestCount == nil)
        #expect(state.isPreparingAppUpdate && !state.session.isUnlocked)
        await engine.resumeAfterAppUpdate()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        let signing = Task { await client.sshSignature(for: request()) }
        defer { signing.cancel() }
        let approval = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await engine.answerSSHApproval(id: approval.id, isAllowed: true)
        #expect(await signing.value == signature)
    }

    @Test func theAgentRunsWhileItIsOnAndAnAccountIsLoggedIn() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await !handles.sshAgent.isRunning)
        #expect(await engine.state.settings.sshAgent == SSHAgentSettings(isEnabled: false, prompt: .always))

        var settings = await engine.state.settings
        settings.sshAgent.isEnabled = true
        try await engine.setSettings(settings)
        try await eventually { await handles.sshAgent.isRunning }
        let client = try #require(await handles.sshAgent.requests)
        // The key of the vault that is not in the trash, by its public part and the name of its item.
        try await eventually { await client.sshIdentities().count == 1 }
        #expect(await client.sshIdentities() == [SSHAgentIdentity(itemID: keyID, name: "Example SSH Key", publicKeyBlob: keyBlob,
                                                               publicKeyFingerprint: "SHA256:synthetic-" + keyID)])
        // The setting is stored with the account.
        #expect(await handles.store.settings.values.contains { $0.sshAgent.isEnabled })

        // A key that goes to the trash is no longer offered.
        try await engine.change(.moveToTrash, of: keyID)
        try await eventually { await client.sshIdentities().isEmpty }
        try await engine.change(.restore, of: keyID)
        try await eventually { await client.sshIdentities().count == 1 }

        // A lock leaves the agent and the names of its keys; a logout ends both.
        await engine.lock()
        #expect(await handles.sshAgent.isRunning)
        #expect(await client.sshIdentities().count == 1)
        try await engine.logOut()
        try await eventually { await !handles.sshAgent.isRunning }
        #expect(await client.sshIdentities().isEmpty)
        #expect(await client.sshSignature(for: request()) == nil)
    }

    @Test func turningTheAgentOffStopsItAndASocketThatCannotBeMadeIsReported() async throws {
        let (engine, handles, client) = try await makeAgent(prompt: .never)
        var settings = await engine.state.settings
        settings.sshAgent.isEnabled = false
        try await engine.setSettings(settings)
        try await eventually { await !handles.sshAgent.isRunning }
        #expect(await client.sshIdentities().isEmpty)
        #expect(await client.sshSignature(for: request()) == nil)

        await handles.sshAgent.failNextStart()
        settings.sshAgent.isEnabled = true
        try await engine.setSettings(settings)
        try await eventually { await engine.state.notices.contains(.sshAgentUnavailable) }
        #expect(await !handles.sshAgent.isRunning)
    }

    @Test func everyUseOfAKeyAsksTheUserWhoMayRefuse() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .always)

        async let first = client.sshSignature(for: request())
        let asked = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(asked.itemID == keyID && asked.keyName == "Example SSH Key" && asked.processName == "ssh")
        #expect(asked.action == .logIn && !asked.isForwarding)
        await engine.answerSSHApproval(id: asked.id, isAllowed: true)
        #expect(await first == signature)
        #expect(await engine.state.sshApproval == nil)

        // The next use asks again, and a refusal gives the client nothing.
        async let second = client.sshSignature(for: request("git", forwarded: true))
        let again = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(again.id != asked.id && again.action == .signGit && again.isForwarding)
        await engine.answerSSHApproval(id: again.id, isAllowed: false)
        #expect(await second == nil)

        // Any other namespace is "sign a message". Two questions wait one after the other.
        async let third = client.sshSignature(for: request("file"))
        let message = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(message.action == .sign)
        async let fourth = client.sshSignature(for: request())
        try await Task.sleep(for: .milliseconds(30))
        #expect(await engine.state.sshApproval?.id == message.id)
        await engine.answerSSHApproval(id: message.id, isAllowed: true)
        #expect(await third == signature)
        let last = try #require(try await nextState(of: engine) { $0.sshApproval != nil && $0.sshApproval?.id != message.id }.sshApproval)
        // A lock refuses what waits and takes the question away.
        await engine.lock()
        #expect(await fourth == nil)
        #expect(await engine.state.sshApproval == nil)
        await engine.answerSSHApproval(id: last.id, isAllowed: true)
    }

    @Test func withoutAQuestionAKeySignsAtOnceAndAnUnknownKeyNever() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .never)
        #expect(await client.sshSignature(for: request()) == signature)
        #expect(await engine.state.sshApproval == nil)
        #expect(await client.sshSignature(for: request(key: Data("another-key".utf8))) == nil)
        // A key in the trash signs nothing, also before the list of keys has followed.
        try await engine.change(.moveToTrash, of: keyID)
        #expect(await client.sshSignature(for: request()) == nil)
    }

    @Test func anAnswerIsRememberedForItsPlaceUntilTheVaultLocks() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .rememberUntilLock)
        func signs(_ request: SSHSignRequest, asking: Bool) async throws -> Data? {
            async let answer = client.sshSignature(for: request)
            if asking {
                let asked = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
                await engine.answerSSHApproval(id: asked.id, isAllowed: true)
            }
            return await answer
        }
        // Only a port-verified destination is remembered; unbound git/file data asks each time.
        #expect(try await signs(request(host: "SHA256:one", verified: true), asking: true) == signature)
        #expect(try await signs(request(host: "SHA256:one", verified: true), asking: false) == signature)
        #expect(try await signs(request(host: "SHA256:two", verified: true), asking: true) == signature)
        #expect(try await signs(request("git"), asking: true) == signature)
        #expect(try await signs(request("git"), asking: true) == signature)
        // The same server through a forwarded agent is another place; without the key of its
        // server a forwarded use is asked for every time.
        #expect(try await signs(request(host: "SHA256:one", forwarded: true, verified: true), asking: true) == signature)
        #expect(try await signs(request(host: "SHA256:one", forwarded: true, verified: true), asking: false) == signature)
        #expect(try await signs(request(forwarded: true), asking: true) == signature)
        #expect(try await signs(request(forwarded: true), asking: true) == signature)

        // A lock forgets it all.
        await engine.lock()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(try await signs(request(host: "SHA256:one", verified: true), asking: true) == signature)
    }

    @Test func clientSuppliedHostMetadataDoesNotRememberAnApproval() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .rememberUntilLock)
        async let first = client.sshSignature(for: request(host: "SHA256:public-host-key"))
        let asked = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(asked.verifiedHostFingerprint == nil)
        await engine.answerSSHApproval(id: asked.id, isAllowed: true)
        #expect(await first == signature)

        async let second = client.sshSignature(for: request(host: "SHA256:public-host-key"))
        // Give the fake signing task a turn. Lock also completes a pending approval on failure.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await engine.state.sshApproval != nil)
        await engine.lock()
        #expect(await second == nil)
    }

    @Test func aCopiedProofCannotAuthorizeDifferentDataOrForwarding() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .rememberUntilLock)
        let verified = request(host: "SHA256:one", verified: true)
        async let first = client.sshSignature(for: verified)
        let approval = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(approval.verifiedHostFingerprint == "SHA256:one")
        await engine.answerSSHApproval(id: approval.id, isAllowed: true)
        #expect(await first == signature)
        for change in 0..<3 {
            var changed = verified
            if change == 0 { changed.data = Data("different data".utf8) }
            if change == 1 { changed.isForwarding = true }
            if change == 2 { changed.flags = 1 }
            async let answer = client.sshSignature(for: changed)
            let asked = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
            #expect(asked.verifiedHostFingerprint == nil)
            await engine.answerSSHApproval(id: asked.id, isAllowed: false)
            #expect(await answer == nil)
        }
    }

    @Test func anApprovalResumedByLockCannotRepopulateTheCache() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .rememberUntilLock)
        let verified = request(host: "SHA256:one", verified: true)
        async let first = client.sshSignature(for: verified)
        let approval = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await engine.approveSSHAndLockForTest(approval.id)
        #expect(await first == nil)
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        async let next = client.sshSignature(for: verified)
        let asked = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await engine.answerSSHApproval(id: asked.id, isAllowed: false)
        #expect(await next == nil)
    }

    @Test func settingsAndKeyEligibilityInvalidatePendingAndRememberedApprovals() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .rememberUntilLock)
        let verified = request(host: "SHA256:one", verified: true)
        async let first = client.sshSignature(for: verified)
        let approval = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await engine.answerSSHApproval(id: approval.id, isAllowed: true)
        #expect(await first == signature)
        var settings = await engine.state.settings
        settings.sshAgent.isEnabled = false
        try await engine.setSettings(settings)
        settings.sshAgent.isEnabled = true
        try await engine.setSettings(settings)
        async let second = client.sshSignature(for: verified)
        _ = try await nextState(of: engine) { $0.sshApproval != nil }
        settings.sshAgent.prompt = .never
        try await engine.setSettings(settings)
        #expect(await second == nil)
        #expect(await client.sshSignature(for: verified) == signature)
        settings.sshAgent.prompt = .rememberUntilLock
        try await engine.setSettings(settings)
        async let third = client.sshSignature(for: verified)
        _ = try await nextState(of: engine) { $0.sshApproval != nil }
        try await engine.change(.moveToTrash, of: keyID)
        #expect(await third == nil)
        #expect(await client.sshSignature(for: verified) == nil)
    }

    @Test func cancellingOneQuestionLeavesTheSuccessorPending() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .always)
        let first = Task { await client.sshSignature(for: request()) }
        let original = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        #expect(original.publicKeyFingerprint == "SHA256:synthetic-" + keyID)
        let second = Task { await client.sshSignature(for: request("git")) }
        _ = try await nextState(of: engine) { $0.sshPendingRequestCount == 2 }
        await engine.cancelSSHRequest(id: original.id)
        #expect(await first.value == nil)
        let next = try #require(try await nextState(of: engine) { $0.sshApproval?.id != original.id }.sshApproval)
        await engine.answerSSHApproval(id: original.id, isAllowed: true)
        #expect(await engine.state.sshApproval?.id == next.id)
        #expect(await engine.state.sshPendingRequestCount == 1)
        await engine.answerSSHApproval(id: next.id, isAllowed: true)
        #expect(await second.value == signature)
    }

    @Test func cancelledUnlockAndApprovalTasksRemoveTheirOwnWindowState() async throws {
        let (engine, _, client) = try await makeAgent(prompt: .always)
        await engine.lock()
        let applicationURL = URL(fileURLWithPath: "/Applications/Example Requester.app")
        let waiting = Task { await client.sshSignature(for: request(applicationURL: applicationURL)) }
        let locked = try await nextState(of: engine) { $0.sshUnlockRequest != nil }
        #expect(locked.vault == .empty && locked.sshApproval == nil && locked.sshUnlockRequest?.processName == "ssh")
        #expect(locked.sshUnlockRequest?.requesterApplicationURL == applicationURL)
        waiting.cancel()
        #expect(await waiting.value == nil)
        _ = try await nextState(of: engine) { $0.sshUnlockRequest == nil }
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        let asking = Task { await client.sshSignature(for: request(applicationURL: applicationURL)) }
        let presented = try await nextState(of: engine) { $0.sshApproval != nil }
        #expect(presented.sshApproval?.requesterApplicationURL == applicationURL)
        asking.cancel()
        #expect(await asking.value == nil)
        _ = try await nextState(of: engine) { $0.sshApproval == nil && $0.sshPendingRequestCount == nil }
    }

    @Test func anExpiredApprovalCannotGrantALaterQuestion() async throws {
        let clock = ManualClock()
        let (engine, _, client) = try await makeAgent(prompt: .always, clock: clock)
        let asking = Task { await client.sshSignature(for: request()) }
        let first = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        #expect(await asking.value == nil)
        let second = Task { await client.sshSignature(for: request()) }
        let next = try #require(try await nextState(of: engine) { $0.sshApproval != nil }.sshApproval)
        await engine.answerSSHApproval(id: first.id, isAllowed: true)
        #expect(await engine.state.sshApproval?.id == next.id)
        await engine.cancelSSHRequest(id: next.id)
        #expect(await second.value == nil)
    }

    @Test func aLockedVaultIsWaitedForAndThenGivenUp() async throws {
        let clock = ManualClock()
        let (engine, _, client) = try await makeAgent(prompt: .never, clock: clock)
        await engine.lock()

        // The client waits, the user is told, and the unlock lets the key sign.
        async let first = client.sshSignature(for: request())
        _ = try await nextState(of: engine) { $0.notices.contains(.sshAgentUnlockRequired) }
        await engine.dismiss(.sshAgentUnlockRequired)
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(await first == signature)

        // A vault that stays locked for a minute refuses the client and says so.
        await engine.lock()
        async let second = client.sshSignature(for: request())
        _ = try await nextState(of: engine) { $0.notices.contains(.sshAgentUnlockRequired) }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        #expect(await second == nil)
        #expect(await engine.state.notices.contains(.sshAgentUnlockTimedOut))
    }
}

private extension Engine {
    /// One actor turn deterministically exercises the approval-resumption/lock race.
    func approveSSHAndLockForTest(_ id: UUID) {
        answerSSHApproval(id: id, isAllowed: true)
        lock()
    }
}
