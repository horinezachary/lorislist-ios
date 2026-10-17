import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LorisListKit

/// Plays scripted connections: each call to `lines` takes the next script.
final class ScriptedStreamer: LineStreamer, @unchecked Sendable {
    enum Script {
        case lines([String])
        case fail(APIError)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var opened = 0

    init(_ scripts: [Script]) { self.scripts = scripts }

    var connections: Int { lock.withLock { opened } }

    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let script: Script = lock.withLock {
            opened += 1
            return scripts.count > 1 ? scripts.removeFirst() : scripts[0]
        }
        switch script {
        case .fail(let error):
            throw error
        case .lines(let lines):
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        }
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [Digest] = []
    private var reminders = 0

    func add(_ digest: Digest?) {
        lock.withLock {
            if let digest = digest { digests.append(digest) } else { reminders += 1 }
        }
    }

    var received: [Digest] { lock.withLock { digests } }
    var reminderCount: Int { lock.withLock { reminders } }
}

final class LiveUpdatesTests: XCTestCase {
    private func fast() -> LiveUpdates.Timing {
        var timing = LiveUpdates.Timing()
        timing.firstRetry = 0.01
        timing.longestRetry = 0.02
        timing.pollInterval = 0.02
        timing.pollingFor = 30
        return timing
    }

    private func streamLines() throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "events_stream", withExtension: "txt", subdirectory: "Fixtures"))
        // AsyncBytes.lines drops blank lines; do the same.
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func eventually(_ message: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    func testTheRecordedStreamReachesTheCaller() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .json(500, "{}") })
        let streamer = ScriptedStreamer([.lines(try streamLines())])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        await eventually("two digests") { got.received.count >= 2 }
        live.stop()
        XCTAssertEqual(got.received[0].lists.first?.id, 1)
        XCTAssertNotEqual(got.received[0], got.received[1])
    }

    func testItReconnectsAfterTheServerSaysGoodbye() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .json(500, "{}") })
        let lines = ["event: changes", #"data: {"revision":"r1","lists":[]}"#, "event: bye", "data: {}"]
        let streamer = ScriptedStreamer([.lines(lines)])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        await eventually("a second connection") { streamer.connections >= 2 }
        live.stop()
        XCTAssertGreaterThanOrEqual(got.received.count, 2)
    }

    func testAStreamThatWillNotStayUpFallsBackToAsking() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .json(500, "{}") })
        let streamer = ScriptedStreamer([.fail(APIError(code: .serverError, status: 503))])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        await eventually("reminders to ask the server") { got.reminderCount >= 3 }
        live.stop()
        XCTAssertTrue(got.received.isEmpty)
        XCTAssertEqual(streamer.connections, 3, "three tries, then it stops trying the stream for a while")
    }

    func testARejectedTokenIsRenewedAndTheStreamOpensAgain() async throws {
        let refreshes = Counter()
        let transport = MockTransport { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                refreshes.increment()
                return .fixture("refresh_ok")
            }
            return .json(500, "{}")
        }
        let (client, _) = Fixtures.client(transport: transport)
        let streamer = ScriptedStreamer([
            .fail(APIError(code: .unauthorized, status: 401)),
            .lines(try streamLines()),
        ])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        await eventually("digests after renewing") { got.received.count >= 2 }
        live.stop()
        XCTAssertEqual(refreshes.count, 1)
    }

    func testStoppingEndsIt() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .json(500, "{}") })
        let streamer = ScriptedStreamer([.fail(APIError(code: .serverError, status: 503))])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        await eventually("some activity") { streamer.connections >= 1 }
        live.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let settled = streamer.connections + got.reminderCount
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(streamer.connections + got.reminderCount, settled)
    }

    func testNothingStartsWhenSignedOut() async throws {
        let (client, _) = Fixtures.client(signedIn: false, transport: MockTransport { _ in .json(500, "{}") })
        let streamer = ScriptedStreamer([.lines(try streamLines())])
        let got = Collected()
        let live = LiveUpdates(api: client, streamer: streamer, timing: fast()) { got.add($0) }
        live.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        live.stop()
        XCTAssertEqual(streamer.connections, 0)
    }
}
