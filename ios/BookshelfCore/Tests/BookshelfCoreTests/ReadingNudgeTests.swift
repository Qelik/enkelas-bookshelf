import Foundation
import Testing
@testable import BookshelfCore

/// The daily nudge.
///
/// Two things matter: it names the right book, and it only says things that are
/// true. A notification claiming "40 pages left" about a book with no page count
/// is worse than no notification — it's the app making things up.
struct ReadingNudgeTests {

    static let now = ISO8601.date(from: "2026-08-06T19:00:00.000Z")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    static func book(
        id: String, title: String, pages: Double = 400,
        status: BookStatus = .reading, read: [(Int, Double)] = []
    ) -> WireBook {
        var b = Fixture.book(id: id, title: title, status: status, totalPages: pages)
        b.logs = read.enumerated().map { i, entry in
            WireReadingLog(id: "\(id)-\(i)", date: ISO8601.string(from: day(entry.0)),
                           pages: entry.1, minutes: 20, mood: "", note: "")
        }
        return b
    }

    static func state(_ books: [WireBook]) -> WireState {
        var s = Normalizer(now: { now }, makeID: { "x" }).defaultState()
        s.books = books
        return s
    }

    // MARK: - Naming the right book

    @Test("the nudge names the book by title")
    func namesTheBook() {
        let state = Self.state([Self.book(id: "b", title: "Intermezzo", read: [(-3, 120)])])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        #expect(nudge.body.contains("Intermezzo") || nudge.title.contains("Intermezzo"))
        #expect(nudge.bookID == "b")
    }

    @Test("with several on the go, it's the one read most recently")
    func picksMostRecent() {
        // Not whichever happens to sit first in the array.
        let state = Self.state([
            Self.book(id: "old", title: "Started In March", read: [(-40, 50)]),
            Self.book(id: "fresh", title: "Last Night's Book", read: [(-1, 30)]),
            Self.book(id: "mid", title: "Last Week", read: [(-6, 40)]),
        ])
        #expect(ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar).bookID == "fresh")
    }

    @Test("a finished book is never the subject")
    func ignoresFinished() {
        let state = Self.state([
            Self.book(id: "done", title: "Finished", status: .finished, read: [(-1, 400)]),
            Self.book(id: "going", title: "Still Going", read: [(-5, 60)]),
        ])
        #expect(ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar).bookID == "going")
    }

    // MARK: - Only true things

    @Test("a book with no page count gets no page or percentage claims")
    func noInventedNumbers() {
        // An imported shelf often has no length. "0 pages left" would be a lie.
        let state = Self.state([Self.book(id: "b", title: "Unknown Length", pages: 0, read: [(-3, 10)])])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        let text = nudge.title + " " + nudge.body
        #expect(!text.contains("%"))
        #expect(!text.contains("pages left"))
        #expect(!text.contains("0 pages"))
    }

    @Test("nearly-done says the real number of pages remaining")
    func nearlyDoneIsAccurate() {
        // 380 of 400 read → 20 left.
        let state = Self.state([Self.book(id: "b", title: "Almost", pages: 400, read: [(-2, 380)])])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        #expect(nudge.body.contains("20 pages") || nudge.title.contains("20"))
    }

    @Test("the days-away count is the real gap")
    func neglectCountIsAccurate() {
        let state = Self.state([Self.book(id: "b", title: "Dusty", read: [(-9, 100)])])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        #expect((nudge.title + nudge.body).contains("9 days"))
    }

    @Test("having read today is acknowledged, not nagged at")
    func doesNotNagAfterReading() {
        let state = Self.state([Self.book(id: "b", title: "Today's Book", read: [(0, 30)])])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        let text = (nudge.title + " " + nudge.body).lowercased()
        // Somebody who has already read shouldn't be told to get on with it.
        #expect(!text.contains("waiting"))
        #expect(!text.contains("hasn't been opened"))
    }

    // MARK: - Nothing to read

    @Test("with nothing on the go it suggests something rather than nagging")
    func genericWhenNothingIsBeingRead() {
        let state = Self.state([Self.book(id: "w", title: "On The Pile", status: .want)])
        let nudge = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        #expect(nudge.body.contains("On The Pile"))
        #expect(nudge.bookID == "w")
    }

    @Test("an empty shelf still produces something sensible")
    func emptyShelf() {
        let nudge = ReadingNudges.nudge(for: Self.state([]), on: Self.now, calendar: Self.calendar)
        #expect(!nudge.title.isEmpty)
        #expect(!nudge.body.isEmpty)
        #expect(nudge.bookID == nil)
    }

    // MARK: - Variety, without randomness

    @Test("the same day always produces the same message")
    func stableWithinADay() {
        // Notifications are scheduled ahead and re-armed on every launch. A random
        // pick would rewrite tomorrow's message each time the app opened.
        let state = Self.state([Self.book(id: "b", title: "Steady", read: [(-3, 100)])])
        let first = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        let second = ReadingNudges.nudge(for: state, on: Self.now, calendar: Self.calendar)
        #expect(first == second)
    }

    @Test("a fortnight of nudges isn't the same sentence fourteen times")
    func variesAcrossDays() {
        let state = Self.state([Self.book(id: "b", title: "Long Read", pages: 900, read: [(-3, 200)])])
        let bodies = Set((0..<14).map {
            ReadingNudges.nudge(for: state, on: Self.day($0), calendar: Self.calendar).body
        })
        // The situation changes as days pass, and the wording varies within each.
        #expect(bodies.count >= 3, "only \(bodies.count) distinct messages in a fortnight")
    }
}

/// The personalised lines — where you left off, in your own words where possible.
struct ReadingNudgePersonalTests {

    static func reading(
        id: String = "b", title: String = "Intermezzo", pages: Double = 400,
        read: [(Int, Double)] = [(-2, 120)], bookmarkPage: Double? = nil, bookmarkNote: String = ""
    ) -> WireBook {
        var b = ReadingNudgeTests.book(id: id, title: title, pages: pages, read: read)
        if bookmarkPage != nil || !bookmarkNote.isEmpty {
            b.bookmark = WireBookmark(page: bookmarkPage, note: bookmarkNote, date: nil)
        }
        return b
    }

    @Test("your own bookmark note is quoted back to you")
    func usesTheBookmarkNote() {
        // The most personal true thing there is. Nothing generated competes.
        let state = ReadingNudgeTests.state([
            Self.reading(bookmarkNote: "the bit where she finally calls him")
        ])
        let nudge = ReadingNudges.nudge(for: state, on: ReadingNudgeTests.now, calendar: ReadingNudgeTests.calendar)
        #expect(nudge.body.contains("the bit where she finally calls him"))
    }

    @Test("a long note is trimmed, not dumped whole into the banner")
    func trimsLongNotes() {
        let long = String(repeating: "a chapter about boats ", count: 10)
        let note = try! #require(ReadingNudges.bookmarkNote(Self.reading(bookmarkNote: long)))
        #expect(note.count <= 61)
        #expect(note.hasSuffix("…"))
    }

    @Test("an empty bookmark note doesn't produce empty quote marks")
    func ignoresBlankNotes() {
        #expect(ReadingNudges.bookmarkNote(Self.reading(bookmarkNote: "   ")) == nil)
        #expect(ReadingNudges.bookmarkNote(Self.reading()) == nil)
    }

    @Test("the page you stopped on comes from the bookmark when there is one")
    func prefersTheBookmarkPage() {
        // The bookmark is where the reader *says* they are; the logs are only
        // where the arithmetic puts them.
        #expect(ReadingNudges.leftOffPage(Self.reading(read: [(-2, 120)], bookmarkPage: 214)) == 214)
        #expect(ReadingNudges.leftOffPage(Self.reading(read: [(-2, 120)])) == 120)
        #expect(ReadingNudges.leftOffPage(Self.reading(read: [])) == nil)
    }

    @Test("an in-progress book is told where it left off")
    func namesThePage() {
        let state = ReadingNudgeTests.state([Self.reading(pages: 662, read: [(-2, 100), (-3, 114)], bookmarkPage: 214)])
        let nudge = ReadingNudges.nudge(for: state, on: ReadingNudgeTests.now, calendar: ReadingNudgeTests.calendar)
        let text = nudge.title + " " + nudge.body
        #expect(text.contains("214") || text.contains("448"))
    }

    @Test("a typical sitting needs enough history to be a real average")
    func paceNeedsHistory() {
        // One session is not a pace. Claiming it is would be the app guessing.
        #expect(ReadingNudges.typicalSitting(Self.reading(read: [(-1, 40)])) == nil)
        #expect(ReadingNudges.typicalSitting(Self.reading(read: [(-1, 40), (-2, 20)])) == 30)
        // Trivial sessions don't make a useful "one sitting" claim either.
        #expect(ReadingNudges.typicalSitting(Self.reading(read: [(-1, 2), (-2, 2)])) == nil)
    }

    @Test("nearly done still wins over the everyday page reminder")
    func strongerSignalsOutrank() {
        // 380 of 400 read: "20 pages left" is a better thing to hear than
        // "you stopped on page 380".
        let state = ReadingNudgeTests.state([Self.reading(pages: 400, read: [(-2, 380)])])
        let nudge = ReadingNudges.nudge(for: state, on: ReadingNudgeTests.now, calendar: ReadingNudgeTests.calendar)
        #expect((nudge.title + nudge.body).contains("20 pages"))
    }

    @Test("a long-neglected book is still greeted as neglected")
    func neglectOutranksPage() {
        let state = ReadingNudgeTests.state([Self.reading(read: [(-40, 120)], bookmarkPage: 120)])
        let nudge = ReadingNudges.nudge(for: state, on: ReadingNudgeTests.now, calendar: ReadingNudgeTests.calendar)
        #expect((nudge.title + nudge.body).contains("40 days"))
    }

    // MARK: - The want-to-read pile

    @Test("the suggested book rotates rather than being the same one daily")
    func rotatesThePile() {
        let pile = (0..<5).map {
            ReadingNudgeTests.book(id: "w\($0)", title: "Waiting \($0)", status: .want)
        }
        let state = ReadingNudgeTests.state(pile)
        let suggested = Set((0..<10).map {
            ReadingNudges.nudge(for: state, on: ReadingNudgeTests.day($0),
                                calendar: ReadingNudgeTests.calendar).bookID
        })
        #expect(suggested.count >= 2, "the same book was suggested every day")
    }

    @Test("a book that has waited months is told so")
    func mentionsHowLongItWaited() {
        var book = ReadingNudgeTests.book(id: "w", title: "The Patient One", status: .want)
        book.addedAt = ISO8601.string(from: ReadingNudgeTests.day(-200))
        let state = ReadingNudgeTests.state([book])

        // Across a fortnight the wait line should come up at least once — it is
        // one of several, chosen by day.
        let texts = (0..<14).map {
            let n = ReadingNudges.nudge(for: state, on: ReadingNudgeTests.day($0),
                                        calendar: ReadingNudgeTests.calendar)
            return n.title + " " + n.body
        }
        #expect(texts.contains { $0.contains("months") })
        #expect(texts.allSatisfy { $0.contains("The Patient One") })
    }
}
