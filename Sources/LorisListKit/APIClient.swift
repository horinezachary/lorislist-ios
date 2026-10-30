import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport

/// Sends one request. The app uses URLSession; tests supply their own.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// The default session keeps nothing on disk: no cookies and no cached responses.
    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: APIError.unexpected)
                }
            }
            task.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpected }
        return (data, http)
        #endif
    }
}

// MARK: - Client

/// Talks to the Lori's List JSON API.
///
/// Sign-in gives an access token (60 minutes) and a refresh token (60 days from last use).
/// Two things about the server shape how this client refreshes:
///
/// * Each signed-in device has exactly ONE valid access token. Refreshing replaces it, and
///   the old one stops working at once. So refreshing must be single-flight: if three requests
///   all get a 401, one refresh happens and the other two reuse its result.
/// * A request that gets a 401 may have been sent with a token another request has already
///   replaced. In that case it is simply retried with the current token, without refreshing again.
///
/// A refresh the server refuses (401) ends the session. A refresh that fails because the
/// network or server is down does not: the person stays signed in and can try again.
public actor APIClient {
    private let baseURL: String
    private let deviceName: String
    private let transport: HTTPTransport
    private let store: TokenStore
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private var tokens: StoredTokens?
    private var refreshTask: Task<String, Error>?
    private var onSessionExpired: (@Sendable () -> Void)?
    private var isSigningOut = false

    public init(
        baseURL: URL,
        deviceName: String,
        tokenStore: TokenStore,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.deviceName = String(deviceName.prefix(100))
        self.store = tokenStore
        self.transport = transport
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.tokens = tokenStore.load()
    }

    public var isSignedIn: Bool { tokens != nil }

    /// Called when the server ends the session (the refresh token was refused).
    /// Not called by `logout()`.
    public func setSessionExpiredHandler(_ handler: (@Sendable () -> Void)?) {
        onSessionExpired = handler
    }

    // MARK: Auth

    public func login(username: String, password: String) async throws -> User {
        let body = try json(LoginBody(username: username, password: password, deviceName: deviceName))
        let reply: SignInReply = try await send(Endpoint(method: "POST", path: "/auth/login", body: body, authenticated: false))
        adopt(reply)
        return reply.user
    }

    public func register(firstName: String, lastName: String, username: String, email: String, password: String) async throws -> User {
        let body = try json(RegisterBody(
            firstName: firstName, lastName: lastName, username: username,
            email: email, password: password, deviceName: deviceName))
        let reply: SignInReply = try await send(Endpoint(method: "POST", path: "/auth/register", body: body, authenticated: false))
        adopt(reply)
        return reply.user
    }

    /// Signs this device out. The server is told on a best-effort basis; this device is
    /// signed out either way.
    public func logout() async {
        if tokens != nil {
            // The person chose to sign out, so a refused refresh here is not "session expired".
            isSigningOut = true
            _ = try? await execute(Endpoint(method: "POST", path: "/auth/logout"))
            isSigningOut = false
        }
        clearLocalSession()
    }

    /// Signs out every device, this one included.
    public func logoutEverywhere() async throws {
        try await sendEmpty(Endpoint(method: "POST", path: "/auth/logout-everywhere"))
        clearLocalSession()
    }

    public func sessions() async throws -> [DeviceSession] {
        let reply: SessionsReply = try await send(Endpoint(method: "GET", path: "/auth/sessions"))
        return reply.sessions
    }

    public func revokeSession(id: Int) async throws {
        try await sendEmpty(Endpoint(method: "DELETE", path: "/auth/sessions/\(id)"))
    }

    /// Always succeeds from the server's side, whether or not the address has an account.
    public func requestPasswordReset(email: String) async throws {
        let body = try json(EmailBody(email: email))
        try await sendEmpty(Endpoint(method: "POST", path: "/auth/password-reset", body: body, authenticated: false))
    }

    /// Is the emailed reset link still good? Throws `.notFound` when it has expired or was used.
    public func checkPasswordReset(token: String) async throws {
        try await sendEmpty(Endpoint(
            method: "GET", path: "/auth/password-reset/\(Self.pathSafe(token))", authenticated: false))
    }

    /// Sets a new password from an emailed reset link. The server signs the account out
    /// everywhere, so any session on this phone is over too.
    public func completePasswordReset(token: String, newPassword: String) async throws {
        let body = try json(PasswordBody(password: newPassword))
        try await sendEmpty(Endpoint(
            method: "PUT", path: "/auth/password-reset/\(Self.pathSafe(token))", body: body, authenticated: false))
        // The server ends every session when a password is reset, this phone's included.
        clearLocalSession()
    }

    // MARK: Account

    public func me() async throws -> User {
        let reply: UserReply = try await send(Endpoint(method: "GET", path: "/me"))
        return reply.user
    }

    /// Send only what changed.
    public func updateProfile(firstName: String? = nil, lastName: String? = nil, email: String? = nil, showTips: Bool? = nil) async throws -> User {
        let body = try json(ProfilePatch(firstName: firstName, lastName: lastName, email: email, showTips: showTips))
        let reply: UserReply = try await send(Endpoint(method: "PATCH", path: "/me", body: body))
        return reply.user
    }

    public func changePassword(current: String, new: String) async throws {
        let body = try json(PasswordChangeBody(currentPassword: current, newPassword: new))
        try await sendEmpty(Endpoint(method: "PUT", path: "/me/password", body: body))
    }

    // MARK: Live updates

    /// The request that opens the live stream (`GET /events`), signed with the current access token.
    public func streamRequest() async throws -> URLRequest {
        guard let token = tokens?.accessToken else { throw APIError.sessionExpired }
        guard let url = URL(string: baseURL + "/events") else { throw APIError.unexpected }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Call when the stream answered 401: gets a fresh access token the same way any request would.
    public func renewAccessToken(after request: URLRequest) async throws {
        let rejected = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
        guard let rejected = rejected else { throw APIError.sessionExpired }
        _ = try await accessToken(replacing: rejected)
    }

    // MARK: Lists

    public func colors() async throws -> [ListColorOption] {
        let reply: ColorsReply = try await send(Endpoint(method: "GET", path: "/colors"))
        return reply.colors
    }

    public func lists() async throws -> [ListSummary] {
        let reply: ListsReply = try await send(Endpoint(method: "GET", path: "/lists"))
        return reply.lists
    }

    /// A fingerprint per list the person can see. Compare with the stored ones and fetch only
    /// the lists that differ. Older servers answer `.notFound`.
    public func changes() async throws -> Digest {
        try await send(Endpoint(method: "GET", path: "/changes"))
    }

    public func createList(name: String, color: String) async throws -> ListSummary {
        let body = try json(ListBody(name: name, color: color))
        let reply: ListReply = try await send(Endpoint(method: "POST", path: "/lists", body: body))
        return reply.list
    }

    public func list(id: Int) async throws -> ListDetail {
        let reply: ListDetailReply = try await send(Endpoint(method: "GET", path: "/lists/\(id)"))
        return reply.list
    }

    /// Owner only. Send only what changed.
    public func updateList(id: Int, name: String? = nil, color: String? = nil) async throws -> ListSummary {
        let body = try json(ListBody(name: name, color: color))
        let reply: ListReply = try await send(Endpoint(method: "PATCH", path: "/lists/\(id)", body: body))
        return reply.list
    }

    /// Owner only.
    public func deleteList(id: Int) async throws {
        try await sendEmpty(Endpoint(method: "DELETE", path: "/lists/\(id)"))
    }

    /// Stop seeing a list that was shared with you.
    public func leaveList(id: Int) async throws {
        try await sendEmpty(Endpoint(method: "DELETE", path: "/lists/\(id)/members/me"))
    }

    // MARK: Items

    /// Returns all of the list's items after the new one was added.
    ///
    /// `idempotencyKey` makes a retry safe: sent again with the same key, the server returns
    /// its first answer instead of adding a second item. Use one per queued change.
    public func addItem(listID: Int, name: String, count: Int?, idempotencyKey: String? = nil) async throws -> [ListItem] {
        let body = try json(ItemBody(name: name, count: count))
        let endpoint = Endpoint(
            method: "POST", path: "/lists/\(listID)/items", body: body, headers: Self.keyHeader(idempotencyKey))
        let reply: ItemsReply = try await send(endpoint)
        return reply.items
    }

    public func setChecked(listID: Int, itemID: Int, checked: Bool, idempotencyKey: String? = nil) async throws {
        let body = try json(CheckedBody(checked: checked))
        try await sendEmpty(Endpoint(
            method: "PATCH", path: "/lists/\(listID)/items/\(itemID)", body: body, headers: Self.keyHeader(idempotencyKey)))
    }

    public func removeItem(listID: Int, itemID: Int, idempotencyKey: String? = nil) async throws {
        try await sendEmpty(Endpoint(
            method: "DELETE", path: "/lists/\(listID)/items/\(itemID)", headers: Self.keyHeader(idempotencyKey)))
    }

    /// Removes every crossed-off item. Returns how many were removed.
    @discardableResult
    public func clearChecked(listID: Int, idempotencyKey: String? = nil) async throws -> Int {
        let endpoint = Endpoint(
            method: "DELETE", path: "/lists/\(listID)/items",
            query: [URLQueryItem(name: "checked", value: "true")], headers: Self.keyHeader(idempotencyKey))
        let reply: DeletedReply = try await send(endpoint)
        return reply.deleted
    }

    /// Item names used before, most used first.
    public func suggestions() async throws -> [String] {
        let reply: SuggestionsReply = try await send(Endpoint(method: "GET", path: "/items/suggestions"))
        return reply.suggestions
    }

    // MARK: Sharing

    /// Owner only. The server emails the invitation; its link opens the website.
    public func invite(listID: Int, email: String, permission: SharePermission) async throws {
        let body = try json(InviteBody(email: email, permission: permission.rawValue))
        try await sendEmpty(Endpoint(method: "POST", path: "/lists/\(listID)/shares", body: body))
    }

    public func invitation(key: String) async throws -> ShareInvitation {
        let reply: ShareReply = try await send(Endpoint(method: "GET", path: "/shares/\(Self.pathSafe(key))"))
        return reply.share
    }

    /// Accepting returns the list; declining returns nil.
    public func respond(toInvitation key: String, accept: Bool) async throws -> ListSummary? {
        let body = try json(ShareResponseBody(response: accept ? "accept" : "deny"))
        let (data, http) = try await execute(Endpoint(method: "POST", path: "/shares/\(Self.pathSafe(key))", body: body))
        guard http.statusCode == 200 else { return nil }
        return try decode(ListReply.self, from: data).list
    }
}

// MARK: - Request plumbing

extension APIClient {
    struct Endpoint {
        var method: String
        var path: String
        var query: [URLQueryItem] = []
        var body: Data?
        var authenticated: Bool = true
        var headers: [String: String] = [:]
    }

    /// Keys and tokens from links are letters and digits, but they come from outside the app,
    /// so anything else is escaped rather than trusted to stay inside one path segment.
    static func keyHeader(_ key: String?) -> [String: String] {
        guard let key = key, !key.isEmpty else { return [:] }
        return ["Idempotency-Key": key]
    }

    static func pathSafe(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func json<B: Encodable>(_ value: B) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw APIError.unexpected
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("LorisListKit: could not read \(T.self): \(error)")
            #endif
            throw APIError.unexpected
        }
    }

    private func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let (data, _) = try await execute(endpoint)
        return try decode(T.self, from: data)
    }

    private func sendEmpty(_ endpoint: Endpoint) async throws {
        _ = try await execute(endpoint)
    }

    /// Sends the request, refreshing the access token once if the server turns it down.
    private func execute(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        var sentToken: String?
        if endpoint.authenticated {
            guard let current = tokens?.accessToken else { throw APIError.sessionExpired }
            sentToken = current
        }

        var (data, http) = try await transmit(endpoint, token: sentToken)

        if endpoint.authenticated, http.statusCode == 401, let rejected = sentToken {
            let fresh = try await accessToken(replacing: rejected)
            (data, http) = try await transmit(endpoint, token: fresh)
            if http.statusCode == 401 {
                // A brand-new token was refused too: this session is gone.
                expireSession()
                throw APIError.sessionExpired
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw makeError(status: http.statusCode, data: data, response: http)
        }
        return (data, http)
    }

    private func transmit(_ endpoint: Endpoint, token: String?) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: baseURL + endpoint.path) else { throw APIError.unexpected }
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        guard let url = components.url else { throw APIError.unexpected }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            return try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
    }

    private func makeError(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data),
           let raw = envelope.error.code {
            return APIError(
                code: APIError.Code(rawValue: raw) ?? .unknown,
                status: status, message: envelope.error.message, retryAfter: retryAfter)
        }
        let code: APIError.Code
        if status == 429 {
            code = .tooManyRequests
        } else if status >= 500 {
            code = .serverError
        } else {
            code = .unexpectedResponse
        }
        return APIError(code: code, status: status, message: nil, retryAfter: retryAfter)
    }

    // MARK: Tokens

    private func adopt(_ reply: SignInReply) {
        let fresh = StoredTokens(accessToken: reply.accessToken, refreshToken: reply.refreshToken)
        tokens = fresh
        store.save(fresh)
    }

    private func clearLocalSession() {
        tokens = nil
        store.clear()
    }

    private func expireSession() {
        let wasSignedIn = tokens != nil
        clearLocalSession()
        if wasSignedIn && !isSigningOut { onSessionExpired?() }
    }

    /// A usable access token after `rejected` was turned down. Only one refresh runs at a time.
    private func accessToken(replacing rejected: String) async throws -> String {
        // Another request may have refreshed while this one was in flight.
        if let current = tokens?.accessToken, current != rejected { return current }
        guard tokens != nil else { throw APIError.sessionExpired }

        if let running = refreshTask {
            return try await running.value
        }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        do {
            let token = try await task.value
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh() async throws -> String {
        guard let before = tokens else { throw APIError.sessionExpired }
        let body = try json(RefreshBody(refreshToken: before.refreshToken))
        let (data, http) = try await transmit(
            Endpoint(method: "POST", path: "/auth/refresh", body: body, authenticated: false), token: nil)

        // Signed out or signed in again while the request was out: leave that alone.
        guard tokens?.refreshToken == before.refreshToken else {
            if let current = tokens?.accessToken { return current }
            throw APIError.sessionExpired
        }

        switch http.statusCode {
        case 200:
            let reply = try decode(RefreshReply.self, from: data)
            // The refresh token stays the same; keep ours unless the server sends a new one.
            let updated = StoredTokens(
                accessToken: reply.accessToken,
                refreshToken: reply.refreshToken ?? before.refreshToken)
            tokens = updated
            store.save(updated)
            return updated.accessToken
        case 401:
            expireSession()
            throw APIError.sessionExpired
        default:
            // The server is struggling or busy. Stay signed in; the next request can try again.
            throw makeError(status: http.statusCode, data: data, response: http)
        }
    }
}

// MARK: - Wire types

private struct LoginBody: Encodable {
    let username: String
    let password: String
    let deviceName: String
}

private struct RegisterBody: Encodable {
    let firstName: String
    let lastName: String
    let username: String
    let email: String
    let password: String
    let deviceName: String
}

private struct RefreshBody: Encodable { let refreshToken: String }
private struct EmailBody: Encodable { let email: String }
private struct PasswordBody: Encodable { let password: String }

/// Optional fields that are nil are left out of the JSON, which is what PATCH needs.
private struct ProfilePatch: Encodable {
    var firstName: String?
    var lastName: String?
    var email: String?
    var showTips: Bool?
}

private struct PasswordChangeBody: Encodable {
    let currentPassword: String
    let newPassword: String
}

private struct ListBody: Encodable {
    var name: String?
    var color: String?
}

private struct ItemBody: Encodable {
    let name: String
    let count: Int?
}

private struct CheckedBody: Encodable { let checked: Bool }

private struct InviteBody: Encodable {
    let email: String
    let permission: String
}

private struct ShareResponseBody: Encodable { let response: String }

private struct SignInReply: Decodable {
    let user: User
    let accessToken: String
    let refreshToken: String
}

/// The real refresh response is only the new access token. The user and refresh token the
/// spec lists for it are not sent, so neither is required here.
private struct RefreshReply: Decodable {
    let accessToken: String
    let refreshToken: String?
}

private struct UserReply: Decodable { let user: User }
private struct ColorsReply: Decodable { let colors: [ListColorOption] }
private struct ListsReply: Decodable { let lists: [ListSummary] }
private struct ListReply: Decodable { let list: ListSummary }
private struct ListDetailReply: Decodable { let list: ListDetail }
private struct ItemsReply: Decodable { let items: [ListItem] }
private struct DeletedReply: Decodable { let deleted: Int }
private struct SuggestionsReply: Decodable { let suggestions: [String] }
private struct SessionsReply: Decodable { let sessions: [DeviceSession] }
private struct ShareReply: Decodable { let share: ShareInvitation }
