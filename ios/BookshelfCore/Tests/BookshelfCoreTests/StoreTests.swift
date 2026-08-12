import Foundation
import Testing
@testable import BookshelfCore

/// Fixture builders. Deliberately outside the `@MainActor` suite so the
/// non-isolated tests can use them too — a builder that has to hop actors is a
/// builder nobody reaches for.
enum Fixture {
    static func book(
        id: String = "b1",
        title: String = "Test Book",
        status: BookStatus = .reading,
        totalPages: Double = 300,
        logs: [WireReadingLog] = []
    ) -> WireBook {
        let normalizer = Normalizer(now: { Date(timeIntervalSince1970: 0) }, makeID: { id })
        var b = normalizer.normalize(.object(["books": .array([.object([
            "id": .string(id), "title": .string(title),
            "status": .string(status.rawValue), "totalPages": .number(totalPages),
        ])])])).books[0]
        b.logs = logs
        return b
    }

    static func log(_ id: String, pages: Double, on iso: String, note: String = "") -> WireReadingLog {
        WireReadingLog(id: id, date: iso, pages: pages, minutes: 0, mood: "", note: note)
    }

}

@MainActor
struct StoreTests {

    static func shelf(_ books: [WireBook] = []) -> BookshelfStore {
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.books = books }
        return store
    }

    // MARK: - Sessions

    @Test("a session stores the delta, not the page you typed")
    func sessionStoresDelta() {
        // The form asks "what page are you on"; the blob stores per-session
        // pages. Storing the absolute would make every chart wrong the moment
        // someone re-read a chapter, and would double-count on the second entry.
        let store = Self.shelf([Fixture.book(logs: [Fixture.log("l1", pages: 40, on: "2026-01-01T10:00:00.000Z")])])
        store.logSession(bookID: "b1", currentPage: 100)

        let b = store.state.books[0]
        #expect(b.logs.count == 2)
        #expect(b.logs[1].pages == 60)      // 100 - 40 already read
        #expect(b.pagesRead == 100)
    }

    @Test("a session that goes backwards logs zero rather than a negative")
    func sessionCannotGoNegative() {
        // Someone mistypes 20 when they're on page 200. A negative delta would
        // silently subtract from their total.
        let store = Self.shelf([Fixture.book(logs: [Fixture.log("l1", pages: 150, on: "2026-01-01T10:00:00.000Z")])])
        store.logSession(bookID: "b1", currentPage: 20)
        #expect(store.state.books[0].logs[1].pages == 0)
        #expect(store.state.books[0].pagesRead == 150)
    }

    @Test("logging against a want-to-read book starts it")
    func loggingStartsAWantedBook() {
        let store = Self.shelf([Fixture.book(status: .want)])
        store.logSession(bookID: "b1", currentPage: 30)
        #expect(store.state.books[0].status == .reading)
        #expect(store.state.books[0].startedAt != nil)
    }

    @Test("a reader session logs the pages it turned, not a page number")
    func readerSessionLogsItsOwnPages() {
        // An ePub has no page numbers to be "on" — it repaginates with the font
        // size — so the reader reports a count. Sending that through the
        // page-number path turned every eReader sitting into zero pages.
        let store = Self.shelf([Fixture.book(logs: [Fixture.log("l1", pages: 40, on: "2026-01-01T10:00:00.000Z")])])
        store.logReaderSession(bookID: "b1", pages: 12, minutes: 25, note: "📖 eReader session")

        let b = store.state.books[0]
        #expect(b.logs.count == 2)
        #expect(b.logs[1].pages == 12, "12 pages turned, not 12 minus what was already read")
        #expect(b.logs[1].minutes == 25)
        #expect(b.pagesRead == 52)
    }

    @Test("a reader session starts a want-to-read book too")
    func readerSessionStartsAWantedBook() {
        let store = Self.shelf([Fixture.book(status: .want)])
        store.logReaderSession(bookID: "b1", pages: 3, minutes: 4)
        #expect(store.state.books[0].status == .reading)
        #expect(store.state.books[0].startedAt != nil)
    }

    // MARK: - Status

    @Test("re-shelving a book does not rewrite when it was started")
    func startedAtIsNotOverwritten() {
        var b = Fixture.book(status: .want)
        b.startedAt = "2025-06-01T00:00:00.000Z"
        let store = Self.shelf([b])

        store.setStatus(.reading, for: "b1")
        #expect(store.state.books[0].startedAt == "2025-06-01T00:00:00.000Z")

        store.setStatus(.finished, for: "b1")
        #expect(store.state.books[0].startedAt == "2025-06-01T00:00:00.000Z")
        #expect(store.state.books[0].finishedAt != nil)
    }

    @Test("un-finishing a book clears its finish date")
    func reReadingClearsFinish() {
        let store = Self.shelf([Fixture.book(status: .finished)])
        store.setStatus(.finished, for: "b1")
        #expect(store.state.books[0].finishedAt != nil)
        store.setStatus(.reading, for: "b1")
        // Otherwise it stays in the Library counts while sitting on the Reading
        // shelf, and the yearly goal counts it twice.
        #expect(store.state.books[0].finishedAt == nil)
    }

    // MARK: - updatedAt

    @Test("every mutation bumps updatedAt")
    func mutationsBumpTheClock() {
        // updatedAt is what the sync endpoint's optimistic concurrency compares.
        // A change that doesn't bump it is a change the server later refuses or
        // quietly overwrites.
        let store = Self.shelf([Fixture.book()])
        let before = store.state.updatedAt

        store.logSession(bookID: "b1", currentPage: 10)
        #expect(store.state.updatedAt >= before)

        let mid = store.state.updatedAt
        store.toggleOwned(bookID: "b1")
        #expect(store.state.updatedAt >= mid)
    }

    // MARK: - Persistence

    @Test("a shelf survives being reloaded from storage")
    func persistsAndReloads() async {
        let storage = ShelfStorage.inMemory()
        let store = BookshelfStore(storage: storage)
        store.add(book: Fixture.book(title: "Persisted"))
        await store.saveNow()

        let reopened = BookshelfStore(storage: storage)
        #expect(reopened.state.books.count == 1)
        #expect(reopened.state.books[0].title == "Persisted")
        #expect(reopened.loadError == nil)
    }

    @Test("an unreadable shelf reports why instead of silently starting fresh")
    func corruptStorageSurfacesTheError() {
        // Starting empty on top of an unreadable shelf is how someone overwrites
        // the only copy of their library — the next save would flush the blank
        // state over the file. The UI needs to be able to say so.
        let storage = ShelfStorage.inMemory(Data("{ this is not json".utf8))
        let store = BookshelfStore(storage: storage)
        #expect(store.state.books.isEmpty)
        #expect(store.loadError != nil)
    }

    @Test("a stored shelf is normalized on the way in")
    func loadNormalizes() {
        // Whatever wrote the file — an older build, a hand edit, a sync — the
        // in-memory shelf has to satisfy the same invariants as a fresh one.
        let raw = #"{"books":[{"title":"Old","status":"read","tags":["to-read","Fantasy"],"rating":0}]}"#
        let store = BookshelfStore(storage: .inMemory(Data(raw.utf8)))
        let b = store.state.books[0]
        #expect(b.status == .reading)     // "read" isn't a status
        #expect(b.tags == ["Fantasy"])    // Goodreads shelf name stripped
        #expect(b.rating == nil)          // 0 stars means unrated
        #expect(!b.id.isEmpty)
    }

    @Test("deleting a book also removes it from the shelf order")
    func deleteCleansShelfOrder() {
        let store = Self.shelf([Fixture.book(id: "b1"), Fixture.book(id: "b2")])
        store.commit { $0.shelfOrder = ["b1", "b2"] }
        store.delete(bookID: "b1")
        // A dangling id in shelfOrder is harmless today but survives every sync,
        // accumulating forever.
        #expect(store.state.shelfOrder == ["b2"])
        #expect(store.state.books.map(\.id) == ["b2"])
    }
}

struct DerivedTests {

    @Test("pages read sums the sessions")
    func pagesRead() {
        let b = Fixture.book(logs: [
            Fixture.log("l1", pages: 40, on: "2026-01-01T10:00:00.000Z"),
            Fixture.log("l2", pages: 60, on: "2026-01-02T10:00:00.000Z"),
        ])
        #expect(b.pagesRead == 100)
        #expect(b.progress == 100.0 / 300.0)
        #expect(b.pagesRemaining == 200)
    }

    @Test("pages-before uses date order, not array order")
    func pagesBeforeSortsByDate() {
        // Editing an old session appends it to the array, so array order stops
        // being chronological. Summing in array order would compute the baseline
        // against the wrong sessions.
        let early = Fixture.log("early", pages: 40, on: "2026-01-01T10:00:00.000Z")
        let late = Fixture.log("late", pages: 60, on: "2026-01-05T10:00:00.000Z")
        let b = Fixture.book(logs: [late, early])   // deliberately out of order
        #expect(b.pagesBefore(late) == 40)
        #expect(b.pagesBefore(early) == 0)
        #expect(b.pagesBefore(nil) == 100)
    }

    @Test("progress never leaves 0…1 even when over-read")
    func progressClamps() {
        let b = Fixture.book(totalPages: 100, logs: [Fixture.log("l1", pages: 250, on: "2026-01-01T10:00:00.000Z")])
        #expect(b.progress == 1)
        #expect(b.pagesRemaining == 0)
    }

    @Test("a book with no page count has no progress")
    func noTotalNoProgress() {
        let b = Fixture.book(totalPages: 0, logs: [Fixture.log("l1", pages: 30, on: "2026-01-01T10:00:00.000Z")])
        #expect(b.progress == nil)
    }

    @Test("an estimate needs at least two reading days")
    func estimateNeedsAPace() {
        let one = Fixture.book(logs: [Fixture.log("l1", pages: 50, on: "2026-01-01T10:00:00.000Z")])
        // One session says nothing about a rate.
        #expect(one.estimatedFinish() == nil)

        let sameDay = Fixture.book(logs: [
            Fixture.log("l1", pages: 50, on: "2026-01-01T10:00:00.000Z"),
            Fixture.log("l2", pages: 50, on: "2026-01-01T20:00:00.000Z"),
        ])
        #expect(sameDay.estimatedFinish() == nil)
    }

    @Test("an estimate extrapolates the recent pace")
    func estimateComputesDaysLeft() {
        // 100 pages over 5 days = 20/day; 200 left = 10 days.
        let b = Fixture.book(totalPages: 300, logs: [
            Fixture.log("l1", pages: 50, on: "2026-01-01T10:00:00.000Z"),
            Fixture.log("l2", pages: 50, on: "2026-01-05T10:00:00.000Z"),
        ])
        let est = b.estimatedFinish(now: Date(timeIntervalSince1970: 0))
        #expect(est?.daysLeft == 10)
    }

    @Test("a finished or unstarted book has no estimate")
    func estimateOnlyForReading() {
        let logs = [
            Fixture.log("l1", pages: 50, on: "2026-01-01T10:00:00.000Z"),
            Fixture.log("l2", pages: 50, on: "2026-01-05T10:00:00.000Z"),
        ]
        #expect(Fixture.book(status: .finished, logs: logs).estimatedFinish() == nil)
        #expect(Fixture.book(status: .want, logs: logs).estimatedFinish() == nil)
    }

    @Test("search matches title, author and tags, ignoring accents and case")
    func searchMatches() {
        var b = Fixture.book(title: "Wuthering Heights")
        b.author = "Emily Brontë"
        b.tags = ["Classics"]

        #expect(b.matches("wuthering"))
        #expect(b.matches("BRONTE"))        // diacritic-insensitive
        #expect(b.matches("classics"))
        #expect(b.matches(""))              // empty query matches everything
        #expect(b.matches("   "))
        #expect(!b.matches("dickens"))
    }

    @Test("tag and collection lists deduplicate case-insensitively")
    func tagListsDeduplicate() {
        var a = Fixture.book(id: "a")
        a.tags = ["Fantasy", "Adventure"]
        var c = Fixture.book(id: "c")
        c.tags = ["fantasy", "Horror"]      // same tag, different spelling

        var state = Normalizer(now: { Date(timeIntervalSince1970: 0) }, makeID: { "x" }).defaultState()
        state.books = [a, c]
        // Showing "Fantasy" and "fantasy" as two filters is a bug users report as
        // "my tags are duplicated".
        #expect(state.allTags == ["Adventure", "Fantasy", "Horror"])
    }
}

struct StableHueTests {

    @Test("a title's colour is the same on every launch")
    func hueIsDeterministic() {
        // Swift's hashValue is seeded per process, so a placeholder cover built
        // on it changes colour every time the app starts — which reads as the
        // app forgetting something.
        #expect("The Name of the Wind".stableHue == "The Name of the Wind".stableHue)
        #expect((0..<360).contains("The Name of the Wind".stableHue))
        #expect("".stableHue == 0)
    }

    @Test("it matches the web app's hashHue, so a book is the same colour in both", arguments: [
        // Values taken from the real JavaScript, not worked out by hand:
        //   h = 0; for (c of str) h = (h * 31 + c.charCodeAt(0)) >>> 0; h % 360
        ("The Name of the Wind", 306),
        ("Pride and Prejudice", 4),
        ("The Wise Man's Fear", 287),
        ("a", 97),
        ("Brontë", 302),
    ])
    func matchesTheWebApp(_ title: String, _ expected: Int) {
        #expect(title.stableHue == expected, "\(title)")
    }
}
