import Foundation
import Testing
@testable import BookshelfCore

@MainActor
struct BookDetailTests {

    static func shelf(_ book: WireBook) -> BookshelfStore {
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.books = [book] }
        return store
    }

    static var book: WireBook { Fixture.book(id: "b1", status: .reading, totalPages: 400) }

    // MARK: - Finishing

    @Test("finishing tops up the pages you never logged")
    func finishTopsUpPages() {
        // Finishing a 400-page book you only logged 120 pages of would otherwise
        // leave 280 pages missing from every total and chart, forever.
        var b = Self.book
        b.logs = [Fixture.log("l1", pages: 120, on: "2026-01-01T10:00:00.000Z")]
        let store = Self.shelf(b)

        store.finish(bookID: "b1", rating: 4)

        let done = store.state.books[0]
        #expect(done.pagesRead == 400)
        #expect(done.logs.count == 2)
        #expect(done.logs.last?.note == "Finished the book")
        #expect(done.status == .finished)
        #expect(done.rating == 4)
    }

    @Test("a book already at its page count gets no top-up log")
    func noTopUpWhenComplete() {
        var b = Self.book
        b.logs = [Fixture.log("l1", pages: 400, on: "2026-01-01T10:00:00.000Z")]
        let store = Self.shelf(b)
        store.finish(bookID: "b1", rating: nil)
        #expect(store.state.books[0].logs.count == 1)
    }

    @Test("a book with no page count gets no top-up either")
    func noTopUpWithoutTotal() {
        // Otherwise a book with totalPages 0 would log a negative delta.
        let store = Self.shelf(Fixture.book(id: "b1", status: .reading, totalPages: 0))
        store.finish(bookID: "b1", rating: nil)
        #expect(store.state.books[0].logs.isEmpty)
    }

    @Test("re-saving a finished book doesn't stack duplicate history")
    func finishIsIdempotentForHistory() {
        let store = Self.shelf(Self.book)
        store.finish(bookID: "b1", rating: 5)
        store.finish(bookID: "b1", rating: 5)
        // One finish, one history entry — the second save is a correction, not a
        // second reading.
        #expect(store.state.books[0].finishHistory.count == 1)
    }

    @Test("finishing clears the bookmark — the journey's over")
    func finishClearsBookmark() {
        var b = Self.book
        b.bookmark = WireBookmark(page: 120, note: "here", date: "2026-01-01T00:00:00.000Z")
        let store = Self.shelf(b)
        store.finish(bookID: "b1", rating: nil)
        #expect(store.state.books[0].bookmark == nil)
    }

    // MARK: - Re-reading

    @Test("a re-read bumps the count and history without re-counting pages")
    func rereadDoesNotDoubleCountPages() {
        // A re-read isn't new pages on the same copy. Logging them again would
        // double the year's totals and every chart.
        var b = Self.book
        b.status = .finished
        b.logs = [Fixture.log("l1", pages: 400, on: "2026-01-01T10:00:00.000Z")]
        b.finishHistory = [WireFinishRecord(date: "2026-01-01T10:00:00.000Z", rating: 4)]
        let store = Self.shelf(b)

        store.finishReread(bookID: "b1", rating: 5)

        let done = store.state.books[0]
        #expect(done.readCount == 2)
        #expect(done.pagesRead == 400, "pages must not be counted twice")
        #expect(done.finishHistory.count == 2)
        #expect(done.finishHistory.last?.rating == 5)
        #expect(done.rating == 5)
    }

    @Test("an unrated re-read leaves the headline rating alone")
    func unratedRereadKeepsRating() {
        // Each read is rated on its own; skipping the rating shouldn't wipe what
        // you thought of it the first time.
        var b = Self.book
        b.status = .finished
        b.rating = 4
        let store = Self.shelf(b)
        store.finishReread(bookID: "b1", rating: nil)
        #expect(store.state.books[0].rating == 4)
        #expect(store.state.books[0].finishHistory.last?.rating == nil)
    }

    // MARK: - DNF

    @Test("giving up records the reason and clears the bookmark")
    func dnf() {
        var b = Self.book
        b.bookmark = WireBookmark(page: 40, note: "", date: nil)
        let store = Self.shelf(b)
        store.markDidNotFinish(bookID: "b1", reason: "  Too slow  ")
        let done = store.state.books[0]
        #expect(done.status == .dnf)
        #expect(done.dnfReason == "Too slow")
        #expect(done.bookmark == nil)
        #expect(done.finishedAt != nil)
    }

    @Test("giving up on a book that already has a date keeps that date")
    func dnfKeepsExistingDate() {
        var b = Self.book
        b.finishedAt = "2025-03-01T00:00:00.000Z"
        let store = Self.shelf(b)
        store.markDidNotFinish(bookID: "b1", reason: "")
        #expect(store.state.books[0].finishedAt == "2025-03-01T00:00:00.000Z")
    }

    // MARK: - Bookmark

    @Test("an empty bookmark clears rather than storing a blank")
    func emptyBookmarkClears() {
        var b = Self.book
        b.bookmark = WireBookmark(page: 10, note: "old", date: nil)
        let store = Self.shelf(b)
        store.setBookmark(bookID: "b1", page: nil, note: "   ")
        #expect(store.state.books[0].bookmark == nil)
    }

    @Test("a bookmark with only a note is kept")
    func noteOnlyBookmark() {
        let store = Self.shelf(Self.book)
        store.setBookmark(bookID: "b1", page: nil, note: "the bit about the lute")
        #expect(store.state.books[0].bookmark?.note == "the bit about the lute")
        #expect(store.state.books[0].bookmark?.page == nil)
    }

    // MARK: - Lending

    @Test("lending records who has it and since when")
    func lending() {
        let store = Self.shelf(Self.book)
        let when = ISO8601.date(from: "2026-06-01T12:00:00.000Z")!
        store.lend(bookID: "b1", to: "  Sam  ", on: when)

        let b = store.state.books[0]
        #expect(b.lentTo == "Sam")
        #expect(b.isLentOut)
        #expect(b.daysLent(now: ISO8601.date(from: "2026-06-15T12:00:00.000Z")!) == 14)

        store.markReturned(bookID: "b1")
        #expect(!store.state.books[0].isLentOut)
        #expect(store.state.books[0].lentAt == nil)
    }

    @Test("lending to nobody is refused")
    func lendingNeedsAName() {
        let store = Self.shelf(Self.book)
        store.lend(bookID: "b1", to: "   ")
        #expect(!store.state.books[0].isLentOut)
    }

    @Test("a return date is stored as a bare day, and is what a reminder can fire on")
    func lendingWithADueDate() {
        let store = Self.shelf(Self.book)
        let when = ISO8601.date(from: "2026-06-01T12:00:00.000Z")!
        let back = ISO8601.date(from: "2026-06-30T22:00:00.000Z")!
        store.lend(bookID: "b1", to: "Sam", on: when, due: back)

        let b = store.state.books[0]
        // Bare YYYY-MM-DD, the same shape the web app writes `loanDue` in — a date
        // someone named, not an instant.
        #expect(b.lentDue == "2026-06-30")
        #expect(b.lentDueDate != nil)
        #expect(!b.isLentOverdue(now: ISO8601.date(from: "2026-06-29T12:00:00.000Z")!))
        #expect(b.isLentOverdue(now: ISO8601.date(from: "2026-07-02T12:00:00.000Z")!))

        // The boundary, on a fixed calendar. "Overdue" is a comparison of *days*,
        // and which day an instant falls on depends on the reader's timezone — so
        // asserting it against `Calendar.current` would pass or fail depending on
        // where the machine running the tests happens to be.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // The day itself is not yet late.
        #expect(!b.isLentOverdue(now: ISO8601.date(from: "2026-06-30T23:00:00.000Z")!, calendar: utc))
        #expect(b.isLentOverdue(now: ISO8601.date(from: "2026-07-01T00:30:00.000Z")!, calendar: utc))
    }

    @Test("an open-ended loan has no date, and nothing to remind about")
    func lendingWithoutADueDate() {
        let store = Self.shelf(Self.book)
        store.lend(bookID: "b1", to: "Sam")
        #expect(store.state.books[0].lentDue.isEmpty)
        #expect(store.state.books[0].lentDueDate == nil)
        #expect(!store.state.books[0].isLentOverdue())
    }

    @Test("getting the book back clears the deadline with it")
    func returningClearsTheDueDate() {
        // Left behind, it would re-arm a reminder for a book already on the shelf —
        // and the reminders are rebuilt wholesale from the shelf every time.
        let store = Self.shelf(Self.book)
        store.lend(bookID: "b1", to: "Sam", due: ISO8601.date(from: "2026-06-30T12:00:00.000Z")!)
        store.markReturned(bookID: "b1")

        let b = store.state.books[0]
        #expect(b.lentDue.isEmpty)
        #expect(b.lentDueDate == nil)
        #expect(!b.isLentOut)
    }

    @Test("a due date on a book nobody has is not a loan")
    func dueDateNeedsALoan() {
        // Data can arrive this way from an older build or a hand-edited blob; the
        // date means nothing without somebody holding the book.
        let store = Self.shelf(Self.book)
        store.commit { $0.books[0].lentDue = "2026-06-30" }
        #expect(store.state.books[0].lentDueDate == nil)
        #expect(!store.state.books[0].isLentOverdue())
    }

    // MARK: - Notes

    @Test("all four kinds of note add and delete")
    func notes() {
        let store = Self.shelf(Self.book)
        store.addQuote(bookID: "b1", text: "It was night again.", page: 1)
        store.addJournalEntry(bookID: "b1", text: "Slow start.", page: 40)
        store.addCharacter(bookID: "b1", name: "Kvothe", description: "Narrator")
        store.addVocab(bookID: "b1", word: "alar", definition: "Riding the lightning", page: 300)

        var b = store.state.books[0]
        #expect(b.noteCount == 4)

        store.deleteNote(.quote, bookID: "b1", noteID: b.quotes[0].id)
        store.deleteNote(.vocab, bookID: "b1", noteID: b.vocab[0].id)
        b = store.state.books[0]
        #expect(b.quotes.isEmpty)
        #expect(b.vocab.isEmpty)
        #expect(b.journal.count == 1)
        #expect(b.characters.count == 1)
    }

    @Test("an empty note is not stored")
    func emptyNotesRejected() {
        let store = Self.shelf(Self.book)
        store.addQuote(bookID: "b1", text: "   ", page: nil)
        store.addJournalEntry(bookID: "b1", text: "", page: nil)
        store.addCharacter(bookID: "b1", name: " ", description: "someone")
        store.addVocab(bookID: "b1", word: "", definition: "a word", page: nil)
        #expect(store.state.books[0].noteCount == 0)
    }

    @Test("notes survive a round trip through the wire format")
    func notesRoundTrip() throws {
        // These are the fields M2 adds; if any of them didn't normalize they'd
        // vanish on the next sync.
        let store = Self.shelf(Self.book)
        store.addQuote(bookID: "b1", text: "A line", page: 5)
        store.addJournalEntry(bookID: "b1", text: "A thought", page: 6)
        store.addCharacter(bookID: "b1", name: "Someone", description: "A person")
        store.addVocab(bookID: "b1", word: "word", definition: "meaning", page: 7)
        store.setBookmark(bookID: "b1", page: 120, note: "here")
        store.lend(bookID: "b1", to: "Sam")

        let encoded = try store.state.encodedJSON()
        let reread = try Normalizer().normalize(data: encoded).books[0]

        #expect(reread.quotes.count == 1)
        #expect(reread.journal.count == 1)
        #expect(reread.characters.count == 1)
        #expect(reread.vocab.count == 1)
        #expect(reread.bookmark?.page == 120)
        #expect(reread.lentTo == "Sam")
    }
}

@MainActor
struct ReadingTimerTests {

    static func makeTimer() -> (ReadingTimer, UserDefaults) {
        let defaults = UserDefaults(suiteName: "timer-tests-\(UUID().uuidString)")!
        return (ReadingTimer(defaults: defaults), defaults)
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("a session survives the app being killed")
    func survivesColdLaunch() {
        // The whole point: iOS suspends and eventually kills a backgrounded app.
        // A counter held in memory would silently reset; an absolute start
        // instant on disk doesn't.
        // Started ten minutes ago on the REAL clock: `elapsed` is deliberately
        // derived from `Date()` rather than an injected now, because that is what
        // makes it immune to a suspended app missing ticks. `now:` only decides
        // whether a session is too old to resume.
        let (timer, defaults) = Self.makeTimer()
        timer.start(bookID: "b1", at: Date().addingTimeInterval(-600))

        // The app dies and comes back — a brand-new object over the same store.
        let revived = ReadingTimer(defaults: defaults)
        #expect(revived.running == nil, "nothing is resumed until a book asks for it")
        revived.resume(for: "b1")
        #expect(revived.isRunning(for: "b1"))
        #expect(revived.elapsedMinutes == 10)
    }

    @Test("opening a different book doesn't steal or discard the session")
    func otherBookLeavesItAlone() {
        let (timer, defaults) = Self.makeTimer()
        timer.start(bookID: "b1", at: Self.t0)

        let other = ReadingTimer(defaults: defaults)
        other.resume(for: "b2", now: Self.t0.addingTimeInterval(60))
        #expect(other.running == nil, "b2 gets a clean slate")

        // …and b1's session is still there afterwards.
        let back = ReadingTimer(defaults: defaults)
        back.resume(for: "b1", now: Self.t0.addingTimeInterval(120))
        #expect(back.isRunning(for: "b1"))
    }

    @Test("a session left running overnight is abandoned, not resumed")
    func staleSessionsExpire() {
        // Nobody read for nine hours. Resuming it would log a fictional session.
        let (timer, defaults) = Self.makeTimer()
        timer.start(bookID: "b1", at: Self.t0)

        let next = ReadingTimer(defaults: defaults)
        next.resume(for: "b1", now: Self.t0.addingTimeInterval(13 * 3600))
        #expect(next.running == nil)
        #expect(next.pendingSession(now: Self.t0.addingTimeInterval(13 * 3600)) == nil)
    }

    @Test("stopping returns the minutes and clears the stored session")
    func stopReturnsMinutes() {
        let (timer, defaults) = Self.makeTimer()
        timer.start(bookID: "b1", at: Date().addingTimeInterval(-25 * 60))
        let minutes = timer.stop()
        #expect(minutes == 25)
        #expect(timer.running == nil)
        #expect(ReadingTimer(defaults: defaults).pendingSession() == nil)
    }

    @Test("leaving the screen keeps the session running")
    func pauseDisplayKeepsSession() {
        // Closing a sheet must not discard a running timer — only an explicit
        // Stop, or saving the log, does that.
        let (timer, defaults) = Self.makeTimer()
        timer.start(bookID: "b1", at: Self.t0)
        timer.pauseDisplay()
        #expect(ReadingTimer(defaults: defaults).pendingSession(now: Self.t0.addingTimeInterval(60)) != nil)
    }

    @Test("the readout is derived from the clock, never from ticks")
    func displayIsDerived() {
        // A suspended app misses ticks; deriving from `now - start` can't drift.
        let (timer, _) = Self.makeTimer()
        timer.start(bookID: "b1", at: Date().addingTimeInterval(-(65 * 60 + 5)))
        #expect(timer.display == "1:05:05")

        timer.start(bookID: "b1", at: Date().addingTimeInterval(-95))
        #expect(timer.display == "01:35")
    }
}
