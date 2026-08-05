import Foundation
import Testing
@testable import BookshelfCore

extension StubbedNetwork {

@MainActor
struct CommunityTests {

    static func makeEngine(signedIn: Bool = true) -> (CommunityEngine, BookshelfStore) {
        StubServer.reset()
        let defaults = UserDefaults(suiteName: "community-tests-\(UUID().uuidString)")!
        let tokens = TokenStore.inMemory()
        if signedIn {
            tokens.write("t")
            defaults.set(try? JSONEncoder().encode(
                AuthUser(id: "me", email: "a@test.local", fullName: "Ada Lovelace")
            ), forKey: "enkelas-sync-account")
        }
        let client = SyncClient(
            baseURL: URL(string: "https://sync.test")!,
            session: StubServer.session(),
            tokenProvider: tokens.read
        )
        let store = BookshelfStore(storage: .inMemory())
        let sync = SyncEngine(store: store, client: client, tokens: tokens, defaults: defaults)
        return (CommunityEngine(client: client, sync: sync), store)
    }

    static func board(_ rows: String, capped: Bool = false) -> String {
        #"{"recs":[\#(rows)],"signedIn":true,"capped":\#(capped)}"#
    }

    static func rec(_ id: String, title: String, by uid: String = "someone", up: Int = 0, down: Int = 0, author: String = "", isbn: String = "") -> String {
        #"{"id":"\#(id)","category":"Fantasy","book_title":"\#(title)","book_author":"\#(author)","book_isbn":"\#(isbn)","up":\#(up),"down":\#(down),"myVote":0,"created_by":"\#(uid)","created_at":"2026-01-01T00:00:00.000Z"}"#
    }

    // MARK: - Board

    @Test("the board loads and sorts by score")
    func loadsAndSorts() async {
        let (engine, store) = Self.makeEngine()
        StubServer.routes["GET /api/recs"] = .init(200, Self.board([
            Self.rec("a", title: "Middling", up: 3, down: 1),
            Self.rec("b", title: "Loved", up: 9),
            Self.rec("c", title: "Disliked", up: 1, down: 4),
        ].joined(separator: ",")))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)

        await engine.loadBoard()

        let visible = engine.visibleRecommendations(hidingRead: false, shelf: store.state, category: nil)
        #expect(visible.map(\.title) == ["Loved", "Middling", "Disliked"])
    }

    @Test("blocked authors never reach the list, even if the server sends them")
    func blockedAreFilteredLocallyToo() async {
        // The server already filters. Doing it again here is what makes a block
        // feel instant, and stops the next refresh briefly showing what someone
        // just blocked.
        let (engine, store) = Self.makeEngine()
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[{"blocked_uid":"nuisance"}]}"#)
        StubServer.routes["GET /api/recs"] = .init(200, Self.board([
            Self.rec("a", title: "Fine", by: "friend"),
            Self.rec("b", title: "From the blocked person", by: "nuisance"),
        ].joined(separator: ",")))

        await engine.loadBoard()
        await engine.loadBoard()   // second pass: blocks are known by now

        let titles = engine.visibleRecommendations(hidingRead: false, shelf: store.state, category: nil).map(\.title)
        #expect(titles == ["Fine"])
    }

    @Test("blocking removes their posts immediately")
    func blockingIsImmediate() async {
        let (engine, store) = Self.makeEngine()
        StubServer.routes["GET /api/recs"] = .init(200, Self.board([
            Self.rec("a", title: "Fine", by: "friend"),
            Self.rec("b", title: "Unwanted", by: "nuisance"),
        ].joined(separator: ",")))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        StubServer.routes["POST /api/blocks"] = .init(200, #"{"ok":true}"#)
        await engine.loadBoard()

        await engine.block(uid: "nuisance")

        #expect(engine.blockedUIDs.contains("nuisance"))
        let titles = engine.visibleRecommendations(hidingRead: false, shelf: store.state, category: nil).map(\.title)
        #expect(titles == ["Fine"])
    }

    @Test("you can't block yourself")
    func cannotBlockSelf() async {
        // Nothing good happens down that path, and the server would take it.
        let (engine, _) = Self.makeEngine()
        await engine.block(uid: "me")
        #expect(engine.blockedUIDs.isEmpty)
        #expect(StubServer.requests("/api/blocks").isEmpty)
    }

    @Test("a report that trips the auto-hide takes the post away at once")
    func reportAutoHide() async {
        let (engine, store) = Self.makeEngine()
        StubServer.routes["GET /api/recs"] = .init(200, Self.board(Self.rec("bad", title: "Spam")))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        StubServer.routes["POST /api/recs/bad/report"] = .init(200, #"{"ok":true,"hidden":true}"#)
        let hidden = await engine.report(engine.recommendations[0], reason: .spam, detail: "")

        #expect(hidden)
        #expect(engine.recommendations.isEmpty, "an auto-hidden post shouldn't linger on the reporter's screen")
        let sent = StubServer.lastRequest
        #expect(sent?.body?["reason"].stringValue == "spam")
    }

    @Test("a report below the threshold leaves the post visible")
    func reportBelowThreshold() async {
        // Two reporters aren't enough. Removing it locally anyway would let one
        // person hide anything from themselves *and* imply it was taken down.
        let (engine, _) = Self.makeEngine()
        StubServer.routes["GET /api/recs"] = .init(200, Self.board(Self.rec("x", title: "Contested")))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        StubServer.routes["POST /api/recs/x/report"] = .init(200, #"{"ok":true,"hidden":false}"#)
        let hidden = await engine.report(engine.recommendations[0], reason: .harassment, detail: "")

        #expect(!hidden)
        #expect(engine.recommendations.count == 1)
    }

    @Test("voting updates the tally without refetching the board")
    func voteAdjustsLocally() async {
        let (engine, _) = Self.makeEngine()
        StubServer.routes["GET /api/recs"] = .init(200, Self.board(Self.rec("a", title: "Book", up: 5)))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        StubServer.routes["POST /api/recs/a/vote"] = .init(200, #"{"ok":true,"myVote":1}"#)
        await engine.vote(engine.recommendations[0], 1)
        #expect(engine.recommendations[0].up == 6)
        #expect(engine.recommendations[0].myVote == 1)

        // Same vote again clears it, and the tally has to come back down.
        StubServer.routes["POST /api/recs/a/vote"] = .init(200, #"{"ok":true,"myVote":0}"#)
        await engine.vote(engine.recommendations[0], 1)
        #expect(engine.recommendations[0].up == 5)
        #expect(engine.recommendations[0].myVote == 0)
    }

    // MARK: - Already-read filtering

    @Test("books you've finished are hidden when asked")
    func hidesBooksYouveRead() async {
        let (engine, store) = Self.makeEngine()
        var read = Fixture.book(id: "r", title: "Pride and Prejudice", status: .finished)
        read.author = "Jane Austen"
        store.commit { $0.books = [read] }

        StubServer.routes["GET /api/recs"] = .init(200, Self.board([
            Self.rec("a", title: "Pride and Prejudice", author: "Jane Austen"),
            Self.rec("b", title: "Something New", author: "Someone"),
        ].joined(separator: ",")))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        let hidden = engine.visibleRecommendations(hidingRead: true, shelf: store.state, category: nil)
        #expect(hidden.map(\.title) == ["Something New"])
        // …and the option is genuinely optional.
        let shown = engine.visibleRecommendations(hidingRead: false, shelf: store.state, category: nil)
        #expect(shown.count == 2)
    }

    @Test("two different books with the same title don't hide each other")
    func titleAloneIsNotEnough() async {
        // Plenty of books share a title. Matching on title alone would quietly
        // hide recommendations for books nobody has read.
        let (engine, store) = Self.makeEngine()
        var read = Fixture.book(id: "r", title: "Persuasion", status: .finished)
        read.author = "Jane Austen"
        store.commit { $0.books = [read] }

        StubServer.routes["GET /api/recs"] = .init(200, Self.board(
            Self.rec("a", title: "Persuasion", author: "Robert Cialdini")
        ))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        let visible = engine.visibleRecommendations(hidingRead: true, shelf: store.state, category: nil)
        #expect(visible.count == 1)
    }

    @Test("an ISBN match hides it regardless of how the title is spelled")
    func isbnMatchWins() async {
        let (engine, store) = Self.makeEngine()
        var read = Fixture.book(id: "r", title: "Pride & Prejudice (Penguin Classics)", status: .finished)
        read.isbn = "978-0141439518"
        store.commit { $0.books = [read] }

        StubServer.routes["GET /api/recs"] = .init(200, Self.board(
            Self.rec("a", title: "Pride and Prejudice", author: "Austen", isbn: "9780141439518")
        ))
        StubServer.routes["GET /api/blocks"] = .init(200, #"{"blocks":[]}"#)
        await engine.loadBoard()

        #expect(engine.visibleRecommendations(hidingRead: true, shelf: store.state, category: nil).isEmpty)
    }

    // MARK: - Clubs

    @Test("the club detail carries the spoiler gate's verdict, not the content")
    func clubDetailKeepsTheGate() async throws {
        // The client never filters comments. It shows what arrived and reports
        // the locked-ahead count — the only thing the server will say about
        // what's past your progress.
        let (engine, _) = Self.makeEngine()
        StubServer.routes["GET /api/clubs/c1"] = .init(200, #"""
        {"club":{"id":"c1","book_title":"Test Book"},
         "me":{"uid":"me","display_name":"Ada","role":"member","progress_pct":40},
         "members":[{"uid":"me","display_name":"Ada","role":"member","progress_pct":40},
                    {"uid":"bob","display_name":"Bob","role":"host","progress_pct":90}],
         "joinCode":"ABCD2345"}
        """#)
        StubServer.routes["GET /api/clubs/c1/comments"] = .init(200, #"""
        {"comments":[{"id":"k1","uid":"bob","display_name":"Bob","body":"Nice opening","pos_pct":20,
                      "created_at":"2026-01-01T00:00:00.000Z","reactions":{"counts":{"❤️":2},"mine":["❤️"]}}],
         "lockedAhead":3,"myProgress":40}
        """#)

        let detail = try await engine.detail(clubID: "c1")

        #expect(detail.club.title == "Test Book")
        #expect(detail.members.count == 2)
        #expect(detail.me.progress_pct == 40)
        #expect(detail.comments.count == 1)
        #expect(detail.comments[0].reactions?.counts?["❤️"] == 2)
        // Three comments exist past 40% and none of them arrived.
        #expect(detail.lockedAhead == 3)
        #expect(detail.joinCode == "ABCD2345")
    }

    @Test("posting a comment sends the position it belongs to")
    func commentCarriesItsPosition() async throws {
        // pos_pct is the spoiler gate's key: a comment posted at 80% must never
        // reach someone at 30%, and that only works if the client sends where
        // the reader actually is.
        let (engine, _) = Self.makeEngine()
        StubServer.routes["POST /api/clubs/c1/comments"] = .init(200, #"{"ok":true}"#)

        try await engine.post(clubID: "c1", body: "That twist!", atPercent: 80)

        let sent = try #require(StubServer.lastRequest)
        #expect(sent.body?["posPct"].numberValue == 80)
        #expect(sent.body?["body"].stringValue == "That twist!")
    }

    @Test("the realtime ticket is a ticket, not the session token")
    func realtimeUsesATicket() async throws {
        // A WebSocket URL ends up in proxy and access logs, so it carries a
        // 60-second club-scoped ticket that the REST API refuses outright.
        let (engine, _) = Self.makeEngine()
        StubServer.routes["POST /api/clubs/c1/ws-ticket"] = .init(200, #"{"ticket":"short-lived"}"#)

        let client = SyncClient(baseURL: URL(string: "https://sync.test")!, session: StubServer.session())
        let ticket = try await client.webSocketTicket(clubID: "c1")
        #expect(ticket == "short-lived")

        let url = await client.webSocketURL(clubID: "c1", ticket: ticket)
        #expect(url?.scheme == "wss", "a socket to a https server must not fall back to ws")
        #expect(url?.query?.contains("ticket=short-lived") == true)
        _ = engine
    }

    @Test("a local Worker over http gets a ws socket, not wss")
    func localSocketScheme() async {
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:8799")!, session: StubServer.session())
        let url = await client.webSocketURL(clubID: "c1", ticket: "t")
        #expect(url?.scheme == "ws")
    }
}

}
