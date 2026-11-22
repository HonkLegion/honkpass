@testable import EngineLive
import Foundation
import Testing

@Suite struct AppUpdateTests {
    private var info: [String: Any] {
        ["CFBundleIdentifier": "cz.honklegion.honkpass",
         "SUFeedURL": AppUpdateConfiguration.feedURL,
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "SUVerifyUpdateBeforeExtraction": true,
         "SUAllowsAutomaticUpdates": true, "SUAutomaticallyUpdate": false,
         "SUEnableSystemProfiling": false]
    }

    @Test func rejectsMissingKeysAndUnexpectedReleaseIdentity() {
        #expect(AppUpdateConfiguration.isReady(info))
        for key in info.keys {
            var value = info
            value.removeValue(forKey: key)
            #expect(!AppUpdateConfiguration.isReady(value))
        }
        for (key, badValue) in [
            ("CFBundleIdentifier", "cz.honklegion.honkdeck"),
            ("SUFeedURL", "http://update.honklegion.cz/apps/honkpass/appcast.xml"),
            ("SUPublicEDKey", "$(HONKPASS_SPARKLE_PUBLIC_KEY)"),
            ("SUPublicEDKey", Data(repeating: 0, count: 32).base64EncodedString())
        ] {
            var value = info
            value[key] = badValue
            #expect(!AppUpdateConfiguration.isReady(value))
        }
    }

    @MainActor @Test func noUpdateDoesNotTouchTheSessionAndRecoveryRunsOnce() async {
        var preparations = 0
        var recoveries = 0
        let gate = AppUpdateInstallationGate(prepare: { preparations += 1; return true },
                                            recover: { recoveries += 1 })
        await gate.finish()
        #expect(recoveries == 0)
        #expect(await gate.begin())
        #expect(await gate.begin())
        #expect(preparations == 1)
        await gate.finish()
        await gate.finish()
        #expect(recoveries == 1)
        #expect(!gate.prepared)
    }

    @MainActor @Test func cancellationWhilePreparingReleasesALateHold() async {
        var reply: CheckedContinuation<Bool, Never>?
        var recoveries = 0
        let gate = AppUpdateInstallationGate(prepare: {
            await withCheckedContinuation { reply = $0 }
        }, recover: { recoveries += 1 })
        let preparation = Task { await gate.begin() }
        while reply == nil { await Task.yield() }
        await gate.finish()
        reply?.resume(returning: true)
        #expect(await preparation.value == false)
        #expect(recoveries == 1)
        #expect(!gate.isBusy)
    }

    @MainActor @Test func blockedInstallationCanBeRetried() async {
        var ready = false
        let gate = AppUpdateInstallationGate(prepare: { ready }, recover: {})
        #expect(await gate.begin() == false)
        ready = true
        #expect(await gate.begin())
    }
}
