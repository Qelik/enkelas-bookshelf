import Foundation
import Testing
@testable import BookshelfCore

/// The end-of-book page. What matters here is that it never claims a reading
/// history the data doesn't support — a keepsake is only worth keeping if it's
/// true.
struct BookKeepsakeTests {

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func log(_ id: String, pages: Double, minutes: Double = 0, day: String) -> WireReadingLog {
        WireReadingLog(id: id, date: "\(day)T12:00:00.000Z", pages: pages, minutes: minutes, mood: "", note: "")
    }

    @Test("how long it took is measured from the sessions, not from the shelf date")
    func daysComeFromRealReading() throws {
        // A book moved to "reading" in January and actually opened in June would
        // otherwise claim five months of reading that never happened.
        var book = Fixture.book(status: .finished, logs: [
            Self.log("1", pages: 40, day: "2026-06-01"),
            Self.log("2", pages: 60, day: "2026-06-05"),
        ])
        book.startedAt = "2026-01-01T00:00:00.000Z"
        book.finishedAt = "2026-06-05T00:00:00.000Z"

        let keepsake = book.keepsake(calendar: Self.calendar)
        #expect(keepsake.daysTaken == 5)
        #expect(keepsake.sessions == 2)
        #expect(keepsake.pagesRead == 100)
    }

    @Test("a book read in one sitting says a day, not zero")
    func singleDay() {
        let book = Fixture.book(status: .finished, logs: [Self.log("1", pages: 200, day: "2026-06-01")])
        let keepsake = book.keepsake(calendar: Self.calendar)
        #expect(keepsake.daysTaken == 1)
        #expect(keepsake.summaryLine == "Read in a day, June 2026")
    }

    @Test("hours are only claimed when sessions were actually timed")
    func hoursNeedTiming() {
        // Most sessions carry pages and no minutes. Inventing an hours figure
        // from a page count would be the one number on the card that's made up.
        let untimed = Fixture.book(status: .finished, logs: [Self.log("1", pages: 200, day: "2026-06-01")])
        #expect(untimed.keepsake(calendar: Self.calendar).hoursRead == nil)
        #expect(!untimed.keepsake(calendar: Self.calendar).highlights.contains { $0.label == "hours" })

        let timed = Fixture.book(status: .finished, logs: [
            Self.log("1", pages: 100, minutes: 120, day: "2026-06-01"),
            Self.log("2", pages: 100, minutes: 90, day: "2026-06-02"),
        ])
        #expect(timed.keepsake(calendar: Self.calendar).hoursRead == 3.5)
    }

    @Test("a book with nothing kept has no keepsake to offer")
    func emptyKeepsake() {
        // Offering a blank page as though it were a memento is worse than not
        // offering one.
        var bare = Fixture.book(status: .finished, logs: [])
        bare.review = ""
        #expect(!bare.keepsake(calendar: Self.calendar).hasAnything)

        let withNotes = Fixture.book(status: .finished, logs: [Self.log("1", pages: 10, day: "2026-06-01")])
        #expect(withNotes.keepsake(calendar: Self.calendar).hasAnything)
    }

    @Test("the last thing you marked comes first")
    func newestFirst() throws {
        // What you remember about a book is what you marked near the end of it.
        var book = Fixture.book(status: .finished)
        book.quotes = [
            WireQuote(id: "q1", text: "first", page: 10, at: "2026-06-01T00:00:00.000Z"),
            WireQuote(id: "q2", text: "last", page: 300, at: "2026-06-09T00:00:00.000Z"),
        ]
        book.journal = [
            WireJournalEntry(id: "j1", date: "2026-06-01T00:00:00.000Z", page: 10, text: "starting"),
            WireJournalEntry(id: "j2", date: "2026-06-09T00:00:00.000Z", page: 300, text: "finishing"),
        ]

        let keepsake = book.keepsake(calendar: Self.calendar)
        #expect(keepsake.quotes.first?.text == "last")
        #expect(keepsake.journal.first?.text == "finishing")
    }

    @Test("the highlight tiles only show numbers there are")
    func highlightsSkipZeroes() {
        // A card reading "0 quotes · 0 characters" is a list of things you
        // didn't do.
        let book = Fixture.book(status: .finished, logs: [Self.log("1", pages: 120, day: "2026-06-01")])
        let labels = book.keepsake(calendar: Self.calendar).highlights.map(\.label)
        #expect(labels.contains("pages"))
        #expect(!labels.contains("quotes"))
        #expect(!labels.contains("new words"))
    }
}
