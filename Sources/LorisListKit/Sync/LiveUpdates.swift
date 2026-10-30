import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Reading Server-Sent Events

/// Reads the server's live stream one line at a time.
///
/// The server sends `event: changes` followed by one `data:` line holding the digest, a blank line,
/// and `: ping` comments to keep the connection alive. `URLSession.AsyncBytes.lines` drops blank
/// lines, so a message is complete when its `data:` line arrives rather than at the blank line.
public struct SSEParser {
    public enum Message: Equatable {
        /// The raw JSON of a digest.
        case changes(Data)
        /// The server is closing the stream on purpose; open a new one.
        case bye
    }

    private var event: String?

    public init() {}

    public mutating func feed(_ line: String) -> Message? {
        if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("retry:") { return nil }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let name = event ?? "message"
            event = nil
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "changes": return .changes(Data(payload.utf8))
            case "bye": return .bye
            default: return nil
            }
        }
        return nil
    }
}

/// Opens the stream and hands back its lines. The app's version uses URLSession; tests supply their own.
public protocol LineStreamer: Sendable {
    /// Throws an `APIError` with the HTTP status when the server does not answer 200.
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
}

#if !canImport(FoundationNetworking)
public struct URLSessionLineStreamer: LineStreamer {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The server sends something at least every 15 seconds, so a minute of silence is a dead link.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpected }
        guard http.statusCode == 200 else {
            let code: APIError.Code = http.statusCode == 401 ? .unauthorized
                : (http.statusCode == 429 ? .tooManyRequests : (http.statusCode >= 500 ? .serverError : .unknown))
            throw APIError(code: code, status: http.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
#endif

// MARK: - Staying connected

/// Keeps a live connection to the server while the app is open, and tells the caller whenever
/// something changed (or may have, when it has to fall back to asking every few seconds).
///
/// It reconnects on its own with a growing delay. If the stream will not stay up three times in a
/// row (a proxy that holds messages back, say) it asks `GET /changes` every `pollInterval`
/// seconds for a while instead, then tries the stream again.
public final class LiveUpdates: @unchecked Sendable {
    public struct Timing: Sendable {
        public var idleTimeout: TimeInterval = 45
        public var pollInterval: TimeInterval = 12
        public var pollingFor: TimeInterval = 300
        public var firstRetry: TimeInterval = 2
        public var longestRetry: TimeInterval = 60

        public init() {}
    }

    private let api: APIClient
    private let streamer: LineStreamer
    private let timing: Timing
    private let onChange: @Sendable (Digest?) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// `onChange` gets the digest the stream delivered, or nil when it is only a reminder to ask the server.
    public init(
        api: APIClient, streamer: LineStreamer, timing: Timing = Timing(),
        onChange: @escaping @Sendable (Digest?) -> Void
    ) {
        self.api = api
        self.streamer = streamer
        self.timing = timing
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    // MARK: The loop

    private enum Outcome {
        case delivered       // at least one message arrived
        case failed
        case unauthorized
        case notSignedIn
    }

    private func run() async {
        var failures = 0
        var pollingUntil: Date?
        var delay = timing.firstRetry

        while !Task.isCancelled {
            if let until = pollingUntil {
                if Date() < until {
                    onChange(nil)
                    if await sleep(timing.pollInterval) { return }
                    continue
                }
                pollingUntil = nil
            }

            switch await streamOnce() {
            case .notSignedIn:
                return
            case .delivered:
                failures = 0
                delay = timing.firstRetry
                if await sleep(1) { return }
            case .unauthorized:
                failures += 1
                if let request = try? await api.streamRequest() {
                    do {
                        try await api.renewAccessToken(after: request)
                    } catch is CancellationError {
                        return
                    } catch let error as APIError where error.code == .sessionExpired {
                        return
                    } catch {
                        // Offline or the server is busy; the delay below covers it.
                    }
                }
                if await sleep(1) { return }
            case .failed:
                failures += 1
                if failures >= 3 {
                    failures = 0
                    delay = timing.firstRetry
                    pollingUntil = Date().addingTimeInterval(timing.pollingFor)
                    continue
                }
                if await sleep(delay + Double.random(in: 0...(delay / 2))) { return }
                delay = min(delay * 2, timing.longestRetry)
            }
        }
    }

    /// Sleeps; returns true if the loop should end because it was cancelled.
    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return Task.isCancelled
        } catch {
            return true
        }
    }

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var count = 0

        func touch() { lock.lock(); last = Date(); lock.unlock() }
        func delivered() { lock.lock(); count += 1; lock.unlock() }
        func idle(longerThan seconds: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last) > seconds
        }
        var messages: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private struct Idle: Error {}

    private func streamOnce() async -> Outcome {
        let request: URLRequest
        do {
            request = try await api.streamRequest()
        } catch {
            return .notSignedIn
        }
        let activity = Activity()
        do {
            let lines = try await streamer.lines(for: request)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [onChange] in
                    var parser = SSEParser()
                    for try await line in lines {
                        activity.touch()
                        guard let message = parser.feed(line) else { continue }
                        switch message {
                        case .changes(let data):
                            if let digest = try? JSONDecoder().decode(Digest.self, from: data) {
                                activity.delivered()
                                onChange(digest)
                            }
                        case .bye:
                            return
                        }
                    }
                }
                group.addTask { [timing] in
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        if activity.idle(longerThan: timing.idleTimeout) { throw Idle() }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
            return activity.messages > 0 ? .delivered : .failed
        } catch is CancellationError {
            return Task.isCancelled ? .notSignedIn : .failed
        } catch let error as APIError where error.code == .unauthorized || error.status == 401 {
            return .unauthorized
        } catch {
            return activity.messages > 0 ? .delivered : .failed
        }
    }
}
