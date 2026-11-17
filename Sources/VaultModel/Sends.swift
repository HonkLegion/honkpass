import Foundation

/// What a Send carries to the one who opens its link.
public enum SendType: String, Sendable, Codable, CaseIterable {
    case text, file
}

/// What the list of Sends shows about one Send. It holds no text, no file and no key.
public struct VaultSendSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let type: SendType
    public var name: String
    /// The day the server deletes the Send.
    public var deletionDate: Date
    /// From this day on the link opens nothing more.
    public var expirationDate: Date?
    public var maxAccessCount: Int?
    public var accessCount: Int
    public var hasPassword: Bool
    /// The server has turned the Send off: its link opens nothing.
    public var isDisabled: Bool

    public init(id: String, type: SendType, name: String, deletionDate: Date, expirationDate: Date? = nil,
                maxAccessCount: Int? = nil, accessCount: Int = 0, hasPassword: Bool = false, isDisabled: Bool = false) {
        self.id = id
        self.type = type
        self.name = name
        self.deletionDate = deletionDate
        self.expirationDate = expirationDate
        self.maxAccessCount = maxAccessCount
        self.accessCount = accessCount
        self.hasPassword = hasPassword
        self.isDisabled = isDisabled
    }

    // The marks of a row, as send-table.component.html of the reference has them.

    public func isExpired(at time: Date) -> Bool {
        expirationDate.map { $0 <= time } ?? false
    }

    public func isPendingDeletion(at time: Date) -> Bool {
        deletionDate <= time
    }

    public var isMaxAccessCountReached: Bool {
        maxAccessCount.map { accessCount >= $0 } ?? false
    }
}

/// One Send with what it carries, decrypted.
public struct VaultSend: Sendable, Codable, Equatable, Identifiable {
    public var summary: VaultSendSummary
    public var id: String { summary.id }
    public var notes: String?
    /// The text of a text Send.
    public var text: String?
    /// The one who opens the link sees the text only after a click.
    public var hidesText: Bool
    /// The name and the size of the file of a file Send, as the server says it.
    public var fileName: String?
    public var fileSizeName: String?
    /// The address of the user is not shown to the one who opens the link.
    public var hidesEmail: Bool
    /// What follows the address of the server in the link of the Send: the identifier the server
    /// gave it and its key. The key is in no request to the server.
    public var linkPath: String?

    public init(summary: VaultSendSummary, notes: String? = nil, text: String? = nil, hidesText: Bool = false,
                fileName: String? = nil, fileSizeName: String? = nil, hidesEmail: Bool = false, linkPath: String? = nil) {
        self.summary = summary
        self.notes = notes
        self.text = text
        self.hidesText = hidesText
        self.fileName = fileName
        self.fileSizeName = fileSizeName
        self.hidesEmail = hidesEmail
        self.linkPath = linkPath
    }

    /// The link that opens the Send in the web vault of its server (`getSendUrl` of the
    /// reference for a server of one's own: the web vault with "/#/send/").
    public func link(server: URL) -> String? {
        guard let linkPath else { return nil }
        var address = server.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        return address + "/#/send/" + linkPath
    }
}

/// What the form of a Send holds.
public struct SendDraft: Sendable, Codable, Equatable {
    /// A file a new file Send is made of.
    public struct File: Sendable, Codable, Equatable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// nil for a new Send.
    public var id: String?
    public var type: SendType
    public var name: String
    public var notes: String
    public var text: String
    public var hidesText: Bool
    /// Only a new file Send has a file; the file of a Send cannot be changed.
    public var file: File?
    /// The day the Send is deleted. The form sets the day its link ends to the same day, as the
    /// one of the reference does.
    public var deletionDate: Date
    public var maxAccessCount: Int?
    public var hidesEmail: Bool
    /// A password the Send gets. nil leaves a Send as it is: with the password it has, or without one.
    public var newPassword: String?

    public init(id: String? = nil, type: SendType, name: String = "", notes: String = "", text: String = "",
                hidesText: Bool = false, file: File? = nil, deletionDate: Date, maxAccessCount: Int? = nil,
                hidesEmail: Bool = false, newPassword: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.notes = notes
        self.text = text
        self.hidesText = hidesText
        self.file = file
        self.deletionDate = deletionDate
        self.maxAccessCount = maxAccessCount
        self.hidesEmail = hidesEmail
        self.newPassword = newPassword
    }

    /// The form of a Send the vault has.
    public init(_ send: VaultSend) {
        self.init(id: send.id, type: send.summary.type, name: send.summary.name, notes: send.notes ?? "",
                  text: send.text ?? "", hidesText: send.hidesText, deletionDate: send.summary.deletionDate,
                  maxAccessCount: send.summary.maxAccessCount, hidesEmail: send.hidesEmail)
    }

    /// What a save needs: a name, and a text or, for a new file Send, a file.
    public var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch type {
        case .text: return !text.isEmpty
        case .file: return id != nil || file != nil
        }
    }
}

/// The order of the list of Sends: by the column whose title the user clicked.
public struct SendSort: Sendable, Equatable {
    public enum Column: Sendable {
        case name, deletionDate
    }

    public var column: Column
    public var isAscending: Bool

    public init(column: Column = .name, isAscending: Bool = true) {
        self.column = column
        self.isAscending = isAscending
    }
}

/// The filter and the order of the list of Sends.
public extension Array where Element == VaultSendSummary {
    /// The Sends of a type (nil: all) whose name holds the search text, by name unless the
    /// user chose another order.
    func shown(type: SendType?, search: String, sort: SendSort = SendSort()) -> [VaultSendSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let matching = filter { send in
            (type == nil || send.type == type) && (needle.isEmpty || send.name.localizedCaseInsensitiveContains(needle))
        }
        return matching.sorted { first, second in
            let order: ComparisonResult = switch sort.column {
            case .name: first.name.localizedCaseInsensitiveCompare(second.name)
            case .deletionDate: first.deletionDate == second.deletionDate ? .orderedSame
                : (first.deletionDate < second.deletionDate ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return first.id < second.id }
            return (order == .orderedAscending) == sort.isAscending
        }
    }
}
