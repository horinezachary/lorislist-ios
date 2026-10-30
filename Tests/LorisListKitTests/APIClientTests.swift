import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LorisListKit

/// These run the real client against responses captured from the server's own API code
/// (see Fixtures/README.md), so a change in the server's JSON shows up here.
final class APIClientTests: XCTestCase {

    // MARK: Sign in

    func testLoginReadsUserStoresTokensAndSendsDeviceName() async throws {
        let transport = MockTransport { _ in .fixture("login_ok") }
        let (client, store) = Fixtures.client(signedIn: false, transport: transport)

        let user = try await client.login(username: "lori", password: "hunter2hunter2")

        XCTAssertEqual(user.username, "lori")
        XCTAssertEqual(user.fullName, "Lori Horine")
        XCTAssertNil(user.showTips, "sign-in does not send showTips")
        XCTAssertTrue(user.tipsEnabled)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://lorislist.example/api/v1/auth/login")
        XCTAssertNil(sent.bearer, "sign-in must not send a token")
        XCTAssertEqual(sent.jsonBody?["username"] as? String, "lori")
        XCTAssertEqual(sent.jsonBody?["deviceName"] as? String, "Test iPhone")
        let saved = try XCTUnwrap(store.load())
        XCTAssertFalse(saved.accessToken.isEmpty)
        XCTAssertFalse(saved.refreshToken.isEmpty)
        let signedIn = await client.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testWrongPasswordIsInvalidCredentials() async throws {
        let transport = MockTransport { _ in .fixture("login_invalid_credentials") }
        let (client, store) = Fixtures.client(signedIn: false, transport: transport)

        do {
            _ = try await client.login(username: "lori", password: "nope")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCredentials)
            XCTAssertEqual(error.status, 401)
        }
        XCTAssertNil(store.load())
        XCTAssertEqual(transport.requests.count, 1, "a failed sign-in must not trigger a token refresh")
    }

    func testRegisterAcceptsServerSignInShape() async throws {
        let transport = MockTransport { _ in .fixture("register_created") }
        let (client, store) = Fixtures.client(signedIn: false, transport: transport)

        let user = try await client.register(
            firstName: "Lori", lastName: "Horine", username: "lori", email: "lori@example.com", password: "hunter2hunter2")

        XCTAssertEqual(user.email, "lori@example.com")
        XCTAssertNotNil(store.load())
        let body = try XCTUnwrap(transport.requests.first?.jsonBody)
        XCTAssertEqual(body["firstName"] as? String, "Lori")
        XCTAssertEqual(body["password"] as? String, "hunter2hunter2")
    }

    func testRegisterConflictsAreDistinguished() async throws {
        let cases: [(String, APIError.Code)] = [
            ("register_username_taken", .usernameTaken),
            ("register_email_in_use", .emailInUse)
        ]
        for (fixture, expected) in cases {
            let transport = MockTransport { _ in .fixture(fixture) }
            let (client, _) = Fixtures.client(signedIn: false, transport: transport)
            do {
                _ = try await client.register(firstName: "A", lastName: "B", username: "u", email: "e@example.com", password: "password1")
                XCTFail("expected an error for \(fixture)")
            } catch let error as APIError {
                XCTAssertEqual(error.code, expected, fixture)
                XCTAssertEqual(error.status, 409)
            }
        }
    }

    func testRateLimitCarriesRetryAfterAndReadableText() async throws {
        let transport = MockTransport { _ in .fixture("login_rate_limited") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        do {
            _ = try await client.login(username: "amy", password: "x")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .tooManyRequests)
            XCTAssertEqual(error.retryAfter, 900)
            XCTAssertTrue(error.errorDescription?.contains("15 minutes") == true, error.errorDescription ?? "")
        }
    }

    // MARK: Reading

    func testRequestsCarryTheBearerToken() async throws {
        let transport = MockTransport { _ in .fixture("lists_two") }
        let (client, _) = Fixtures.client(access: "abc123", transport: transport)

        _ = try await client.lists()

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.bearer, "Bearer abc123")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/api/v1/lists")
    }

    func testListsDecodeAndSplitIntoMineAndShared() async throws {
        let transport = MockTransport { _ in .fixture("lists_shared_with_amy") }
        let (client, _) = Fixtures.client(transport: transport)

        let lists = try await client.lists()

        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].name, "Weekly Groceries")
        XCTAssertEqual(lists[0].role, .edit)
        XCTAssertEqual(lists[0].owner, "lori")
        let groups = ListGroups(lists)
        XCTAssertTrue(groups.mine.isEmpty)
        XCTAssertEqual(groups.shared.map(\.id), [1])
    }

    func testOwnedListsGoInMine() async throws {
        let transport = MockTransport { _ in .fixture("lists_two") }
        let (client, _) = Fixtures.client(transport: transport)

        let groups = ListGroups(try await client.lists())

        XCTAssertEqual(groups.mine.map(\.name), ["Groceries", "Hardware"])
        XCTAssertTrue(groups.shared.isEmpty)
    }

    func testListWithItemsDecodesCountsAndChecks() async throws {
        let transport = MockTransport { _ in .fixture("list_with_items") }
        let (client, _) = Fixtures.client(transport: transport)

        let list = try await client.list(id: 1)

        XCTAssertEqual(list.summary.name, "Groceries")
        XCTAssertEqual(list.summary.color, "ff9900")
        XCTAssertTrue(list.canEdit)
        XCTAssertEqual(list.items.map(\.name), ["Milk", "Bread", "Eggs"])
        XCTAssertEqual(list.items.map(\.count), [2, nil, 12])
        XCTAssertEqual(list.items.map(\.checked), [true, false, false])
        XCTAssertEqual(list.checkedCount, 1)
    }

    func testViewerGetsReadOnlyList() async throws {
        let transport = MockTransport { _ in .fixture("list_as_viewer") }
        let (client, _) = Fixtures.client(transport: transport)

        let list = try await client.list(id: 1)

        XCTAssertEqual(list.summary.role, .view)
        XCTAssertFalse(list.canEdit)
    }

    func testMissingListIsNotFound() async throws {
        let transport = MockTransport { _ in .fixture("list_not_found") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.list(id: 99999)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testLastChangeAcceptsMillisecondsIsoStringsAndNull() throws {
        let decoder = JSONDecoder()
        func list(_ lastChange: String) throws -> ListSummary {
            let json = #"{"id":1,"name":"A","color":"ff9900","owner":"lori","role":"owner","lastChange":\#(lastChange)}"#
            return try decoder.decode(ListSummary.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try list("1792152001000").lastChange, Date(timeIntervalSince1970: 1_792_152_001))
        XCTAssertEqual(try list(#""2026-10-16T12:00:01.000Z""#).lastChange, Date(timeIntervalSince1970: 1_792_152_001))
        XCTAssertEqual(try list(#""2026-10-16T12:00:01Z""#).lastChange, Date(timeIntervalSince1970: 1_792_152_001))
        XCTAssertNil(try list("null").lastChange)
        XCTAssertNil(try list(#""not a date""#).lastChange)
        let missing = #"{"id":1,"name":"A","color":"ff9900","owner":"lori","role":"owner"}"#
        XCTAssertNil(try decoder.decode(ListSummary.self, from: Data(missing.utf8)).lastChange)
    }

    func testUnknownRoleIsTreatedAsReadOnly() throws {
        let json = #"{"id":1,"name":"A","color":"ff9900","owner":"lori","role":"admin"}"#
        let list = try JSONDecoder().decode(ListSummary.self, from: Data(json.utf8))
        XCTAssertEqual(list.role, .view)
    }

    func testColorsAndSuggestions() async throws {
        let colorsTransport = MockTransport { _ in .fixture("colors") }
        let (client, _) = Fixtures.client(transport: colorsTransport)
        let colors = try await client.colors()
        XCTAssertEqual(colors.map(\.name), ["Orange", "Blue"])
        XCTAssertEqual(colors.map(\.hex), ["ff9900", "3366cc"])

        let suggestionTransport = MockTransport { _ in .fixture("suggestions") }
        let (client2, _) = Fixtures.client(transport: suggestionTransport)
        let names = try await client2.suggestions()
        XCTAssertEqual(names, ["Milk", "Bread", "Eggs"])
    }

    func testSessionsDecodeDatesAndCurrentDevice() async throws {
        let transport = MockTransport { _ in .fixture("sessions") }
        let (client, _) = Fixtures.client(transport: transport)

        let sessions = try await client.sessions()

        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.filter(\.current).count, 1)
        XCTAssertEqual(sessions.first?.deviceName, "Pixel 9")
        XCTAssertNotNil(sessions.first?.lastUsedAt)
        XCTAssertNotNil(sessions.first?.createdAt)
    }

    func testMeIncludesShowTips() async throws {
        let transport = MockTransport { _ in .fixture("me") }
        let (client, _) = Fixtures.client(transport: transport)

        let me = try await client.me()

        XCTAssertEqual(me.username, "lori")
        XCTAssertEqual(me.showTips, true)
    }

    // MARK: Writing

    func testCreateListSendsNameAndColor() async throws {
        let transport = MockTransport { _ in .fixture("list_created") }
        let (client, _) = Fixtures.client(transport: transport)

        let list = try await client.createList(name: "Groceries", color: "ff9900")

        XCTAssertEqual(list.id, 1)
        XCTAssertEqual(list.role, .owner)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.jsonBody?["name"] as? String, "Groceries")
        XCTAssertEqual(sent.jsonBody?["color"] as? String, "ff9900")
    }

    func testRenamingSendsOnlyTheName() async throws {
        let transport = MockTransport { _ in .fixture("list_renamed") }
        let (client, _) = Fixtures.client(transport: transport)

        let list = try await client.updateList(id: 1, name: "Weekly Groceries")

        XCTAssertEqual(list.name, "Weekly Groceries")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "PATCH")
        XCTAssertEqual(sent.url?.path, "/api/v1/lists/1")
        XCTAssertEqual(sent.jsonBody?.keys.sorted(), ["name"])
    }

    func testAddItemReturnsAllItemsAndOmitsMissingCount() async throws {
        let transport = MockTransport { _ in .fixture("item_added_third") }
        let (client, _) = Fixtures.client(transport: transport)

        let items = try await client.addItem(listID: 1, name: "Eggs", count: nil)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(transport.requests.first?.jsonBody?.keys.sorted(), ["name"])

        _ = try await client.addItem(listID: 1, name: "Eggs", count: 12)
        let withCount = try XCTUnwrap(transport.requests.last?.jsonBody)
        XCTAssertEqual(withCount["count"] as? Int, 12)
    }

    func testCrossingOffAnItem() async throws {
        let transport = MockTransport { _ in .fixture("item_checked") }
        let (client, _) = Fixtures.client(transport: transport)

        try await client.setChecked(listID: 1, itemID: 7, checked: true)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "PATCH")
        XCTAssertEqual(sent.url?.path, "/api/v1/lists/1/items/7")
        XCTAssertEqual(sent.jsonBody?["checked"] as? Bool, true)
    }

    func testClearingCrossedOffItemsAsksForCheckedTrue() async throws {
        let transport = MockTransport { _ in .fixture("items_cleared") }
        let (client, _) = Fixtures.client(transport: transport)

        let removed = try await client.clearChecked(listID: 1)

        XCTAssertEqual(removed, 1)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.url?.path, "/api/v1/lists/1/items")
        XCTAssertEqual(sent.url?.query, "checked=true")
    }

    func testRemovingAnItemAcceptsNoContent() async throws {
        let transport = MockTransport { _ in .fixture("item_removed") }
        let (client, _) = Fixtures.client(transport: transport)

        try await client.removeItem(listID: 1, itemID: 2)

        XCTAssertEqual(transport.requests.first?.httpMethod, "DELETE")
    }

    func testViewerCannotAddItems() async throws {
        let transport = MockTransport { _ in .fixture("viewer_add_forbidden") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.addItem(listID: 1, name: "Nope", count: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .forbidden)
            XCTAssertEqual(transport.requests.count, 1, "a 403 is not a reason to refresh the token")
        }
    }

    func testOwnerCannotLeaveOwnList() async throws {
        let transport = MockTransport { _ in .fixture("leave_own_list") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            try await client.leaveList(id: 1)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertNotNil(error.message)
        }
    }

    func testProfileUpdateSendsOnlyChangedFields() async throws {
        let transport = MockTransport { _ in .fixture("me_patched") }
        let (client, _) = Fixtures.client(transport: transport)

        let user = try await client.updateProfile(showTips: false)

        XCTAssertEqual(user.showTips, false)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "PATCH")
        XCTAssertEqual(sent.url?.path, "/api/v1/me")
        XCTAssertEqual(sent.jsonBody?.keys.sorted(), ["showTips"])
        XCTAssertEqual(sent.jsonBody?["showTips"] as? Bool, false)
    }

    func testChangingPasswordWithWrongCurrentPassword() async throws {
        let transport = MockTransport { _ in .fixture("password_wrong_current") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            try await client.changePassword(current: "bad", new: "abcdefgh12")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .wrongPassword)
        }
        let body = try XCTUnwrap(transport.requests.first?.jsonBody)
        XCTAssertEqual(body["currentPassword"] as? String, "bad")
        XCTAssertEqual(body["newPassword"] as? String, "abcdefgh12")
    }

    func testDeletingTheAccountSendsThePasswordAndSignsOut() async throws {
        let expired = Flag()
        let transport = MockTransport { _ in .fixture("account_deleted") }
        let (client, store) = Fixtures.client(transport: transport)
        await client.setSessionExpiredHandler { expired.raise() }

        try await client.deleteAccount(password: "hunter2hunter2")

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.url?.path, "/api/v1/me")
        XCTAssertEqual(sent.jsonBody?["password"] as? String, "hunter2hunter2")
        XCTAssertEqual(sent.bearer, "Bearer access-1")
        XCTAssertNil(store.load())
        let signedIn = await client.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(expired.times, 0, "deleting the account is not an expired session")
    }

    func testDeletingTheAccountWithTheWrongPasswordKeepsTheSession() async throws {
        let transport = MockTransport { _ in .fixture("account_delete_wrong_password") }
        let (client, store) = Fixtures.client(transport: transport)

        do {
            try await client.deleteAccount(password: "bad")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .wrongPassword)
            XCTAssertEqual(error.localizedDescription, "Your password was not correct.")
        }
        XCTAssertNotNil(store.load())
    }

    func testPasswordResetRequestIsAcceptedWithoutSignIn() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_requested") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        try await client.requestPasswordReset(email: "lori@example.com")

        XCTAssertNil(transport.requests.first?.bearer)
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/v1/auth/password-reset")
    }

    // MARK: Sharing

    func testInviteUsesLowercasePermission() async throws {
        let transport = MockTransport { _ in .fixture("share_sent") }
        let (client, _) = Fixtures.client(transport: transport)

        try await client.invite(listID: 1, email: "amy@example.com", permission: .view)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.path, "/api/v1/lists/1/shares")
        XCTAssertEqual(sent.jsonBody?["permission"] as? String, "view")
        XCTAssertEqual(sent.jsonBody?["email"] as? String, "amy@example.com")
    }

    func testInvitationDetailsAndAnswers() async throws {
        let peekTransport = MockTransport { _ in .fixture("share_peek") }
        let (client, _) = Fixtures.client(transport: peekTransport)
        let invitation = try await client.invitation(key: "afb7e71ba6179c2a785abd25d648ab6a")
        XCTAssertEqual(invitation.permission, .edit)
        XCTAssertEqual(invitation.list.name, "Weekly Groceries")
        XCTAssertEqual(invitation.list.owner, "lori")

        let acceptTransport = MockTransport { _ in .fixture("share_accepted") }
        let (accepting, _) = Fixtures.client(transport: acceptTransport)
        let accepted = try await accepting.respond(toInvitation: "k", accept: true)
        XCTAssertEqual(accepted?.role, .edit)
        XCTAssertEqual(acceptTransport.requests.first?.jsonBody?["response"] as? String, "accept")

        let denyTransport = MockTransport { _ in .fixture("share_denied") }
        let (denying, _) = Fixtures.client(transport: denyTransport)
        let declined = try await denying.respond(toInvitation: "k", accept: false)
        XCTAssertNil(declined)
        XCTAssertEqual(denyTransport.requests.first?.jsonBody?["response"] as? String, "deny")
    }

    // MARK: Password reset links

    func testResetLinkThatIsStillGoodIsAccepted() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_token_ok") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        try await client.checkPasswordReset(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90")

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/api/v1/auth/password-reset/a1b2c3d4e5f60718293a4b5c6d7e8f90")
        XCTAssertNil(sent.bearer, "a reset link works without being signed in")
    }

    func testResetLinkThatExpiredOrWasUsedIsNotFound() async throws {
        for fixture in ["password_reset_token_unknown", "password_reset_token_used"] {
            let transport = MockTransport { _ in .fixture(fixture) }
            let (client, _) = Fixtures.client(signedIn: false, transport: transport)
            do {
                try await client.checkPasswordReset(token: "ffffffffffffffffffffffffffffffff")
                XCTFail("expected an error for \(fixture)")
            } catch let error as APIError {
                XCTAssertEqual(error.code, .notFound, fixture)
                XCTAssertEqual(transport.requests.count, 1, "a 404 here must not start a token refresh")
            }
        }
    }

    func testChoosingANewPasswordFromAResetLink() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_completed") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        try await client.completePasswordReset(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90", newPassword: "a-brand-new-password")

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.url?.path, "/api/v1/auth/password-reset/a1b2c3d4e5f60718293a4b5c6d7e8f90")
        XCTAssertEqual(sent.jsonBody?["password"] as? String, "a-brand-new-password")
        XCTAssertEqual(sent.jsonBody?.keys.sorted(), ["password"])
        XCTAssertNil(sent.bearer)
    }

    func testResettingThePasswordEndsTheSessionOnThisPhoneToo() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_completed") }
        let (client, store) = Fixtures.client(transport: transport)

        try await client.completePasswordReset(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90", newPassword: "a-brand-new-password")

        XCTAssertNil(store.load())
        let signedIn = await client.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAResetPasswordThatIsTooShortKeepsTheSession() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_weak_password") }
        let (client, store) = Fixtures.client(transport: transport)

        _ = try? await client.completePasswordReset(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90", newPassword: "short")

        XCTAssertNotNil(store.load())
    }

    func testAResetPasswordThatIsTooShortShowsTheServersMessage() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_weak_password") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        do {
            try await client.completePasswordReset(token: "a1b2c3d4e5f60718293a4b5c6d7e8f90", newPassword: "short")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.errorDescription, "Passwords must be at least 8 characters long.")
        }
    }

    func testLinkPartsAreEscapedInThePath() async throws {
        let transport = MockTransport { _ in .fixture("password_reset_token_unknown") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        _ = try? await client.checkPasswordReset(token: "../me?x=1")

        let path = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertFalse(path.contains("/../"), path)
        XCTAssertFalse(path.contains("?x=1"), path)
    }

    func testInvitationNotFound() async throws {
        let transport = MockTransport { _ in .fixture("share_not_found") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.invitation(key: String(repeating: "e", count: 32))
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    // MARK: Token refresh

    /// The real refresh response is only {accessToken, tokenType, expiresIn}: no user, no
    /// refresh token. The client must cope, and keep the refresh token it already has.
    func testExpiredAccessTokenIsRefreshedAndTheRequestRetried() async throws {
        let transport = MockTransport { request in
            switch (request.url?.path ?? "", request.bearer ?? "") {
            case ("/api/v1/auth/refresh", _):
                return .json(200, #"{"accessToken":"access-2","tokenType":"Bearer","expiresIn":3600}"#)
            case ("/api/v1/lists", "Bearer access-2"):
                return .fixture("lists_two")
            default:
                return .fixture("me_unauthorized")
            }
        }
        let (client, store) = Fixtures.client(access: "access-1", refresh: "refresh-1", transport: transport)

        let lists = try await client.lists()

        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(transport.requests.map { $0.url?.path ?? "" }, ["/api/v1/lists", "/api/v1/auth/refresh", "/api/v1/lists"])
        XCTAssertEqual(transport.requests[1].jsonBody?["refreshToken"] as? String, "refresh-1")
        XCTAssertNil(transport.requests[1].bearer, "refreshing must not send the dead access token")
        XCTAssertEqual(store.load(), StoredTokens(accessToken: "access-2", refreshToken: "refresh-1"))
    }

    /// The server allows one access token per device, so two refreshes would knock each
    /// other out. Parallel requests that all fail must share a single refresh.
    func testParallelRequestsShareOneRefresh() async throws {
        let refreshes = Counter()
        let transport = MockTransport { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/refresh" {
                refreshes.increment()
                try await Task.sleep(nanoseconds: 80_000_000)
                return .json(200, #"{"accessToken":"access-2","tokenType":"Bearer","expiresIn":3600}"#)
            }
            return request.bearer == "Bearer access-2" ? .fixture("lists_two") : .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(access: "access-1", transport: transport)

        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<5 {
                group.addTask { try await client.lists().count }
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }

        XCTAssertEqual(results, [2, 2, 2, 2, 2])
        XCTAssertEqual(refreshes.count, 1, "five failed requests must cause one refresh, not five")
        XCTAssertEqual(store.load()?.accessToken, "access-2")
    }

    /// A request that was sent with a token somebody else has since replaced is retried
    /// with the new token, without refreshing a second time.
    func testRequestRejectedWithAnAlreadyReplacedTokenJustRetries() async throws {
        let refreshes = Counter()
        let interleaved = Flag()
        let box = ClientBox()
        let transport = MockTransport { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/refresh" {
                refreshes.increment()
                return .json(200, #"{"accessToken":"access-2","tokenType":"Bearer","expiresIn":3600}"#)
            }
            if request.bearer == "Bearer access-2" {
                return path.hasSuffix("/me") ? .fixture("me") : .fixture("lists_two")
            }
            // The first /lists request (sent with access-1) is still in flight when another
            // request runs to completion, refreshing the token on the way.
            if path.hasSuffix("/lists"), interleaved.times == 0, let other = box.client {
                interleaved.raise()
                _ = try await other.me()
            }
            return .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(access: "access-1", transport: transport)
        box.client = client

        let lists = try await client.lists()

        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(interleaved.times, 1, "the interleaving request did not run")
        XCTAssertEqual(refreshes.count, 1, "the second request should reuse the first one's refresh")
        XCTAssertEqual(store.load()?.accessToken, "access-2")
    }

    func testRefusedRefreshTokenEndsTheSession() async throws {
        let expired = Flag()
        let transport = MockTransport { request in
            request.url?.path == "/api/v1/auth/refresh" ? .fixture("refresh_invalid") : .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(transport: transport)
        await client.setSessionExpiredHandler { expired.raise() }

        do {
            _ = try await client.lists()
            XCTFail("expected the session to end")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .sessionExpired)
        }

        XCTAssertNil(store.load(), "tokens must be wiped when the refresh token is refused")
        XCTAssertEqual(expired.times, 1)
        let signedIn = await client.isSignedIn
        XCTAssertFalse(signedIn)

        let before = transport.requests.count
        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .sessionExpired)
        }
        XCTAssertEqual(transport.requests.count, before, "once signed out, nothing is sent")
    }

    func testRefreshFailingBecauseOfNetworkKeepsThePersonSignedIn() async throws {
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" { throw URLError(.notConnectedToInternet) }
            return .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .network)
        }

        XCTAssertNotNil(store.load(), "being offline must not sign anyone out")
        let signedIn = await client.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testRefreshFailingBecauseOfServerErrorKeepsThePersonSignedIn() async throws {
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return .json(503, #"{"error":{"code":"api_not_ready","message":"The API is not ready."}}"#)
            }
            return .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .apiNotReady)
        }
        XCTAssertNotNil(store.load())
    }

    func testStillUnauthorizedAfterRefreshEndsTheSession() async throws {
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return .json(200, #"{"accessToken":"access-2","tokenType":"Bearer","expiresIn":3600}"#)
            }
            return .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .sessionExpired)
        }
        XCTAssertNil(store.load())
    }

    // MARK: Signing out

    func testLogoutClearsTokensEvenIfTheServerCannotBeReached() async throws {
        let expired = Flag()
        let transport = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        let (client, store) = Fixtures.client(transport: transport)
        await client.setSessionExpiredHandler { expired.raise() }

        await client.logout()

        XCTAssertNil(store.load())
        let signedIn = await client.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(expired.times, 0, "choosing to sign out is not an expired session")
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/v1/auth/logout")
    }

    func testLogoutDoesNotReportExpiryWhenTheTokenIsAlreadyDead() async throws {
        let expired = Flag()
        let transport = MockTransport { request in
            request.url?.path == "/api/v1/auth/refresh" ? .fixture("refresh_invalid") : .fixture("me_unauthorized")
        }
        let (client, store) = Fixtures.client(transport: transport)
        await client.setSessionExpiredHandler { expired.raise() }

        await client.logout()

        XCTAssertNil(store.load())
        XCTAssertEqual(expired.times, 0)
    }

    func testLogoutEverywhereKeepsSessionIfTheServerRefuses() async throws {
        let transport = MockTransport { _ in .json(500, #"{"error":{"code":"server_error","message":"boom"}}"#) }
        let (client, store) = Fixtures.client(transport: transport)

        do {
            try await client.logoutEverywhere()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .serverError)
        }
        XCTAssertNotNil(store.load())
    }

    func testRevokingAnotherDevice() async throws {
        let transport = MockTransport { _ in .fixture("session_revoked") }
        let (client, _) = Fixtures.client(transport: transport)

        try await client.revokeSession(id: 3)

        XCTAssertEqual(transport.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/v1/auth/sessions/3")
    }

    // MARK: Odd responses

    func testNonJSONErrorFromAProxyIsAServerError() async throws {
        let transport = MockTransport { _ in .json(502, "<html>Bad gateway</html>") }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .serverError)
            XCTAssertEqual(error.status, 502)
        }
    }

    func testGarbageSuccessBodyIsAnUnexpectedResponse() async throws {
        let transport = MockTransport { _ in .json(200, #"{"unexpected":true}"#) }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .unexpectedResponse)
        }
    }

    func testAnUnknownErrorCodeStillShowsTheServersMessage() async throws {
        let transport = MockTransport { _ in .json(418, #"{"error":{"code":"teapot","message":"I am a teapot."}}"#) }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .unknown)
            XCTAssertEqual(error.errorDescription, "I am a teapot.")
        }
    }

    func testNoNetworkIsReportedAsNetworkError() async throws {
        let transport = MockTransport { _ in throw URLError(.timedOut) }
        let (client, _) = Fixtures.client(transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .network)
        }
    }

    func testRequestsFailImmediatelyWhenSignedOut() async throws {
        let transport = MockTransport { _ in .fixture("lists_two") }
        let (client, _) = Fixtures.client(signedIn: false, transport: transport)

        do {
            _ = try await client.lists()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .sessionExpired)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

// MARK: - Sync pieces of the client

extension APIClientTests {
    func testTheChangeDigest() async throws {
        let transport = MockTransport { _ in .fixture("changes_synced") }
        let (client, _) = Fixtures.client(transport: transport)

        let digest = try await client.changes()

        XCTAssertEqual(digest.lists, [Digest.Entry(id: 1, revision: "a79154121b80def1")])
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/v1/changes")
        XCTAssertEqual(transport.requests.first?.bearer, "Bearer access-1")
    }

    func testAListCarriesItsFingerprint() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .fixture("list_synced") })
        let list = try await client.list(id: 1)
        XCTAssertEqual(list.revision, "a79154121b80def1")
    }

    func testAListFromAnOlderServerHasNoFingerprint() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in
            .json(200, #"{"list":{"id":1,"name":"A","color":"ff9900","owner":"lori","role":"owner","canEdit":true,"items":[]}}"#)
        })
        let list = try await client.list(id: 1)
        XCTAssertNil(list.revision)
    }

    func testWritesCanCarryAnIdempotencyKey() async throws {
        let transport = MockTransport { request in
            switch request.httpMethod {
            case "POST": return .fixture("item_added_for_sync")
            case "PATCH": return .fixture("item_checked")
            default: return .fixture("item_removed")
            }
        }
        let (client, _) = Fixtures.client(transport: transport)

        _ = try await client.addItem(listID: 1, name: "Milk", count: 2, idempotencyKey: "key-add-0001")
        try await client.setChecked(listID: 1, itemID: 3, checked: true, idempotencyKey: "key-tick-001")
        try await client.removeItem(listID: 1, itemID: 3, idempotencyKey: "key-del-0001")

        let keys = transport.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertEqual(keys, ["key-add-0001", "key-tick-001", "key-del-0001"])
    }

    func testWritesWithoutAKeySendNone() async throws {
        let transport = MockTransport { _ in .fixture("item_added_for_sync") }
        let (client, _) = Fixtures.client(transport: transport)
        _ = try await client.addItem(listID: 1, name: "Milk", count: nil)
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testTheStreamRequestIsSignedAndAsksForEvents() async throws {
        let (client, _) = Fixtures.client(transport: MockTransport { _ in .json(500, "{}") })
        let request = try await client.streamRequest()
        XCTAssertEqual(request.url?.path, "/api/v1/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testTheStreamRequestNeedsASignIn() async throws {
        let (client, _) = Fixtures.client(signedIn: false, transport: MockTransport { _ in .json(500, "{}") })
        do {
            _ = try await client.streamRequest()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .sessionExpired)
        }
    }
}
