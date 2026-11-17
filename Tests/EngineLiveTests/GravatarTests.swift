@testable import EngineLive
import Foundation
import Testing

@Suite struct GravatarTests {
    private let email = "demo@vault.example"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

    @Test func pictureSurvivesRestartWithoutAnotherRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gravatar-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = AvatarTransport(response: (png, 200))
        let date = date
        let first = Gravatar(directory: directory, now: { date }, fetch: { await transport.fetch($0) })
        #expect(await first.image(email: email) == png)
        let restarted = Gravatar(directory: directory, now: { date.addingTimeInterval(86400) }, fetch: { await transport.fetch($0) })
        #expect(await restarted.image(email: email.uppercased()) == png)
        #expect(await transport.requests == 1)
        #expect(await transport.sentCredentials == false)
    }

    @Test func expiredPictureRefreshesAndOfflineKeepsTheOldOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gravatar-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = date
        let transport = AvatarTransport(response: (png, 200))
        let first = Gravatar(directory: directory, now: { date }, fetch: { await transport.fetch($0) })
        #expect(await first.image(email: email) == png)
        await transport.setResponse(nil)
        let later = date.addingTimeInterval(8 * 86400)
        let offline = Gravatar(directory: directory, now: { later }, fetch: { await transport.fetch($0) })
        #expect(await offline.image(email: email) == png)
        let restarted = Gravatar(directory: directory, now: { later.addingTimeInterval(60) }, fetch: { await transport.fetch($0) })
        #expect(await restarted.image(email: email) == png)
        #expect(await transport.requests == 2)
        await transport.setResponse((Data(), 404))
        let refreshed = Gravatar(directory: directory, now: { later.addingTimeInterval(901) }, fetch: { await transport.fetch($0) })
        #expect(await refreshed.image(email: email) == nil)
        #expect(await transport.requests == 3)
    }

    @Test func missingPictureIsCachedAndRetriedAfterTwelveHours() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gravatar-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = date
        let transport = AvatarTransport(response: (Data(), 404))
        let first = Gravatar(directory: directory, now: { date }, fetch: { await transport.fetch($0) })
        #expect(await first.image(email: email) == nil)
        let restarted = Gravatar(directory: directory, now: { date.addingTimeInterval(3600) }, fetch: { await transport.fetch($0) })
        #expect(await restarted.image(email: email) == nil)
        #expect(await transport.requests == 1)
        await transport.setResponse((png, 200))
        let later = Gravatar(directory: directory, now: { date.addingTimeInterval(13 * 3600) }, fetch: { await transport.fetch($0) })
        #expect(await later.image(email: email) == png)
        #expect(await transport.requests == 2)
    }

    @Test func normalizesEmailAndRequestsOnlyItsHash() {
        let url = Gravatar.url(email: " MyEmailAddress@example.com \n")
        #expect(url.absoluteString == "https://www.gravatar.com/avatar/84059b07d4be67b806386c0aad8070a23f18836bbaae342275dc0a83414c32ee?s=96&d=404&r=g")
        #expect(!url.absoluteString.contains("@"))
    }

    @Test func rejectsErrorPagesAndOversizedImages() {
        #expect(!Gravatar.isAvatar(Data("<html>Not found</html>".utf8)))
        var oversized = Data([0xff, 0xd8, 0xff])
        oversized.append(Data(repeating: 0, count: 262_144))
        #expect(!Gravatar.isAvatar(oversized))
    }
}

private actor AvatarTransport {
    var requests = 0
    var sentCredentials = false
    private var response: (Data, Int)?
    init(response: (Data, Int)?) { self.response = response }
    func setResponse(_ response: (Data, Int)?) { self.response = response }
    func fetch(_ request: URLRequest) -> (Data, Int)? {
        requests += 1
        sentCredentials = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "Cookie") != nil || request.httpBody != nil
        return response
    }
}
