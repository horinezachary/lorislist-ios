import Foundation

/// A list as kept on the phone: what the server last said, plus its fingerprint.
/// Items are nil until the list has been fetched once.
struct StoredList: Codable, Equatable {
    var id: Int
    var name: String
    var color: String
    var owner: String
    var role: String
    var lastChange: Date?
    var canEdit: Bool
    var revision: String?
    var items: [ListItem]?

    init(detail: ListDetail) {
        id = detail.summary.id
        name = detail.summary.name
        color = detail.summary.color
        owner = detail.summary.owner
        role = detail.summary.role.rawValue
        lastChange = detail.summary.lastChange
        canEdit = detail.canEdit
        revision = detail.revision
        items = detail.items
    }

    init(summary: ListSummary) {
        id = summary.id
        name = summary.name
        color = summary.color
        owner = summary.owner
        role = summary.role.rawValue
        lastChange = summary.lastChange
        canEdit = summary.role != .view
        revision = nil
        items = nil
    }

    var summary: ListSummary {
        ListSummary(
            id: id, name: name, color: color, owner: owner,
            role: ListRole(rawValue: role) ?? .view, lastChange: lastChange)
    }
}

/// Everything the app keeps on the phone so it works without a connection.
/// It belongs to one account (`owner`); signing in as someone else starts it over.
public struct CacheSnapshot: Codable, Equatable, Sendable {
    var version: Int
    var owner: String
    var user: User?
    var lists: [StoredList]
    var colors: [ListColorOption]
    var suggestions: [String]
    var outbox: [PendingChange]
    var nextTempID: Int
    var lastSynced: Date?

    static func empty(owner: String = "") -> CacheSnapshot {
        CacheSnapshot(
            version: 1, owner: owner, user: nil, lists: [], colors: [], suggestions: [],
            outbox: [], nextTempID: -1, lastSynced: nil)
    }
}

/// Where the snapshot is kept between launches.
public protocol SnapshotStore: Sendable {
    func load() -> CacheSnapshot?
    func save(_ snapshot: CacheSnapshot)
    func clear()
}

/// A JSON file. On the phone it sits in the app's private Application Support folder, is
/// excluded from backups, and is readable only after the first unlock.
public final class FileSnapshotStore: SnapshotStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/LorisList/cache.json`
    public static func standard() -> FileSnapshotStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileSnapshotStore(url: base.appendingPathComponent("LorisList", isDirectory: true)
            .appendingPathComponent("cache.json"))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func load() -> CacheSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file from a future version, or a damaged one, is treated as no cache at all.
        guard let snapshot = try? Self.decoder().decode(CacheSnapshot.self, from: data),
              snapshot.version == 1 else { return nil }
        return snapshot
    }

    public func save(_ snapshot: CacheSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Self.encoder().encode(snapshot) else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try? data.write(to: url, options: options)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(excluded)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// For tests and previews.
public final class InMemorySnapshotStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CacheSnapshot?

    public init(_ snapshot: CacheSnapshot? = nil) {
        stored = snapshot
    }

    public func load() -> CacheSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func save(_ snapshot: CacheSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        stored = snapshot
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
