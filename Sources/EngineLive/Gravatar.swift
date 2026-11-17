import CryptoKit
import Engine
import Foundation

/// Public avatar lookup requested by the user. No account token, cookies or credentials are sent.
public actor Gravatar: AccountAvatarPort {
    private struct Entry: Codable {
        var expiresAt: Date
        var data: Data?
    }

    private let directory: URL?
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URLRequest) async -> (Data, Int)?
    private var memory: [String: Entry] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]

    public init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "cz.honklegion.honkpass/Gravatar", directoryHint: .isDirectory)
        now = { Date() }
        let http = HTTPClient()
        fetch = { request in try? await http.send(request) }
    }

    /// Tests supply their own directory, clock and synthetic transport.
    init(directory: URL?, now: @escaping @Sendable () -> Date,
         fetch: @escaping @Sendable (URLRequest) async -> (Data, Int)?) {
        self.directory = directory
        self.now = now
        self.fetch = fetch
    }

    static func url(email: String) -> URL {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=96&d=404&r=g")!
    }

    public func image(email: String) async -> Data? {
        let url = Self.url(email: email)
        let key = url.lastPathComponent
        let cached = memory[key] ?? read(key)
        if let cached, cached.expiresAt > now() {
            memory[key] = cached
            return cached.data
        }
        if let task = pending[key] { return await task.value }
        let task = Task { await refresh(url: url, key: key, cached: cached) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        return result
    }

    private func refresh(url: URL, key: String, cached: Entry?) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("image/png, image/jpeg", forHTTPHeaderField: "Accept")
        let response = await fetch(request)
        let entry: Entry
        if let (data, status) = response, status == 200, Self.isAvatar(data) {
            entry = Entry(expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), data: data)
        } else if response?.1 == 404 {
            entry = Entry(expiresAt: now().addingTimeInterval(12 * 60 * 60), data: nil)
        } else {
            // Offline, invalid image or server failure: retain the previous picture and back off.
            entry = Entry(expiresAt: now().addingTimeInterval(15 * 60), data: cached?.data)
        }
        memory[key] = entry
        write(entry, key: key)
        return entry.data
    }

    private func read(_ key: String) -> Entry? {
        guard let file = directory?.appending(path: key + ".json"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 400_000,
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.data.map(Self.isAvatar) ?? true else { return nil }
        return entry
    }

    private func write(_ entry: Entry, key: String) {
        guard let directory, let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: key + ".json"), options: .atomic)
        } catch {
            // A full or unwritable disk must not affect the account or its avatar in memory.
        }
    }

    static func isAvatar(_ data: Data) -> Bool {
        guard data.count <= 262_144 else { return false }
        return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            || data.starts(with: [0xff, 0xd8, 0xff])
    }
}
