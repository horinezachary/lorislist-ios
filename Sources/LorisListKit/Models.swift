import Foundation

// Models for the Lori's List API (docs/openapi.yaml in horinezachary/shoppingList).
// Where the real server differs from the written spec, the decoders follow the server;
// see the notes on each type and Tests/LorisListKitTests/Fixtures for captured responses.

/// What the signed-in person may do with a list.
public enum ListRole: String, Decodable, Sendable {
    case owner, edit, view

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // An unknown role is treated as read-only, the safe choice.
        self = ListRole(rawValue: raw.lowercased()) ?? .view
    }
}

/// The permission an owner can offer when inviting someone.
public enum SharePermission: String, Codable, Sendable, CaseIterable, Identifiable {
    case edit, view

    public var id: String { rawValue }
    public var label: String { self == .edit ? "Edit" : "View" }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SharePermission(rawValue: raw.lowercased()) ?? .view
    }
}

public struct User: Codable, Equatable, Sendable {
    public var username: String
    public var firstName: String
    public var lastName: String
    public var email: String
    /// Only sent by GET/PATCH /me, not by sign-in.
    public var showTips: Bool?

    public init(username: String, firstName: String, lastName: String, email: String, showTips: Bool? = nil) {
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.showTips = showTips
    }

    public var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Tips are on unless the server says otherwise.
    public var tipsEnabled: Bool { showTips ?? true }
}

public struct ListSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var name: String
    /// Six hex digits without "#". The server may return either case.
    public var color: String
    public var owner: String
    public var role: ListRole
    public var lastChange: Date?

    public init(id: Int, name: String, color: String, owner: String, role: ListRole, lastChange: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.owner = owner
        self.role = role
        self.lastChange = lastChange
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, owner, role, lastChange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        owner = try c.decode(String.self, forKey: .owner)
        role = try c.decode(ListRole.self, forKey: .role)
        lastChange = LenientDate.decode(from: c, forKey: .lastChange)
    }
}

public struct ListItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var name: String
    public var count: Int?
    public var checked: Bool

    public init(id: Int, name: String, count: Int? = nil, checked: Bool = false) {
        self.id = id
        self.name = name
        self.count = count
        self.checked = checked
    }
}

/// A list together with its items (GET /lists/{id}). The list fields sit at the same
/// level as `canEdit` and `items` in the JSON, so the summary decodes from the same object.
public struct ListDetail: Decodable, Equatable, Identifiable, Sendable {
    public var summary: ListSummary
    public var canEdit: Bool
    public var items: [ListItem]
    /// The server's fingerprint of this list as fetched (what `GET /changes` reports for it).
    /// Nil from an older server.
    public var revision: String?

    public var id: Int { summary.id }

    public init(summary: ListSummary, canEdit: Bool, items: [ListItem], revision: String? = nil) {
        self.summary = summary
        self.canEdit = canEdit
        self.items = items
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case canEdit, items, revision
    }

    public init(from decoder: Decoder) throws {
        summary = try ListSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canEdit = try c.decode(Bool.self, forKey: .canEdit)
        items = try c.decode([ListItem].self, forKey: .items)
        revision = try? c.decodeIfPresent(String.self, forKey: .revision)
    }

    public var checkedCount: Int { items.filter { $0.checked }.count }
}

public struct ListColorOption: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var hex: String
    public var name: String

    public init(id: Int, hex: String, name: String) {
        self.id = id
        self.hex = hex
        self.name = name
    }
}

/// One signed-in device (GET /auth/sessions).
public struct DeviceSession: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public var deviceName: String
    public var createdAt: Date?
    public var lastUsedAt: Date?
    public var current: Bool

    public init(id: Int, deviceName: String, createdAt: Date? = nil, lastUsedAt: Date? = nil, current: Bool) {
        self.id = id
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.current = current
    }

    private enum CodingKeys: String, CodingKey {
        case id, deviceName, createdAt, lastUsedAt, current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? ""
        createdAt = LenientDate.decode(from: c, forKey: .createdAt)
        lastUsedAt = LenientDate.decode(from: c, forKey: .lastUsedAt)
        current = (try? c.decode(Bool.self, forKey: .current)) ?? false
    }
}

/// A pending invitation (GET /shares/{key}).
public struct ShareInvitation: Decodable, Equatable, Sendable {
    public struct SharedList: Decodable, Equatable, Sendable {
        public let id: Int
        public var name: String
        public var color: String
        public var owner: String
    }

    public let key: String
    public var permission: SharePermission
    public var list: SharedList
}

/// A fingerprint of everything the person can see (GET /changes, and each message of the live
/// stream). A list whose fingerprint differs from the one stored with the cached copy has changed.
public struct Digest: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let id: Int
        public let revision: String

        public init(id: Int, revision: String) {
            self.id = id
            self.revision = revision
        }
    }

    public let revision: String
    public let lists: [Entry]

    public init(revision: String, lists: [Entry]) {
        self.revision = revision
        self.lists = lists
    }
}

// MARK: - Dates

/// The spec says dates are ISO 8601 strings, but the value is passed straight through from
/// the database layer, so a number (milliseconds since 1970) is accepted too, and a missing
/// or unreadable value becomes nil instead of failing the whole response.
enum LenientDate {
    static func decode<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return parse(text)
        }
        if let millis = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }

    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
