import AppKit
import Engine
@testable import EngineLive
import Foundation
import Testing
import VaultModel

/// Who signed an app, as the code signing of the system says it. The tests read apps that
/// every Mac has; they start none.
@Suite struct AppSignatureTests {
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    private let safari = URL(fileURLWithPath: "/Applications/Safari.app")

    @Test func anAppOfAppleIsSignedByApple() async throws {
        let app = try #require(AppSignature.ofApp(at: textEdit))
        #expect(app.address == "osxapp://com.apple.TextEdit:apple")
        // The port says the same, and that it is no browser.
        #expect(await MacAppSignatures().app(at: textEdit) == SignedApp(address: app, isBrowser: false))
        // The system finds the app again by its address, and not under another developer.
        #expect(InstalledApps.location(of: app)?.lastPathComponent == "TextEdit.app")
        let impostor = try #require(AppAddress(bundleID: "com.apple.TextEdit", developer: "ABCDE12345"))
        #expect(InstalledApps.location(of: impostor) == nil)
        #expect(InstalledApps.location(of: try #require(AppAddress("osxapp://test.passvault.missing:ABCDE12345"))) == nil)
    }

    @Test func aBrowserIsKnownAsOne() async throws {
        let app = try #require(await MacAppSignatures().app(at: safari))
        #expect(app.address.address == "osxapp://com.apple.Safari:apple" && app.isBrowser)
    }

    @Test func whatIsNoSignedAppHasNoAddress() async throws {
        // No app at all.
        #expect(AppSignature.ofApp(at: URL(fileURLWithPath: "/System/Applications")) == nil)
        #expect(AppSignature.ofApp(at: URL(fileURLWithPath: "/usr/bin/true")) == nil)
        #expect(AppSignature.ofApp(at: URL(fileURLWithPath: "/nonexistent/Example.app")) == nil)
        #expect(AppSignature.ofApp(at: URL(string: "https://example.com/Example.app")!) == nil)
        // A folder that calls itself an app and has no signature.
        let folder = FileManager.default.temporaryDirectory.appending(path: "passvault-test-\(UUID().uuidString)")
        let fake = folder.appending(path: "Example Unsigned.app/Contents")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.passvault.unsigned", "CFBundleName": "Example Unsigned",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: fake.appending(path: "Info.plist"))
        #expect(AppSignature.ofApp(at: fake.deletingLastPathComponent()) == nil)
        #expect(await MacAppSignatures().app(at: fake.deletingLastPathComponent()) == nil)
    }

    @Test func aRunningAppIsKnownByTheCodeThatRuns() throws {
        // The Finder runs in every session of a user. Without one, as on a build machine, there is nothing to look at.
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let app = try #require(AppSignature.ofProcess(finder.processIdentifier))
        #expect(app.address == "osxapp://com.apple.finder:apple")
        // A process that is not there.
        #expect(AppSignature.ofProcess(-1) == nil)
    }

    @Test func aRunningSelectionUsesAnOpaqueIDAndRechecksItsProcess() async throws {
        let port = MacAppSignatures()
        let apps = await port.runningApps()
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
           finder.launchDate == nil {
            #expect(!apps.contains { $0.address.bundleID == "com.apple.finder" })
        }
        #expect(await port.app(runningID: UUID()) == nil)
        #expect(!apps.contains { $0.address.bundleID == "com.apple.Safari" })
        // Standard system apps need not run on a build machine. Do not launch one for this test.
        let systemApps: Set<String> = ["com.apple.finder", "com.apple.calculator", "com.apple.TextEdit"]
        guard let selection = apps.first(where: { systemApps.contains($0.address.bundleID) }) else { return }
        let signed = await port.app(runningID: selection.id)
        #expect(signed?.address == selection.address && signed?.isBrowser == false)
    }

    @Test func theRequirementNamesTheIdentifierAndTheDeveloper() throws {
        let ofTeam = try #require(AppAddress("osxapp://com.example.Mail:ABCDE12345"))
        #expect(AppSignature.requirementText(for: ofTeam) == "anchor apple generic and identifier \"com.example.Mail\" and "
            + "(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[subject.OU] = \"ABCDE12345\")")
        let ofApple = try #require(AppAddress("osxapp://com.apple.TextEdit:apple"))
        #expect(AppSignature.requirementText(for: ofApple) == "anchor apple and identifier \"com.apple.TextEdit\"")
    }

    @Test func onlyKnownBrowserPublishersCanSupplyWebsiteOrigins() throws {
        let page = "https://account.example.test/login"
        let browsers = [
            ("com.apple.Safari", "apple"), ("org.mozilla.firefox", "43AQ936H96"),
            ("com.google.Chrome", "EQHXZ8M8AV"), ("io.ungoogled-software.ungoogled-chromium", "B9A88FL5XJ"),
        ]
        for (bundleID, developer) in browsers {
            let signed = try #require(AppAddress(bundleID: bundleID, developer: developer))
            for registered in [false, true] {
                let origin = FillOrigin(bundleID: bundleID, signature: signed, isRegisteredBrowser: registered, reportedWebsite: page)
                #expect(origin.website == page && origin.app == nil)
                // Neither a copied bundle name nor registering an HTTP handler authenticates its publisher.
                let impostor = try #require(AppAddress(bundleID: bundleID, developer: "OTHER12345"))
                #expect(FillOrigin(bundleID: bundleID, signature: impostor, isRegisteredBrowser: registered, reportedWebsite: page).website == nil)
                #expect(FillOrigin(bundleID: bundleID, signature: nil, isRegisteredBrowser: registered, reportedWebsite: page).website == nil)
            }
        }
        let chromium = try #require(AppAddress(bundleID: browsers[3].0, developer: browsers[3].1))
        #expect(FillOrigin.isTrustedBrowser(bundleID: "org.chromium.Chromium", signature: chromium))
        #expect(!FillOrigin.isTrustedBrowser(bundleID: "com.attacker.Browser", signature: chromium))
        let unknown = try #require(AppAddress(bundleID: "com.example.Browser", developer: "B9A88FL5XJ"))
        #expect(FillOrigin(bundleID: unknown.bundleID, signature: unknown, isRegisteredBrowser: true, reportedWebsite: page)
            == FillOrigin(bundleID: unknown.bundleID, signature: nil, isRegisteredBrowser: true, reportedWebsite: nil))
    }

    @Test func aNativeWebViewKeepsOnlyItsExplicitSignerAssociation() throws {
        let signed = try #require(AppAddress("osxapp://com.example.Native:ABCDE12345"))
        let page = "https://account.example.test/login"
        let vault = VaultContents(items: [
            VaultItemSummary(id: "web", type: .login, name: "Web", websites: [.init(address: page)]),
            VaultItemSummary(id: "native", type: .login, name: "Native", websites: [.init(address: signed.address, match: .never)]),
        ], folders: [])
        let native = FillOrigin(bundleID: signed.bundleID, signature: signed, isRegisteredBrowser: false, reportedWebsite: page)
        #expect(native.website == nil && native.app == signed)
        #expect(vault.logins(ofPage: native.website, app: native.app).map(\.id) == ["native"])
        let unsigned = FillOrigin(bundleID: signed.bundleID, signature: nil, isRegisteredBrowser: false, reportedWebsite: page)
        #expect(vault.logins(ofPage: unsigned.website, app: unsigned.app).isEmpty)
        // No website is offered to the save-and-fill path for either kind of native capture.
        #expect(unsigned.website == nil)
    }

    @Test func nestedFormsUseTheirOwnPageAndNeverTheContainingPage() throws {
        let safari = try #require(AppAddress("osxapp://com.apple.Safari:apple"))
        let pages = ["parent": "https://parent.example.test", "child": "https://child.example.test"]
        let shared = try #require(FillFormPage(usernamePage: "child", passwordPage: "child", equal: ==))
        #expect(shared.page == "child" && shared.matches("child", equal: ==))
        #expect(!shared.matches("parent", equal: ==))
        let origin = FillOrigin(bundleID: safari.bundleID, signature: safari, isRegisteredBrowser: true,
                                reportedWebsite: shared.page.flatMap { pages[$0] })
        #expect(origin.website == pages["child"] && origin.website != pages["parent"])
        // Even two frames reporting the same URL must not be merged into one form.
        #expect(FillFormPage(usernamePage: "frame-one", passwordPage: "frame-two", equal: ==) == nil)
        #expect(FillFormPage(usernamePage: "child", passwordPage: nil, equal: ==) == nil)
        let native = try #require(FillFormPage<String>(usernamePage: nil, passwordPage: nil, equal: ==))
        #expect(native.page == nil && native.matches(nil, equal: ==))
    }
}
