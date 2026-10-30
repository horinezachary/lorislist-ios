import Foundation

/// One edit made while the phone may have been offline, waiting to be sent.
///
/// Only changes to items are queued; they are small, they commute well (ticking, adding,
/// removing), and they are what people do in a shop with no signal. Creating, renaming,
/// deleting and sharing lists need the server and say so.
///
/// Each change carries a `key`. It is sent as the `Idempotency-Key` header every time the
/// change is tried, so a try that reached the server but lost its answer is not applied twice.
public enum PendingChange: Codable, Equatable, Sendable {
    /// `tempID` is a negative number standing in for the item until the server gives it a real one.
    case addItem(listID: Int, tempID: Int, name: String, count: Int?, key: String)
    case setChecked(listID: Int, itemID: Int, checked: Bool, key: String)
    case removeItem(listID: Int, itemID: Int, key: String)
    case clearChecked(listID: Int, key: String)

    public var listID: Int {
        switch self {
        case .addItem(let listID, _, _, _, _), .setChecked(let listID, _, _, _),
             .removeItem(let listID, _, _), .clearChecked(let listID, _):
            return listID
        }
    }

    public var key: String {
        switch self {
        case .addItem(_, _, _, _, let key), .setChecked(_, _, _, let key),
             .removeItem(_, _, let key), .clearChecked(_, let key):
            return key
        }
    }

    /// True when this change is about the item (the add that created it counts).
    func touches(itemID id: Int) -> Bool {
        switch self {
        case .addItem(_, let tempID, _, _, _): return tempID == id
        case .setChecked(_, let itemID, _, _), .removeItem(_, let itemID, _): return itemID == id
        case .clearChecked: return false
        }
    }
}

/// The rules for a queue of pending changes. Pure functions, so they can be tested without a network.
public enum Outbox {
    /// What the list looks like with the pending changes applied on top of the server's copy.
    /// This is what the person sees; the server's copy itself is never edited until a change is sent.
    public static func apply(_ queue: [PendingChange], to items: [ListItem], listID: Int) -> [ListItem] {
        var result = items
        for change in queue where change.listID == listID {
            switch change {
            case .addItem(_, let tempID, let name, let count, _):
                if !result.contains(where: { $0.id == tempID }) {
                    result.append(ListItem(id: tempID, name: name, count: count, checked: false))
                }
            case .setChecked(_, let itemID, let checked, _):
                if let index = result.firstIndex(where: { $0.id == itemID }) {
                    result[index].checked = checked
                }
            case .removeItem(_, let itemID, _):
                result.removeAll { $0.id == itemID }
            case .clearChecked:
                result.removeAll { $0.checked }
            }
        }
        return result
    }

    /// Adds a change to the end of the queue, dropping work that no longer matters:
    /// * removing an item that was only ever added here cancels the add and everything after it;
    /// * ticking the same item again replaces the earlier tick (only the last state is sent);
    /// * removing an item makes earlier ticks of it pointless.
    public static func enqueue(_ change: PendingChange, into queue: [PendingChange]) -> [PendingChange] {
        var result = queue
        switch change {
        case .removeItem(let listID, let itemID, _):
            if itemID < 0 {
                let wasQueued = result.contains { $0.listID == listID && $0.touches(itemID: itemID) }
                result.removeAll { $0.listID == listID && $0.touches(itemID: itemID) }
                if wasQueued { return result }
            } else {
                result.removeAll { change in
                    if case .setChecked(let l, let i, _, _) = change { return l == listID && i == itemID }
                    return false
                }
            }
        case .setChecked(let listID, let itemID, _, _):
            result.removeAll { change in
                if case .setChecked(let l, let i, _, _) = change { return l == listID && i == itemID }
                return false
            }
        default:
            break
        }
        result.append(change)
        return result
    }

    /// Once the server has given an item its real id, later changes that named the stand-in use it.
    public static func retarget(_ queue: [PendingChange], tempID: Int, realID: Int) -> [PendingChange] {
        queue.map { change in
            switch change {
            case .setChecked(let l, let i, let checked, let key) where i == tempID:
                return .setChecked(listID: l, itemID: realID, checked: checked, key: key)
            case .removeItem(let l, let i, let key) where i == tempID:
                return .removeItem(listID: l, itemID: realID, key: key)
            default:
                return change
            }
        }
    }

    /// The id the server gave a just-added item: the one in `after` that was not in `before`.
    /// If several appeared (someone else added at the same moment), the last one that matches
    /// the name and quantity; failing that, the last new one.
    public static func newItemID(before: [ListItem], after: [ListItem], name: String, count: Int?) -> Int? {
        let known = Set(before.map { $0.id })
        let fresh = after.filter { !known.contains($0.id) }
        if fresh.count <= 1 { return fresh.first?.id }
        return fresh.last(where: { $0.name == name && $0.count == count })?.id ?? fresh.last?.id
    }
}
