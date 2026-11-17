import EngineLive
import Foundation

// Fills the local development server with the synthetic test accounts.
// Usage: swift run passvault-seed                     the accounts of support/vaultwarden
//        swift run passvault-seed authenticator-code  the current code of the two-step account's authenticator app

let folder = URL(fileURLWithPath: "support/vaultwarden")
do {
    let twoStep = try SeedAccount.load(from: folder.appending(path: "test-account-two-step.json"))
    if CommandLine.arguments.dropFirst().first == "authenticator-code" {
        print(try await DevelopmentSeed.authenticatorCode(twoStep))
        exit(0)
    }

    let account = try SeedAccount.load(from: folder.appending(path: "test-account.json"))
    switch try await DevelopmentSeed.run(account) {
    case .created(let items):
        print("Created the test account \(account.email) on \(account.server.absoluteString) with \(items) items.")
    case .alreadySeeded(let items):
        print("The test account \(account.email) is already there with \(items) items.")
    }
    switch try await DevelopmentSeed.runTwoStep(twoStep) {
    case .created:
        print("Created the test account \(twoStep.email) with two-step login by authenticator app and by email.")
    case .alreadySeeded:
        print("The test account \(twoStep.email) is already there with two-step login.")
    }
    let organization = try SeedAccount.load(from: folder.appending(path: "test-account-organization.json"))
    switch try await DevelopmentSeed.runOrganization(organization) {
    case .created(let items):
        print("Created the test account \(organization.email) with an organization, two collections and \(items) items.")
    case .alreadySeeded(let items):
        print("The test account \(organization.email) is already there with its organization and \(items) items.")
    }
} catch {
    print("The seed failed: \(error)")
    exit(1)
}
