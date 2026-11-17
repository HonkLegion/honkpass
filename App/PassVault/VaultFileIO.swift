import Foundation
import VaultModel

/// Blocking filesystem access and import decoding run on the concurrent executor.
enum VaultFileIO {
    enum Failure: Error { case empty, tooLarge }

    struct PreparedImport: Sendable {
        let file: VaultImport
        let summary: VaultImport.Summary
    }

    @concurrent static func importFile(_ url: URL?, pasted: String, format: VaultImportFormat,
                                      folder: VaultFolder?) async throws -> PreparedImport {
        let contents: Data
        if let url { contents = try await read(url) } else { contents = Data(pasted.utf8) }
        try Task.checkCancellation()
        guard !contents.isEmpty else { throw Failure.empty }
        var imported = try format.read(contents)
        try Task.checkCancellation()
        if let folder { imported = imported.placed(in: folder) }
        let summary = imported.summary
        try Task.checkCancellation()
        return PreparedImport(file: imported, summary: summary)
    }

    @concurrent static func read(_ url: URL, maximumBytes: Int? = nil) async throws -> Data {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let limit = maximumBytes ?? Int.max
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(size)
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else { break }
            guard chunk.count <= limit - data.count else { throw Failure.tooLarge }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return data
    }

    /// Stage beside the destination, with owner-only permissions before the first byte.
    /// Cancellation removes the staging file and leaves the destination unchanged.
    @concurrent static func write(_ data: Data, to destination: URL) async throws {
        try Task.checkCancellation()
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appending(path: ".honkpass-\(UUID()).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + 1_024 * 1_024, data.count)
                try handle.write(contentsOf: data[(data.startIndex + offset)..<(data.startIndex + end)])
                offset = end
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }
}
