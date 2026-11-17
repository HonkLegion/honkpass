#if DEBUG
import AppKit
import AutoFillBridge
import EngineFakes
import ProviderUI
import SwiftUI
import VaultModel

/// Only synthetic data. Build with Release optimization and DEBUG to measure the real views.
@MainActor enum VaultPerformanceProbe {
    static var account: FakeAccount {
        var account = FakeAccount.demo
        account.contents.items = (0..<1500).map { index in
            VaultItemSummary(id: "load-\(index)", type: .login,
                             name: String(format: "Synthetic Login %04d", 1500 - index),
                             subtitle: "demo@example.test", isFavorite: index % 20 == 0,
                             fields: [.username, .password])
        }
        account.contents.sends = (0..<500).map { index in
            VaultSendSummary(id: "send-load-\(index)", type: .text,
                             name: String(format: "Synthetic Send %04d", 500 - index),
                             deletionDate: Date(timeIntervalSince1970: 1_900_000_000 + Double(index * 3600)))
        }
        return account
    }

    static func run(model: AppModel, quickAccess: QuickAccessPanelController,
                    navigation: VaultNavigation, autoFill: any AutoFillAsking) async {
        let account = account
        await measure("login") {
            try? await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
            while !model.state.session.isUnlocked { await Task.yield() }
        }
        await model.lock()
        try? await Task.sleep(for: .milliseconds(300))
        await measure("unlock") {
            try? await model.unlock(masterPassword: account.masterPassword)
            while !model.state.session.isUnlocked { await Task.yield() }
        }
        quickAccess.closesWithoutKeyboard = false
        await measure("quick-access") { quickAccess.show() }
        quickAccess.close()
        await measure("vault-search") { navigation.search = "Synthetic Login 1" }
        navigation.search = ""
        await measure("sends-open") { navigation.showSends(nil) }
        await measure("sends-menu") { navigation.openSendMenuID = "send-load-1" }
        navigation.openSendMenuID = nil
        navigation.page = .vault
        let provider = ProviderModel(request: .chooseLogin(services: []), asking: autoFill,
                                     actions: .init(openApp: { _ in }, finish: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        await measure("provider-open") {
            let host = NSHostingController(rootView: ProviderView(model: provider))
            host.sizingOptions = []
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
        }
        await measure("provider-search") { provider.search = "Synthetic Login 1" }
        await measure("provider-keyboard") { provider.move(1) }
        provider.cancel()
        window.close()
    }

    private static func measure(_ name: String, action: () async -> Void) async {
        var largestGap = Duration.zero
        var previous = ContinuousClock.now
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                largestGap = max(largestGap, previous.duration(to: now))
                previous = now
            }
        }
        let start = ContinuousClock.now
        await action()
        let command = start.duration(to: .now)
        // Include view creation and the opening animation after the engine command returns.
        try? await Task.sleep(for: .seconds(2))
        largestGap = max(largestGap, previous.duration(to: .now))
        heartbeat.cancel()
        let result = "VAULT PERF \(name) items=1500 command=\(command) settled=\(start.duration(to: .now)) mainActorMaxGap=\(largestGap)\n"
        FileHandle.standardError.write(Data(result.utf8))
    }
}
#endif
