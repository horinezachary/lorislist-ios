import XCTest
@testable import LorisListKit

final class SSEParserTests: XCTestCase {
    private func fixtureLines(dropBlank: Bool) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "events_stream", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        return dropBlank ? lines.filter { !$0.isEmpty } : lines
    }

    private func messages(_ lines: [String]) -> [SSEParser.Message] {
        var parser = SSEParser()
        return lines.compactMap { parser.feed($0) }
    }

    func testTheRecordedStreamYieldsTwoDigests() throws {
        for dropBlank in [false, true] {
            let found = messages(try fixtureLines(dropBlank: dropBlank))
            XCTAssertEqual(found.count, 2, "dropBlank \(dropBlank)")
            for message in found {
                guard case .changes(let data) = message else { return XCTFail("expected a digest") }
                let digest = try JSONDecoder().decode(Digest.self, from: data)
                XCTAssertEqual(digest.lists.count, 1)
                XCTAssertEqual(digest.lists[0].id, 1)
            }
            if case .changes(let first) = found[0], case .changes(let second) = found[1] {
                XCTAssertNotEqual(first, second)
            }
        }
    }

    func testCommentsRetryAndUnknownEventsAreIgnored() {
        XCTAssertTrue(messages([": ping", "retry: 5000", "event: other", "data: {}", "data: {}"]).isEmpty)
    }

    func testTheServerSayingGoodbye() {
        XCTAssertEqual(messages(["event: bye", "data: {}"]), [.bye])
    }

    func testAnEventNameAppliesToTheNextDataLineOnly() {
        XCTAssertEqual(messages(["event: changes", "data: {\"a\":1}", "data: {\"a\":2}"]).count, 1)
    }
}

final class SnapshotStoreTests: XCTestCase {
    func testAFileStoreRoundTripsEverything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lorislist-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSnapshotStore(url: folder.appendingPathComponent("cache.json"))
        XCTAssertNil(store.load())

        var snapshot = CacheSnapshot.empty(owner: "lori")
        snapshot.user = User(username: "lori", firstName: "Lori", lastName: "H", email: "l@example.com")
        snapshot.colors = [ListColorOption(id: 1, hex: "ff9900", name: "Orange")]
        snapshot.suggestions = ["Milk"]
        snapshot.outbox = [.addItem(listID: 1, tempID: -1, name: "Milk", count: nil, key: "k")]
        snapshot.nextTempID = -2
        snapshot.lastSynced = Date(timeIntervalSince1970: 1_800_000_000)
        snapshot.lists = [
            StoredList(detail: ListDetail(
                summary: ListSummary(id: 1, name: "Food", color: "ff9900", owner: "lori", role: .owner,
                                     lastChange: Date(timeIntervalSince1970: 1_700_000_000)),
                canEdit: true, items: [ListItem(id: 3, name: "Eggs", count: 12, checked: true)], revision: "abc")),
            StoredList(summary: ListSummary(id: 2, name: "Shared", color: "3366cc", owner: "amy", role: .view)),
        ]
        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testAFileThatIsNotACacheCountsAsNoCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lorislist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cache.json")
        try Data("{ not json".utf8).write(to: file)
        XCTAssertNil(FileSnapshotStore(url: file).load())
    }
}
