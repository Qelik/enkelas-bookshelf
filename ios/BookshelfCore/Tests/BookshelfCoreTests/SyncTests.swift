import Foundation
import Testing
@testable import BookshelfCore

/// Sync is the one part of this app that can lose data rather than merely
/// annoy someone, so these tests are written around the ways it could:
/// overwriting a change that was never seen, wiping a shelf because a session
/// expired, or resolving a genuine divergence by guessing.
extension StubbedNetwork {

@MainActor
struct SyncTests {

    // MARK: - Harness

    static func makeEngine(
        localBooks: [WireBook] = [],
        signedIn: Bool = true,
        fullName: String = "Ada Lovelace"
    ) -> (SyncEngine, BookshelfStore, UserDefaults, TokenStore) {
        StubServer.reset()
        let suiteName = "sync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tokens = TokenStore.inMemory()

        let store = BookshelfStore(storage: .inMemory())
        if !localBooks.isEmpty { store.commit { $0.books = localBooks } }

        if signedIn {
            tokens.write("test-token")
            defaults.set(try? JSONEncoder().encode(
                AuthUser(id: "u1", email: "a@test.local", fullName: fullName)
            ), forKey: "enkelas-sync-account")
        }

        let client = SyncClient(baseURL: URL(string: "https://sync.test")!, session: StubServer.session())
        let engine = SyncEngine(store: store, client: client, tokens: tokens, defaults: defaults)
        return (engine, store, defaults, tokens)
    }

    /// Set the shelf's timestamp without bumping it.
    ///
    /// `commit` deliberately stamps `updatedAt` itself — that is the whole point
    /// of it — so a test that needs a specific timestamp has to go through
    /// `adopt`, which preserves one.
    static func setUpdatedAt(_ store: BookshelfStore, _ iso: String) {
        var next = store.state
        next.updatedAt = iso
        store.adopt(next)
    }

    static func shelfJSON(books: [(id: String, title: String)], updatedAt: String) -> String {
        let items = books.map { #"{"id":"\#($0.id)","title":"\#($0.title)","status":"reading"}"# }.joined(separator: ",")
        return #"{"blob":{"version":1,"updatedAt":"\#(updatedAt)","books":[\#(items)]},"updatedAt":"\#(updatedAt)"}"#
    }

    // MARK: - Push

    @Test("a push sends the base the server must still be on")
    func pushSendsBase() async throws {
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book(id: "b1")])
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-02-01T00:00:00.000Z"}"#)

        try await engine.push(force: false)

        let sent = try #require(StubServer.lastRequest)
        // Without baseUpdatedAt the server accepts the write unconditionally, and
        // optimistic concurrency stops meaning anything.
        #expect(sent.body?["baseUpdatedAt"].stringValue == "2026-01-01T00:00:00.000Z")
        #expect(sent.body?["force"].isNull == true)
        #expect(sent.body?["blob"]["books"].arrayValue?.count == 1)
        #expect(defaults.string(forKey: "enkelas-sync-base") == "2026-02-01T00:00:00.000Z")
        #expect(engine.status == .idle)
        _ = store
    }

    @Test("a forced push says so instead of sending a base")
    func forcedPushOmitsBase() async throws {
        let (engine, _, defaults, _) = Self.makeEngine(localBooks: [Fixture.book()])
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-02-01T00:00:00.000Z"}"#)

        try await engine.push(force: true)

        let sent = try #require(StubServer.lastRequest)
        #expect(sent.body?["force"].boolValue == true)
        #expect(sent.body?["baseUpdatedAt"].isNull == true)
    }

    // MARK: - The 409

    @Test("a 409 is never resolved silently")
    func conflictAsksRatherThanGuessing() async throws {
        // Both devices edited from the same base, so neither copy contains the
        // other's changes. Picking one automatically throws away real reading.
        let (engine, store, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "local", title: "Local Book")])
        StubServer.routes["PUT /api/data"] = .init(409, Self.shelfJSON(
            books: [("remote", "Remote Book")], updatedAt: "2026-03-01T00:00:00.000Z"
        ))

        try await engine.push(force: false)

        let conflict = try #require(engine.pendingConflict)
        #expect(conflict.origin == .push)
        #expect(conflict.serverBookCount == 1)
        #expect(conflict.localBookCount == 1)
        #expect(conflict.serverState.books.first?.title == "Remote Book")
        // Nothing has been overwritten yet.
        #expect(store.state.books.first?.title == "Local Book")
    }

    @Test("choosing the server's copy adopts it and keeps the server's timestamp")
    func resolveTakingServer() async throws {
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book(id: "local", title: "Local Book")])
        StubServer.routes["PUT /api/data"] = .init(409, Self.shelfJSON(
            books: [("remote", "Remote Book")], updatedAt: "2026-03-01T00:00:00.000Z"
        ))
        try await engine.push(force: false)

        await engine.resolve(useServer: true)

        #expect(store.state.books.map(\.title) == ["Remote Book"])
        // Keeping the server's updatedAt is what stops the very next push from
        // trying to overwrite the version we just accepted.
        #expect(store.state.updatedAt == "2026-03-01T00:00:00.000Z")
        #expect(defaults.string(forKey: "enkelas-sync-base") == "2026-03-01T00:00:00.000Z")
        #expect(engine.pendingConflict == nil)
    }

    @Test("choosing this device's copy forces the overwrite")
    func resolveKeepingLocal() async throws {
        let (engine, store, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "local", title: "Local Book")])
        StubServer.routes["PUT /api/data"] = .init(409, Self.shelfJSON(
            books: [("remote", "Remote Book")], updatedAt: "2026-03-01T00:00:00.000Z"
        ))
        try await engine.push(force: false)
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-04-01T00:00:00.000Z"}"#)

        await engine.resolve(useServer: false)

        #expect(store.state.books.map(\.title) == ["Local Book"])
        let sent = try #require(StubServer.lastRequest)
        // Anything less than force would just 409 again forever.
        #expect(sent.body?["force"].boolValue == true)
    }

    @Test("both resolutions are written to the conflict log")
    func conflictsAreRecorded() async throws {
        let (engine, _, _, _) = Self.makeEngine(localBooks: [Fixture.book()])
        StubServer.routes["PUT /api/data"] = .init(409, Self.shelfJSON(books: [("r", "Remote")], updatedAt: "2026-03-01T00:00:00.000Z"))
        try await engine.push(force: false)
        await engine.resolve(useServer: true)

        // "Where did that session go?" has to have an answer.
        #expect(engine.conflictLog.count == 1)
        #expect(engine.conflictLog[0].origin == "sync push")
        #expect(engine.conflictLog[0].choice.contains("other device"))
    }

    // MARK: - Pull

    @Test("a pull takes the server's copy when the server is ahead")
    func pullAdoptsNewerServer() async throws {
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book(id: "local", title: "Local Book")])
        Self.setUpdatedAt(store, "2026-01-01T00:00:00.000Z")
        // In step as of the last exchange: this device has nothing outstanding,
        // so a newer server copy is simply the next version, not a divergence.
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(
            books: [("remote", "Remote Book")], updatedAt: "2026-05-01T00:00:00.000Z"
        ))

        await engine.pull()

        // No prompt here, and that's right: one side is simply behind, which is
        // not the same thing as a divergence.
        #expect(engine.pendingConflict == nil)
        #expect(store.state.books.map(\.title) == ["Remote Book"])
        #expect(store.state.updatedAt == "2026-05-01T00:00:00.000Z")
    }

    @Test("a pull pushes instead when this device is ahead")
    func pullPushesWhenLocalIsNewer() async throws {
        let (engine, store, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "local", title: "Local Book")])
        Self.setUpdatedAt(store, "2026-09-01T00:00:00.000Z")
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(books: [("r", "Old")], updatedAt: "2026-01-01T00:00:00.000Z"))
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-09-01T00:00:00.000Z"}"#)

        await engine.pull()

        #expect(store.state.books.map(\.title) == ["Local Book"])
        #expect(StubServer.requests("/api/data").contains { $0.method == "PUT" })
    }

    @Test("an account with no shelf yet gets seeded from this device")
    func pullSeedsEmptyAccount() async throws {
        let (engine, _, _, _) = Self.makeEngine(localBooks: [Fixture.book()])
        StubServer.routes["GET /api/data"] = .init(200, #"{"blob":null,"updatedAt":null}"#)
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-01-01T00:00:00.000Z"}"#)

        await engine.pull()

        let put = try #require(StubServer.requests("/api/data").first { $0.method == "PUT" })
        #expect(put.body?["force"].boolValue == true)
    }

    // MARK: - Failure modes

    @Test("an expired session never takes the local shelf with it")
    func unauthorizedKeepsLocalData() async throws {
        // A 401 means the token stopped working — a password change on another
        // device, usually. The books on this phone are still the user's, and
        // deleting them because a session expired would be theft.
        let (engine, store, _, tokens) = Self.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Mine")])
        StubServer.routes["PUT /api/data"] = .init(401, #"{"error":"Not signed in."}"#)

        try? await engine.push(force: false)

        #expect(engine.status == .needsLogin)
        #expect(!engine.isSignedIn)
        #expect(tokens.read() == nil)
        #expect(store.state.books.map(\.title) == ["Mine"])
    }

    @Test("going offline is a status, not a data loss")
    func offlineIsRecoverable() async throws {
        let (engine, store, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Mine")])
        StubServer.failWithOffline = true

        try? await engine.push(force: false)

        #expect(engine.status == .offline)
        #expect(store.state.books.map(\.title) == ["Mine"])
        #expect(engine.isSignedIn)      // still signed in; just unreachable
    }

    @Test("an oversized shelf reports the server's explanation")
    func tooLargeSurfacesTheReason() async throws {
        let (engine, _, _, _) = Self.makeEngine(localBooks: [Fixture.book()])
        StubServer.routes["PUT /api/data"] = .init(413, #"{"error":"This bookshelf is too large to sync (over 8 MB). Export a backup, then remove some books."}"#)

        try? await engine.push(force: false)

        guard case .error(let message) = engine.status else {
            Issue.record("expected an error status, got \(engine.status)")
            return
        }
        // The Worker's message tells the user what to actually do; ours wouldn't.
        #expect(message.contains("too large"))
    }

    // MARK: - Sign-in reconciliation

    @Test("signing in on a device with books, into an account with books, asks")
    func signInWithBothSidesPopulated() async throws {
        let (engine, store, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "l", title: "On This Phone")], signedIn: false)
        StubServer.routes["POST /api/login"] = .init(200, #"{"token":"t","user":{"id":"u1","email":"a@test.local","fullName":"Ada Lovelace"}}"#)
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(books: [("s", "In The Account")], updatedAt: "2026-05-01T00:00:00.000Z"))

        try await engine.signIn(email: "a@test.local", password: "correct-horse-1")

        // Neither copy is behind — they're different. Silently picking either one
        // is how someone loses a shelf on their first sign-in.
        let conflict = try #require(engine.pendingConflict)
        #expect(conflict.origin == .signIn)
        #expect(store.state.books.map(\.title) == ["On This Phone"])
    }

    @Test("signing in on an empty device just loads the account")
    func signInOnEmptyDeviceAdopts() async throws {
        let (engine, store, _, _) = Self.makeEngine(signedIn: false)
        StubServer.routes["POST /api/login"] = .init(200, #"{"token":"t","user":{"id":"u1","email":"a@test.local","fullName":"Ada Lovelace"}}"#)
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(books: [("s", "In The Account")], updatedAt: "2026-05-01T00:00:00.000Z"))

        try await engine.signIn(email: "a@test.local", password: "correct-horse-1")

        #expect(engine.pendingConflict == nil)
        #expect(store.state.books.map(\.title) == ["In The Account"])
    }

    @Test("registering uploads this device's shelf to the new account")
    func registerPushesLocal() async throws {
        let (engine, _, _, tokens) = Self.makeEngine(localBooks: [Fixture.book(id: "l", title: "Mine")], signedIn: false)
        StubServer.routes["POST /api/register"] = .init(200, #"{"token":"fresh","user":{"id":"u2","email":"b@test.local","fullName":"Bram Teller"}}"#)
        StubServer.routes["GET /api/data"] = .init(200, #"{"blob":null,"updatedAt":null}"#)
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-01-01T00:00:00.000Z"}"#)

        try await engine.register(email: "b@test.local", fullName: "Bram Teller", password: "meadow-cipher-3")

        #expect(engine.isSignedIn)
        #expect(tokens.read() == "fresh")
        let put = try #require(StubServer.requests("/api/data").first { $0.method == "PUT" })
        #expect(put.body?["blob"]["books"].arrayValue?.count == 1)
    }

    @Test("the token goes to the token store, never to defaults")
    func tokenIsNotInDefaults() async throws {
        let (engine, _, defaults, tokens) = Self.makeEngine(signedIn: false)
        StubServer.routes["POST /api/login"] = .init(200, #"{"token":"secret-token","user":{"id":"u1","email":"a@test.local","fullName":"Ada Lovelace"}}"#)
        StubServer.routes["GET /api/data"] = .init(200, #"{"blob":null,"updatedAt":null}"#)
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-01-01T00:00:00.000Z"}"#)

        try await engine.signIn(email: "a@test.local", password: "correct-horse-1")

        #expect(tokens.read() == "secret-token")
        // UserDefaults is a plist in the container: backed up, restorable and
        // readable. A 30-day bearer token does not belong in it.
        let dump = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? String }
            .joined(separator: " ")
        #expect(!dump.contains("secret-token"))
        let encoded = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? Data }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: " ")
        #expect(!encoded.contains("secret-token"))
    }

    // MARK: - Sign out and delete

    @Test("signing out pushes unsynced work before clearing the device")
    func signOutFlushesFirst() async throws {
        // Signing out is a privacy boundary, so the shelf has to go — but it must
        // not be the action that loses today's reading.
        let (engine, store, _, tokens) = Self.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Unsynced")])
        StubServer.routes["PUT /api/data"] = .init(200, #"{"ok":true,"updatedAt":"2026-06-01T00:00:00.000Z"}"#)

        let pushed = await engine.signOut()

        #expect(pushed)
        #expect(StubServer.requests("/api/data").contains { $0.method == "PUT" })
        #expect(store.state.books.isEmpty)
        #expect(tokens.read() == nil)
        #expect(engine.status == .signedOut)
    }

    @Test("a failed flush is reported rather than swallowed")
    func signOutReportsFailedFlush() async throws {
        let (engine, _, _, _) = Self.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Unsynced")])
        StubServer.failWithOffline = true

        let pushed = await engine.signOut(clearLocalShelf: false)

        // The caller needs this to warn "you have unsynced changes" before
        // wiping the shelf.
        #expect(!pushed)
    }

    @Test("deleting the account leaves nothing behind on the device")
    func deleteAccountClearsEverything() async throws {
        let (engine, store, defaults, tokens) = Self.makeEngine(localBooks: [Fixture.book()])
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        StubServer.routes["DELETE /api/account"] = .init(200, #"{"ok":true,"deleted":{"clubs":0,"recs":0}}"#)

        try await engine.deleteAccount(password: "correct-horse-1")

        let sent = try #require(StubServer.lastRequest)
        #expect(sent.method == "DELETE")
        // The server requires the password; a stolen token alone must not be
        // enough to erase somebody's library.
        #expect(sent.body?["password"].stringValue == "correct-horse-1")
        #expect(tokens.read() == nil)
        #expect(store.state.books.isEmpty)
        #expect(defaults.string(forKey: "enkelas-sync-base") == nil)
        #expect(engine.status == .signedOut)
    }

    @Test("a wrong password on delete leaves the account alone")
    func deleteAccountWrongPassword() async throws {
        let (engine, store, _, tokens) = Self.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Still Here")])
        StubServer.routes["DELETE /api/account"] = .init(401, #"{"error":"That password isn't right."}"#)

        await #expect(throws: SyncClient.Failure.self) {
            try await engine.deleteAccount(password: "wrong")
        }
        #expect(engine.isSignedIn)
        #expect(tokens.read() != nil)
        #expect(store.state.books.map(\.title) == ["Still Here"])
    }

    // MARK: - Dirty tracking

    @Test("a device is dirty exactly when it has changes the server hasn't seen")
    func dirtyTracking() async throws {
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book()])
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")

        Self.setUpdatedAt(store, "2026-01-01T00:00:00.000Z")
        #expect(!engine.isDirty)

        // Any real mutation stamps a fresh, later timestamp.
        store.commit { $0.books.append(Fixture.book(id: "b2")) }
        #expect(engine.isDirty)
    }

    // MARK: - Regressions

    @Test("the first request after a cold launch carries the token")
    func tokenIsSentImmediately() async throws {
        // Regression: the token used to be actor state set through an `async`
        // method fired from init without awaiting it. A cold launch could send
        // its first request before that landed — unauthenticated, 401, and the
        // app signed the user out by itself. Seen for real on the simulator.
        StubServer.reset()
        let tokens = TokenStore.inMemory()
        tokens.write("cold-launch-token")
        let client = SyncClient(
            baseURL: URL(string: "https://sync.test")!,
            session: StubServer.session(),
            tokenProvider: tokens.read
        )
        StubServer.routes["GET /api/data"] = .init(200, #"{"blob":null,"updatedAt":null}"#)

        _ = try await client.fetchShelf()

        #expect(StubServer.lastAuthorization == "Bearer cold-launch-token")
    }

    @Test("a pull will not overwrite unsynced local work, even from a newer server")
    func pullDoesNotClobberDirtyLocal() async throws {
        // Both sides have moved. The server happens to have the later timestamp,
        // but that does not make this device's unsynced reading disposable.
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book(id: "l", title: "Read On The Train")])
        defaults.set("2026-01-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        Self.setUpdatedAt(store, "2026-02-01T00:00:00.000Z")   // ahead of base → dirty
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(
            books: [("s", "Changed On The Laptop")], updatedAt: "2026-09-01T00:00:00.000Z"
        ))

        await engine.pull()

        #expect(engine.pendingConflict != nil, "a newer server must not silently win over unsynced local changes")
        #expect(store.state.books.map(\.title) == ["Read On The Train"])
    }

    @Test("a pull still adopts freely when this device has nothing outstanding")
    func pullAdoptsWhenClean() async throws {
        let (engine, store, defaults, _) = Self.makeEngine(localBooks: [Fixture.book(id: "l", title: "Old Copy")])
        Self.setUpdatedAt(store, "2026-02-01T00:00:00.000Z")
        // In step with the server as of the last exchange — nothing local to lose.
        defaults.set("2026-02-01T00:00:00.000Z", forKey: "enkelas-sync-base")
        StubServer.routes["GET /api/data"] = .init(200, Self.shelfJSON(
            books: [("s", "Newer Copy")], updatedAt: "2026-09-01T00:00:00.000Z"
        ))

        await engine.pull()

        #expect(engine.pendingConflict == nil)
        #expect(store.state.books.map(\.title) == ["Newer Copy"])
    }

    @Test("the app titles itself after whoever is signed in")
    func personalisedTitle() {
        // Matches renderTitle() in the web app, so a household sharing the app
        // sees the same name on the phone as in the browser.
        let (engine, _, _, _) = Self.makeEngine(signedIn: false)
        #expect(engine.displayTitle == "Enkela's Bookshelf")

        let (mine, _, _, _) = Self.makeEngine(signedIn: true, fullName: "Çelik Hasanaj")
        #expect(mine.displayTitle == "Çelik's Bookshelf")

        // First name only, and a one-word name still works.
        let (single, _, _, _) = Self.makeEngine(signedIn: true, fullName: "Enkela")
        #expect(single.displayTitle == "Enkela's Bookshelf")

        // A blank name falls back rather than rendering "'s Bookshelf".
        let (blank, _, _, _) = Self.makeEngine(signedIn: true, fullName: "   ")
        #expect(blank.displayTitle == "Enkela's Bookshelf")
    }
}


/// "Offline" and "the server didn't answer" are different problems.
///
/// They were one case, and it cost real debugging time: a `wrangler dev` that
/// wasn't running told the user they were offline, so the report came in as
/// "Community isn't loading" rather than "the worker is down". These pin the
/// split so it can't quietly collapse back.
@MainActor
struct ReachabilityTests {

    @Test("no network is offline", arguments: [
        URLError.Code.notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .internationalRoamingOff,
    ])
    func noNetworkIsOffline(_ code: URLError.Code) async throws {
        let (engine, store, _, _) = SyncTests.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Mine")])
        StubServer.failWith = code

        try? await engine.push(force: false)

        #expect(engine.status == .offline)
        // Still signed in, and nothing lost — the shelf is the local copy.
        #expect(engine.isSignedIn)
        #expect(store.state.books.map(\.title) == ["Mine"])
    }

    @Test("a server that doesn't answer says so instead of blaming the connection", arguments: [
        URLError.Code.cannotConnectToHost,
        .cannotFindHost,
        .timedOut,
        .dnsLookupFailed,
    ])
    func unreachableIsNotOffline(_ code: URLError.Code) async throws {
        let (engine, store, _, _) = SyncTests.makeEngine(localBooks: [Fixture.book(id: "b1", title: "Mine")])
        StubServer.failWith = code

        try? await engine.push(force: false)

        #expect(engine.status != .offline, "\(code) is a server problem, not a connection problem")
        guard case .error(let message) = engine.status else {
            Issue.record("expected an error status, got \(engine.status)")
            return
        }
        #expect(message.contains("sync server"))
        #expect(!message.lowercased().contains("you're offline"))
        #expect(store.state.books.map(\.title) == ["Mine"])
    }
}

}
