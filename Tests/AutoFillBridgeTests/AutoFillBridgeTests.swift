@testable import AutoFillBridge
import Foundation
import Testing
import VaultModel

/// The connection between the app and the AutoFill extension. These tests run in one process
/// that no team has signed: they try the messages, the listener and the relay, and that an
/// unsigned process gets nowhere. What signatures and the sandbox do is tried with the built app.
@Suite struct AutoFillBridgeTests {
    private struct Answers: AutoFillAnswering {
        func answer(_ request: AutoFillRequest) async -> AutoFillResponse {
            switch request {
            case .status: .status(AutoFillStatus(vault: .unlocked, account: "user@example.com"))
            case .logins(let services): .logins(services.map { AutoFillLogin(itemID: $0, name: "Login of " + $0, username: "user") })
            case .password(let itemID): itemID == "1" ? .password(AutoFillPassword(username: "user", password: "synthetic-password"))
                : .failure(.notFound)
            case .unlock: .failure(.wrongPin)
            default: .failure(.unavailable)
            }
        }
    }

    @Test func aPartIsKnownByItsIdentifierAndItsTeam() throws {
        let peers = try AutoFillPeers(team: "ABCDE12345", appIdentifier: "com.example.vault")
        #expect(peers.identifier(of: .app) == "com.example.vault")
        #expect(peers.identifier(of: .provider) == "com.example.vault.provider")
        #expect(peers.identifier(of: .agent) == "com.example.vault.rendezvous")
        #expect(peers.requirement(for: .provider)
            == "anchor apple generic and identifier \"com.example.vault.provider\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        // The services begin with the App Group, which lets a process in a sandbox find them.
        #expect(peers.service(.publish) == "ABCDE12345.com.example.vault.bridge.publish")
        #expect(peers.service(.lookup) == "ABCDE12345.com.example.vault.bridge.lookup")
        #expect(peers.agentLabel == "com.example.vault.bridge")
        #expect(peers.agentPropertyList == "com.example.vault.bridge.plist")

        // Nothing that could say more in a requirement than a name.
        for (team, identifier) in [("ABCDE1234", "com.example.vault"), ("ABCDE1234\"", "com.example.vault"),
                                   ("ABCDE12345", "com.example\" or anchor apple"), ("ABCDE12345", ""), ("ABCDE12345", ".com.example")] {
            #expect(throws: AutoFillBridgeError.notSigned) { try AutoFillPeers(team: team, appIdentifier: identifier) }
        }
    }

    @Test func aProcessThatNoTeamSignedHasNoPeers() {
        for part in AutoFillPeers.Part.allCases {
            #expect(throws: AutoFillBridgeError.notSigned) { try AutoFillPeers.current(as: part) }
        }
    }

    @Test func aQuestionCrossesTheConnectionAndItsAnswerComesBack() async throws {
        let host = AutoFillHost(uncheckedAnswering: Answers())
        #expect(await host.start() == .ready)
        let client = AutoFillClient(uncheckedEndpoint: try #require(host.endpoint))

        #expect(await client.ask(.status) == .status(AutoFillStatus(vault: .unlocked, account: "user@example.com")))
        #expect(await client.ask(.logins(services: ["example.com"]))
            == .logins([AutoFillLogin(itemID: "example.com", name: "Login of example.com", username: "user")]))
        #expect(await client.ask(.password(itemID: "1")) == .password(AutoFillPassword(username: "user", password: "synthetic-password")))
        #expect(await client.ask(.password(itemID: "2")) == .failure(.notFound))
        #expect(await client.ask(.unlock(pin: "0000")) == .failure(.wrongPin))

        // A host that has stopped answers nobody: the extension hears "unavailable".
        host.stop()
        #expect(await client.ask(.status) == .failure(.unavailable))
    }

    @Test func theAgentKeepsTheNewestEndAndDropsItWithItsOwner() {
        let relay = EndpointRelay()
        let first = NSXPCListener.anonymous().endpoint, second = NSXPCListener.anonymous().endpoint
        let app = UUID(), appStartedAgain = UUID()
        #expect(relay.endpoint == nil)

        relay.publish(Endpoint(value: first), owner: app)
        #expect(relay.endpoint?.value === first)
        // The app was started again while its old connection is still closing.
        relay.publish(Endpoint(value: second), owner: appStartedAgain)
        relay.withdraw(owner: app)
        #expect(relay.endpoint?.value === second)
        relay.withdraw(owner: appStartedAgain)
        #expect(relay.endpoint == nil)
    }

    @Test func aMessageIsReadOnlyWhenItIsWholeAndNotTooLarge() throws {
        let questions: [AutoFillRequest] = [.status, .logins(services: []), .logins(services: ["a.example", "https://b.example/x"]),
                                            .password(itemID: "id"), .unlock(pin: "4812"),
                                            .unlockWithTouchID(reason: "unlock your vault")]
        for question in questions {
            #expect(Wire.decode(AutoFillRequest.self, from: try #require(Wire.encode(question))) == question)
        }
        let answers: [AutoFillResponse] = [.status(AutoFillStatus(vault: .locked, canUnlockWithPin: true, account: "user@example.com")),
                                           .status(AutoFillStatus(vault: .locked, canUnlockWithTouchID: true, asksForTouchIDAtOnce: true)),
                                           .failure(.touchIDFailed),
                                           .logins([AutoFillLogin(itemID: "1", name: "A", username: "u", asksForMasterPassword: true)]),
                                           .password(AutoFillPassword(username: "u", password: "p")), .failure(.masterPasswordRequired)]
        for answer in answers {
            #expect(Wire.decode(AutoFillResponse.self, from: try #require(Wire.encode(answer))) == answer)
        }
        #expect(Wire.decode(AutoFillRequest.self, from: nil) == nil)
        #expect(Wire.decode(AutoFillRequest.self, from: Data("not a message".utf8)) == nil)
        #expect(Wire.encode(AutoFillRequest.logins(services: Array(repeating: String(repeating: "a", count: 1_000), count: 100))) == nil)
        #expect(Wire.decode(AutoFillRequest.self, from: Data(count: Wire.maximumBytes + 1)) == nil)
    }
}
