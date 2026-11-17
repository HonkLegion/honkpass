import AppKit

/// Closing the originating form also dismisses its save panel and releases the pending data.
@MainActor enum VaultFileSavePanel {
    static func destination(named name: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}
