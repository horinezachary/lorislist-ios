import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LorisListKit

/// A stand-in for the network and the server: answers from recorded fixtures, and can be switched
/// off to behave like a phone with no signal.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var isUp = true
    private var stage = "synced"          // "synced" or "afterAdd": which recorded state the server is in
    private var overrides: [String: MockResponse] = [:]
    private var posts: [String] = []      // Idempotency-Key of every add the server accepted
    private var attempts: [String] = []   // ... and of every add that reached it, accepted or not
    private var counts: [String: Int] = [:]
    private var delay: TimeInterval = 0

    /// Seconds to pause before answering, to make requests overlap.
    var latency: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    var up: Bool {
        get { lock.withLock { isUp } }
        set { lock.withLock { isUp = newValue } }
    }

    var state: String {
        get { lock.withLock { stage } }
        set { lock.withLock { stage = newValue } }
    }

    func override(_ key: String, _ response: MockResponse?) {
        lock.withLock { overrides[key] = response }
    }

    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }

    var addKeys: [String] { lock.withLock { posts } }
    var attemptKeys: [String] { lock.withLock { attempts } }

    func respond(_ request: URLRequest) throws -> MockResponse {
        let method = request.httpMethod ?? "GET"
        let path = (request.url?.path ?? "").replacingOccurrences(of: "/api/v1", with: "")
        let key = "\(method) \(path)"
        let (reachable, stage, forced): (Bool, String, MockResponse?) = lock.withLock {
            if self.isUp {
                counts[key, default: 0] += 1
                if key == "POST /lists/1/items" {
                    attempts.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                }
            }
            return (self.isUp, self.stage, overrides[key])
        }
        guard reachable else { throw URLError(.notConnectedToInternet) }
        if let forced = forced { return forced }
        switch key {
        case "GET /changes": return .fixture(stage == "synced" ? "changes_synced" : "changes_after_add")
        case "GET /lists/1": return .fixture(stage == "synced" ? "list_synced" : "list_after_add")
        case "GET /colors": return .fixture("colors")
        case "GET /items/suggestions": return .fixture("suggestions")
        case "POST /lists/1/items":
            lock.withLock {
                posts.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                self.stage = "afterAdd"
            }
            return .fixture("item_added_for_sync")
        case "PATCH /lists/1/items/3", "PATCH /lists/1/items/4":
            return .fixture("item_checked")
        case "DELETE /lists/1/items/3", "DELETE /lists/1/items/4":
            return .fixture("item_removed")
        default:
            return .json(404, #"{"error":{"code":"not_found","message":"No such endpoint."}}"#)
        }
    }
}

final class SyncEngineTests: XCTestCase {
    private func makeEngine(
        server: FakeServer = FakeServer(), signedIn: Bool = true, store: SnapshotStore = InMemorySnapshotStore()
    ) -> (SyncEngine, FakeServer, SnapshotStore) {
        let transport = MockTransport { request in
            let pause = server.latency
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            return try server.respond(request)
        }
        let (client, _) = Fixtures.client(signedIn: signedIn, transport: transport)
        return (SyncEngine(api: client, store: store), server, store)
    }

    private func eventually(_ message: String = "", timeout: TimeInterval = 5, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    // MARK: Fetching

    func testTheFixturesAgreeAboutFingerprints() throws {
        // The recorded digest and list must carry the same fingerprint, or the tests below prove nothing.
        let digest = try JSONDecoder().decode(Digest.self, from: MockResponse.fixture("changes_synced").body)
        let list = try JSONDecoder().decode(ListEnvelope.self, from: MockResponse.fixture("list_synced").body).list
        XCTAssertEqual(digest.lists[0].revision, list.revision)
    }

    func testTheFirstSyncCachesEveryList() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()

        let lists = await engine.lists()
        XCTAssertEqual(lists.map { $0.name }, ["Weekly Groceries"])
        let detail = await engine.list(id: 1)
        XCTAssertEqual(detail?.items.map { $0.name }, ["Eggs", "Cake"])
        XCTAssertEqual(detail?.revision, "a79154121b80def1")
        let colors = await engine.colors()
        XCTAssertEqual(colors.count, 2)
        let hasData = await engine.hasData()
        XCTAssertTrue(hasData)
        XCTAssertEqual(server.count("GET /lists/1"), 1)
    }

    func testAnUnchangedFingerprintFetchesNothingMore() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        await engine.sync()
        await engine.sync()
        XCTAssertEqual(server.count("GET /lists/1"), 1)
        XCTAssertEqual(server.count("GET /changes"), 3)
    }

    func testAChangedFingerprintFetchesThatListAgain() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        server.state = "afterAdd"
        await engine.sync()
        let detail = await engine.list(id: 1)
        XCTAssertEqual(detail?.items.map { $0.name }, ["Eggs", "Cake", "Oat milk"])
        XCTAssertEqual(server.count("GET /lists/1"), 2)
    }

    func testTheStreamsDigestSavesAskingAgain() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        let streamed = try JSONDecoder().decode(Digest.self, from: MockResponse.fixture("changes_after_add").body)
        server.state = "afterAdd"
        await engine.sync(digest: streamed)
        XCTAssertEqual(server.count("GET /changes"), 1, "used the digest it was handed")
        let detail = await engine.list(id: 1)
        XCTAssertEqual(detail?.items.count, 3)
    }

    func testAListMissingFromTheDigestIsForgotten() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        server.override("GET /changes", .fixture("changes_empty"))
        await engine.sync()
        let lists = await engine.lists()
        XCTAssertTrue(lists.isEmpty)
        let detail = await engine.list(id: 1)
        XCTAssertNil(detail)
    }

    func testAServerWithoutLiveUpdatesStillSyncs() async throws {
        let server = FakeServer()
        server.override("GET /changes", .json(404, #"{"error":{"code":"not_found","message":"No such endpoint."}}"#))
        server.override("GET /lists", .json(200, #"{"lists":[{"id":1,"name":"Weekly Groceries","color":"ff9900","owner":"lori","role":"owner"}]}"#))
        let (engine, _, _) = makeEngine(server: server)
        await engine.sync()
        let detail = await engine.list(id: 1)
        XCTAssertEqual(detail?.items.count, 2)
    }

    func testConcurrentSyncsShareTheWork() async throws {
        let slow = FakeServer()
        slow.latency = 0.05   // long enough for the five calls to overlap
        let (engine, server, _) = makeEngine(server: slow)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await engine.sync() } }
        }
        XCTAssertLessThanOrEqual(server.count("GET /changes"), 2)
        let detail = await engine.list(id: 1)
        XCTAssertNotNil(detail)
    }

    // MARK: Offline edits

    func testAnEditMadeOfflineShowsAtOnceAndIsSentWhenTheConnectionReturns() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()

        server.up = false
        let shown = await engine.addItem(listID: 1, name: "Oat milk", count: 3)
        XCTAssertEqual(shown?.items.map { $0.name }, ["Eggs", "Cake", "Oat milk"])
        XCTAssertLessThan(shown?.items.last?.id ?? 0, 0, "a stand-in id until the server has seen it")
        await engine.sync()
        var state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 1)
        XCTAssertFalse(state.isOnline)
        XCTAssertTrue(server.addKeys.isEmpty)

        server.up = true
        await engine.sync()
        state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertTrue(state.isOnline)
        let detail = await engine.list(id: 1)
        XCTAssertEqual(detail?.items.map { $0.id }, [3, 4, 5], "the real id replaced the stand-in")
        XCTAssertEqual(server.addKeys.count, 1)
        XCTAssertFalse(server.addKeys[0].isEmpty)
    }

    func testARetryCarriesTheSameKey() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        // The first attempt reaches the server but the answer is lost.
        server.override("POST /lists/1/items", .json(503, "{}"))
        _ = await engine.addItem(listID: 1, name: "Oat milk", count: 3)
        await engine.sync()
        var state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 1, "a server error keeps the change queued")
        XCTAssertTrue(state.isOnline, "we did reach the server")

        server.override("POST /lists/1/items", nil)
        await engine.sync()
        state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(server.addKeys.count, 1)
        XCTAssertGreaterThanOrEqual(server.attemptKeys.count, 2, "tried at least twice")
        XCTAssertEqual(Set(server.attemptKeys).count, 1, "every try carried the same key")
    }

    func testTicksAndRemovalsMadeOfflineAreAllSent() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        server.up = false
        _ = await engine.setChecked(listID: 1, itemID: 3, checked: true)
        let shown = await engine.removeItem(listID: 1, itemID: 4)
        XCTAssertEqual(shown?.items.map { $0.name }, ["Eggs"])
        XCTAssertEqual(shown?.items.first?.checked, true)

        server.up = true
        await engine.sync()
        let state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(server.count("PATCH /lists/1/items/3"), 1)
        XCTAssertEqual(server.count("DELETE /lists/1/items/4"), 1)
    }

    func testAnItemAddedAndRemovedOfflineNeverReachesTheServer() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        server.up = false
        let added = await engine.addItem(listID: 1, name: "Oops", count: nil)
        let temp = try XCTUnwrap(added?.items.last?.id)
        let shown = await engine.removeItem(listID: 1, itemID: temp)
        XCTAssertEqual(shown?.items.map { $0.name }, ["Eggs", "Cake"])
        let state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
        server.up = true
        await engine.sync()
        XCTAssertTrue(server.addKeys.isEmpty)
    }

    func testAChangeTheServerRefusesIsDroppedAndTheRestGoOn() async throws {
        let (engine, server, _) = makeEngine()
        await engine.sync()
        server.override("PATCH /lists/1/items/3", .fixture("list_not_found"))
        _ = await engine.setChecked(listID: 1, itemID: 3, checked: true)
        _ = await engine.setChecked(listID: 1, itemID: 4, checked: true)
        await engine.sync()
        let state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(state.droppedCount, 1)
        await engine.acknowledgeDropped()
        let after = await engine.currentState()
        XCTAssertEqual(after.droppedCount, 0)
    }

    func testViewersCannotQueueEdits() async throws {
        let server = FakeServer()
        server.override("GET /lists/1", .json(200, """
            {"list":{"id":1,"name":"Shared","color":"3366cc","owner":"amy","role":"view","canEdit":false,"items":[],"revision":"x1"}}
            """))
        server.override("GET /changes", .json(200, #"{"revision":"r","lists":[{"id":1,"revision":"x1"}]}"#))
        let (engine, _, _) = makeEngine(server: server)
        await engine.sync()
        let shown = await engine.addItem(listID: 1, name: "Nope", count: nil)
        XCTAssertNil(shown)
        let state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
    }

    // MARK: Staying out of the way

    func testNothingHappensWhileSignedOutButTheQueueIsKept() async throws {
        let store = InMemorySnapshotStore()
        let (online, server, _) = makeEngine(store: store)
        await online.sync()
        server.up = false
        _ = await online.setChecked(listID: 1, itemID: 3, checked: true)

        let (signedOut, offServer, _) = makeEngine(signedIn: false, store: store)
        await signedOut.sync()
        XCTAssertEqual(offServer.count("GET /changes"), 0)
        let state = await signedOut.currentState()
        XCTAssertEqual(state.pendingCount, 1)
    }

    func testTheCacheAndQueueSurviveARestart() async throws {
        let store = InMemorySnapshotStore()
        let (first, server, _) = makeEngine(store: store)
        await first.sync()
        server.up = false
        _ = await first.addItem(listID: 1, name: "Oat milk", count: 3)

        let (second, _, _) = makeEngine(server: FakeServer(), store: store)
        let lists = await second.lists()
        XCTAssertEqual(lists.count, 1)
        let detail = await second.list(id: 1)
        XCTAssertEqual(detail?.items.map { $0.name }, ["Eggs", "Cake", "Oat milk"])
        let state = await second.currentState()
        XCTAssertEqual(state.pendingCount, 1)
    }

    func testSigningInAsSomeoneElseStartsOver() async throws {
        let (engine, server, _) = makeEngine()
        await engine.attach(username: "lori")
        await engine.sync()
        server.up = false
        _ = await engine.setChecked(listID: 1, itemID: 3, checked: true)

        await engine.attach(username: "LORI")
        var lists = await engine.lists()
        XCTAssertEqual(lists.count, 1, "same person, any capitalisation, keeps the cache")

        await engine.attach(username: "amy")
        lists = await engine.lists()
        XCTAssertTrue(lists.isEmpty)
        let state = await engine.currentState()
        XCTAssertEqual(state.pendingCount, 0)
    }

    func testSigningOutForgetsEverything() async throws {
        let (engine, _, store) = makeEngine()
        await engine.attach(username: "lori")
        await engine.sync()
        await engine.reset()
        let lists = await engine.lists()
        XCTAssertTrue(lists.isEmpty)
        XCTAssertNil(store.load())
    }

    func testEventsAreReported() async throws {
        let (engine, _, _) = makeEngine()
        let seen = EventLog()
        await engine.setHandler { seen.add($0) }
        await engine.sync()
        await eventually("lists event") { seen.sawLists && seen.sawList(1) }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncEvent] = []

    func add(_ event: SyncEvent) { lock.withLock { events.append(event) } }

    var sawLists: Bool {
        lock.withLock { events.contains { if case .lists = $0 { return true } else { return false } } }
    }

    func sawList(_ id: Int) -> Bool {
        lock.withLock { events.contains { if case .list(id) = $0 { return true } else { return false } } }
    }
}

private struct ListEnvelope: Decodable { let list: ListDetail }
