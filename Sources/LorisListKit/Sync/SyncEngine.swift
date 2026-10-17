import Foundation

/// What the app shows about syncing: is the phone talking to the server, and is anything waiting.
public struct SyncState: Equatable, Sendable {
    /// False after a request failed for lack of a connection; true again after one succeeds.
    public var isOnline = true
    public var isSyncing = false
    /// Changes made on this phone that the server has not accepted yet.
    public var pendingCount = 0
    public var lastSynced: Date?
    /// Changes the server refused when they were sent (the list was deleted, or the person
    /// lost access, since they were made). They were dropped; this lets the app say so once.
    public var droppedCount = 0

    public init() {}
}

public enum SyncEvent: Sendable {
    case state(SyncState)
    /// The set of lists, or their names, colours or roles, changed.
    case lists
    /// This list's items (or details) changed.
    case list(Int)
}

/// Keeps a copy of the person's lists on the phone, sends changes made offline when the
/// connection returns, and fetches what others changed.
///
/// How it works, in short:
/// * The cached copy is the server's last answer. It is only ever replaced by a newer server
///   answer, never edited locally.
/// * Edits go into an outbox. What the screen shows is the cached copy with the outbox applied
///   on top, so an edit appears at once and survives a restart.
/// * `sync()` first sends the outbox in order, then asks the server for the fingerprint of every
///   list (`GET /changes`) and fetches only the lists that differ from the cached ones.
/// * If the server rejects a queued change for good (404, 403, 400) the change is dropped: the
///   list was deleted or the person lost access, and sending it again would fail again. Anything
///   else (no connection, a server error, an expired session) keeps it queued for the next try.
public actor SyncEngine {
    private let api: APIClient
    private let store: SnapshotStore
    private let clock: @Sendable () -> Date

    private var snap: CacheSnapshot
    private var state = SyncState()
    private var handler: (@Sendable (SyncEvent) -> Void)?

    private var syncTask: Task<Void, Never>?
    private var runAgain = false
    private var hint: Digest?
    private var colorsFetched = false
    /// Bumped whenever the cache is wiped, so a sync that was in flight cannot write the old
    /// account's answers back into the new, empty cache.
    private var epoch = 0

    public init(api: APIClient, store: SnapshotStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.store = store
        self.clock = clock
        let loaded = store.load() ?? CacheSnapshot.empty()
        self.snap = loaded
        self.state.pendingCount = loaded.outbox.count
        self.state.lastSynced = loaded.lastSynced
    }

    /// Where updates are reported. Called from the engine's own context; hop to the main actor yourself.
    public func setHandler(_ handler: (@Sendable (SyncEvent) -> Void)?) {
        self.handler = handler
    }

    // MARK: Whose data is this

    /// Call once the signed-in account is known. A different account than the cache belongs to
    /// starts the cache over, so nobody sees (or sends) someone else's lists.
    public func attach(username: String) {
        if snap.owner.caseInsensitiveCompare(username) == .orderedSame { return }
        epoch += 1
        snap = CacheSnapshot.empty(owner: username)
        colorsFetched = false
        persist()
        state.pendingCount = 0
        state.lastSynced = nil
        state.droppedCount = 0
        emit(.lists)
        emit(.state(state))
    }

    /// Signing out: forget everything, including changes that were never sent.
    public func reset() {
        epoch += 1
        snap = CacheSnapshot.empty()
        colorsFetched = false
        store.clear()
        state = SyncState()
        emit(.lists)
        emit(.state(state))
    }

    public func remember(user: User) {
        snap.user = user
        persist()
    }

    // MARK: Reading the cache

    public func cachedUser() -> User? { snap.user }

    public func currentState() -> SyncState { state }

    public func colors() -> [ListColorOption] { snap.colors }

    public func suggestions() -> [String] { snap.suggestions }

    public func lists() -> [ListSummary] { snap.lists.map { $0.summary } }

    /// True once lists have been fetched at least once, or there is something cached to show.
    public func hasData() -> Bool { snap.lastSynced != nil || !snap.lists.isEmpty }

    /// The list with the pending changes applied. Nil if it is not cached (or has no items yet).
    public func list(id: Int) -> ListDetail? {
        guard let stored = snap.lists.first(where: { $0.id == id }), let items = stored.items else { return nil }
        return ListDetail(
            summary: stored.summary, canEdit: stored.canEdit,
            items: Outbox.apply(snap.outbox, to: items, listID: id), revision: stored.revision)
    }

    // MARK: Making changes

    /// Adds an item. It shows at once; it is sent as soon as there is a connection.
    @discardableResult
    public func addItem(listID: Int, name: String, count: Int?) -> ListDetail? {
        guard let stored = snap.lists.first(where: { $0.id == listID }), stored.canEdit else { return nil }
        let tempID = snap.nextTempID
        snap.nextTempID -= 1
        queue(.addItem(listID: listID, tempID: tempID, name: name, count: count, key: Self.newKey()))
        return list(id: listID)
    }

    @discardableResult
    public func setChecked(listID: Int, itemID: Int, checked: Bool) -> ListDetail? {
        guard let stored = snap.lists.first(where: { $0.id == listID }), stored.canEdit else { return nil }
        queue(.setChecked(listID: listID, itemID: itemID, checked: checked, key: Self.newKey()))
        return list(id: listID)
    }

    @discardableResult
    public func removeItem(listID: Int, itemID: Int) -> ListDetail? {
        guard let stored = snap.lists.first(where: { $0.id == listID }), stored.canEdit else { return nil }
        queue(.removeItem(listID: listID, itemID: itemID, key: Self.newKey()))
        return list(id: listID)
    }

    @discardableResult
    public func clearChecked(listID: Int) -> ListDetail? {
        guard let stored = snap.lists.first(where: { $0.id == listID }), stored.canEdit else { return nil }
        queue(.clearChecked(listID: listID, key: Self.newKey()))
        return list(id: listID)
    }

    /// The person has seen the "some changes could not be saved" message.
    public func acknowledgeDropped() {
        state.droppedCount = 0
        emit(.state(state))
    }

    private func queue(_ change: PendingChange) {
        snap.outbox = Outbox.enqueue(change, into: snap.outbox)
        persist()
        state.pendingCount = snap.outbox.count
        emit(.list(change.listID))
        emit(.state(state))
        Task { await self.sync() }
    }

    private static func newKey() -> String { UUID().uuidString }

    // MARK: Syncing

    /// Sends waiting changes, then fetches what changed on the server. Safe to call at any time
    /// and from anywhere: a call while one is running makes it go around once more and waits for that.
    /// `digest` is a fingerprint the live stream already delivered, which saves asking again.
    public func sync(digest: Digest? = nil) async {
        if let digest = digest { hint = digest }
        if let running = syncTask {
            runAgain = true
            await running.value
            return
        }
        let task = Task { await self.syncLoop() }
        syncTask = task
        await task.value
    }

    private func syncLoop() async {
        repeat {
            runAgain = false
            await syncOnce()
        } while runAgain
        syncTask = nil
        setSyncing(false)
    }

    private func syncOnce() async {
        guard await api.isSignedIn else { return }
        setSyncing(true)
        let streamed = hint
        hint = nil

        var sentSomething = false
        if !snap.outbox.isEmpty {
            switch await flush() {
            case .blocked:
                // Still no connection (or the server is struggling): fetching would fail the same way.
                return
            case .done(let applied):
                sentSomething = applied
            }
        }

        do {
            let digest: Digest
            if let streamed = streamed, !sentSomething {
                digest = streamed
            } else {
                digest = try await fetchDigest()
            }
            try await apply(digest)
            snap.lastSynced = clock()
            persist()
            state.lastSynced = snap.lastSynced
            markOnline()
            if !colorsFetched { await fetchColors() }
        } catch is CancellationError {
            // The app is going away; the next sync picks up.
        } catch let error as APIError {
            noteFailure(error)
        } catch {
            // Not an API problem; try again next time.
        }
    }

    private func fetchDigest() async throws -> Digest {
        do {
            return try await api.changes()
        } catch let error as APIError where error.code == .notFound {
            // A server from before live updates: no fingerprints, so every list is fetched again.
            let lists = try await api.lists()
            return Digest(revision: "", lists: lists.map { Digest.Entry(id: $0.id, revision: "") })
        }
    }

    private func checkEpoch(_ start: Int) throws {
        if epoch != start { throw CancellationError() }
    }

    /// Brings the cache in line with the server's fingerprint.
    private func apply(_ digest: Digest) async throws {
        let startEpoch = epoch
        let existing = Dictionary(snap.lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fetched: [Int: StoredList] = [:]
        var changed: [Int] = []

        for entry in digest.lists {
            if let have = existing[entry.id], have.items != nil, !entry.revision.isEmpty, have.revision == entry.revision {
                continue
            }
            do {
                let detail = try await api.list(id: entry.id)
                fetched[entry.id] = StoredList(detail: detail)
                changed.append(entry.id)
            } catch let error as APIError where error.code == .notFound {
                // Deleted, or no longer shared, since the fingerprint was made. The next one will omit it.
                continue
            }
        }

        try checkEpoch(startEpoch)
        let wanted = Set(digest.lists.map { $0.id })
        var next: [StoredList] = []
        // Keep the order people are used to; new lists go at the end in server order.
        for stored in snap.lists where wanted.contains(stored.id) {
            next.append(fetched[stored.id] ?? stored)
        }
        for entry in digest.lists where existing[entry.id] == nil {
            if let new = fetched[entry.id] { next.append(new) }
        }

        let listsChanged = next.map { $0.summary } != snap.lists.map { $0.summary }
        let itemsChanged = changed.filter { id in
            existing[id]?.items != fetched[id]?.items
        }
        if next != snap.lists {
            snap.lists = next
            persist()
        }
        if listsChanged { emit(.lists) }
        for id in itemsChanged { emit(.list(id)) }
        if !changed.isEmpty && !listsChanged && itemsChanged.isEmpty { emit(.lists) }
    }

    private func fetchColors() async {
        if let colors = try? await api.colors(), !colors.isEmpty {
            colorsFetched = true
            if colors != snap.colors {
                snap.colors = colors
                persist()
            }
        }
    }

    /// Item names for the quick-pick chips. Cached; refreshed when asked.
    @discardableResult
    public func refreshSuggestions() async -> [String] {
        if let names = try? await api.suggestions() {
            if names != snap.suggestions {
                snap.suggestions = names
                persist()
            }
        }
        return snap.suggestions
    }

    // MARK: Sending the outbox

    private enum FlushResult {
        case done(applied: Bool)
        case blocked
    }

    private func flush() async -> FlushResult {
        var applied = false
        while let change = snap.outbox.first {
            do {
                try await send(change)
                applied = true
            } catch is CancellationError {
                return .blocked
            } catch let error as APIError {
                if Self.worthRetrying(error) {
                    noteFailure(error)
                    return .blocked
                }
                drop(change)
            } catch {
                return .blocked
            }
        }
        markOnline()
        return .done(applied: applied)
    }

    /// No connection, a struggling server, a busy server or an expired session: try again later.
    /// Anything else the server said no to will get the same answer next time.
    static func worthRetrying(_ error: APIError) -> Bool {
        if error.code == .network || error.code == .sessionExpired { return true }
        return error.status == 0 || error.status == 401 || error.status == 429 || error.status >= 500
    }

    private func send(_ change: PendingChange) async throws {
        let startEpoch = epoch
        switch change {
        case .addItem(let listID, let tempID, let name, let count, let key):
            let items = try await api.addItem(listID: listID, name: name, count: count, idempotencyKey: key)
            try checkEpoch(startEpoch)
            let before = snap.lists.first(where: { $0.id == listID })?.items ?? []
            let realID = Outbox.newItemID(before: before, after: items, name: name, count: count)
            setItems(items, in: listID)
            let stillQueued = snap.outbox.contains { $0.key == key }
            if let realID = realID {
                snap.outbox = Outbox.retarget(snap.outbox, tempID: tempID, realID: realID)
                if !stillQueued {
                    // Deleted while it was being sent: now that it exists, remove it for real.
                    snap.outbox.append(.removeItem(listID: listID, itemID: realID, key: Self.newKey()))
                }
            }
            finish(change)

        case .setChecked(let listID, let itemID, let checked, let key):
            if itemID < 0 { drop(change); return }
            try await api.setChecked(listID: listID, itemID: itemID, checked: checked, idempotencyKey: key)
            try checkEpoch(startEpoch)
            mutateItems(in: listID) { items in
                if let index = items.firstIndex(where: { $0.id == itemID }) { items[index].checked = checked }
            }
            finish(change)

        case .removeItem(let listID, let itemID, let key):
            if itemID < 0 { drop(change); return }
            try await api.removeItem(listID: listID, itemID: itemID, idempotencyKey: key)
            try checkEpoch(startEpoch)
            mutateItems(in: listID) { $0.removeAll { $0.id == itemID } }
            finish(change)

        case .clearChecked(let listID, let key):
            try await api.clearChecked(listID: listID, idempotencyKey: key)
            try checkEpoch(startEpoch)
            mutateItems(in: listID) { $0.removeAll { $0.checked } }
            finish(change)
        }
    }

    private func setItems(_ items: [ListItem], in listID: Int) {
        if let index = snap.lists.firstIndex(where: { $0.id == listID }) {
            snap.lists[index].items = items
        }
    }

    private func mutateItems(in listID: Int, _ body: (inout [ListItem]) -> Void) {
        if let index = snap.lists.firstIndex(where: { $0.id == listID }), var items = snap.lists[index].items {
            body(&items)
            snap.lists[index].items = items
        }
    }

    /// The server took the change.
    private func finish(_ change: PendingChange) {
        snap.outbox.removeAll { $0.key == change.key }
        persist()
        state.pendingCount = snap.outbox.count
        emit(.list(change.listID))
        emit(.state(state))
    }

    /// The server refused the change for good. Forget it, and anything that depended on it.
    private func drop(_ change: PendingChange) {
        snap.outbox.removeAll { $0.key == change.key }
        if case .addItem(_, let tempID, _, _, _) = change {
            snap.outbox.removeAll { $0.touches(itemID: tempID) }
        }
        persist()
        state.pendingCount = snap.outbox.count
        state.droppedCount += 1
        emit(.list(change.listID))
        emit(.state(state))
    }

    // MARK: State

    private func setSyncing(_ syncing: Bool) {
        guard state.isSyncing != syncing else { return }
        state.isSyncing = syncing
        emit(.state(state))
    }

    private func markOnline() {
        guard !state.isOnline else { return }
        state.isOnline = true
        emit(.state(state))
    }

    private func noteFailure(_ error: APIError) {
        // Only a missing connection says "offline"; a server error means we did reach it.
        let offline = error.code == .network
        if state.isOnline == offline {
            state.isOnline = !offline
            emit(.state(state))
        }
    }

    private func persist() {
        store.save(snap)
    }

    private func emit(_ event: SyncEvent) {
        handler?(event)
    }
}
