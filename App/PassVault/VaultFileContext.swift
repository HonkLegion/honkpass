import Engine
import Foundation

/// UI lifetime checks complement the engine's unlocked-session token.
@MainActor struct VaultFileContext {
    let model: AppModel
    let navigation: VaultNavigation
    private let revision: UUID

    init(model: AppModel, navigation: VaultNavigation) {
        self.model = model
        self.navigation = navigation
        revision = navigation.fileWorkRevision
    }

    func session() async throws -> VaultSessionToken {
        try checkCurrent()
        let session = try await model.vaultSession()
        try checkCurrent()
        return session
    }

    func check(_ session: VaultSessionToken) async throws {
        try await model.checkVaultSession(session)
        try checkCurrent()
    }

    func prepare<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try checkCurrent()
        let result = try await navigation.prepareFile(work)
        try checkCurrent()
        return result
    }

    func checkCurrent() throws {
        try Task.checkCancellation()
        guard navigation.fileWorkRevision == revision else { throw CancellationError() }
    }
}
