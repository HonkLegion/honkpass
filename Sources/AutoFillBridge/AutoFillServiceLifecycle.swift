import Foundation

/// Keeps a registered helper tied to the installed executable after an app update.
/// Operations are serialized because unregistering must finish before registering again.
@MainActor
public final class AutoFillServiceLifecycle {
    public enum State: Sendable {
        case enabled, requiresApproval, notRegistered, notFound
    }

    public struct Actions {
        public var state: () -> State
        public var savedIdentity: () -> Data?
        public var saveIdentity: (Data?) -> Void
        public var register: () throws -> Void
        public var unregister: () async throws -> Void
        public var startHost: () async -> Void
        public var stopHost: () -> Void

        public init(state: @escaping () -> State, savedIdentity: @escaping () -> Data?,
                    saveIdentity: @escaping (Data?) -> Void, register: @escaping () throws -> Void,
                    unregister: @escaping () async throws -> Void, startHost: @escaping () async -> Void,
                    stopHost: @escaping () -> Void) {
            self.state = state
            self.savedIdentity = savedIdentity
            self.saveIdentity = saveIdentity
            self.register = register
            self.unregister = unregister
            self.startHost = startHost
            self.stopHost = stopHost
        }
    }

    private enum Operation: Equatable { case start, enable, disable }
    private let identity: Data
    private let actions: Actions
    private var pending: (id: UUID, operation: Operation, task: Task<Void, Error>)?

    public init(identity: Data, actions: Actions) {
        self.identity = identity
        self.actions = actions
    }

    public func start() async throws { try await enqueue(.start) }
    public func setEnabled(_ enabled: Bool) async throws { try await enqueue(enabled ? .enable : .disable) }

    private func enqueue(_ operation: Operation) async throws {
        if operation == .start, let pending, pending.operation == .start {
            return try await pending.task.value
        }
        let previous = pending?.task
        let id = UUID()
        let task = Task {
            // A failed operation does not prevent a later explicit disable or retry.
            _ = try? await previous?.value
            try await perform(operation)
        }
        pending = (id, operation, task)
        defer { if pending?.id == id { pending = nil } }
        try await task.value
    }

    private func perform(_ operation: Operation) async throws {
        if operation == .disable {
            actions.stopHost()
            if actions.state() != .notRegistered && actions.state() != .notFound {
                try await actions.unregister()
            }
            actions.saveIdentity(nil)
            return
        }

        let state = actions.state()
        if state == .enabled && actions.savedIdentity() != identity {
            actions.stopHost()
            actions.saveIdentity(nil)
            try await actions.unregister()
            try actions.register()
        } else if operation == .enable && (state == .notRegistered || state == .notFound) {
            try actions.register()
        }
        // A service disabled by the user in System Settings is never re-enabled here.
        if actions.state() == .enabled { actions.saveIdentity(identity) }
        await actions.startHost()
    }
}
