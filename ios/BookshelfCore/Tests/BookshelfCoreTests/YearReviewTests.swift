import Foundation
import Testing
@testable import BookshelfCore

struct YearReviewTests {

    static let now = ISO8601.date(from: "2026-08-04T12:00:00.000Z")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    static func book(
        _ id: String, title: String = "A Book", pages: Double = 300,
        finishedISO: String?, rating: Double? = nil, tags: [String] = [],
        logs: [(Date, Double)] = []
    ) -> WireBook {
        var b = Fixture.book(id: id, title: title, status: .finished, totalPages: pages)
        b.finishedAt = finishedISO
        b.rating = rating
        b.tags = tags
        b.logs = logs.enumerated().map { i, e in
            WireReadingLog(id: "\(id)-\(i)", date: ISO8601.string(from: e.0), pages: e.1,
                           minutes: 0, mood: "", note: "")
        }
        return b
    }

    static func state(_ books: [WireBook]) -> WireState {
        var s = Normalizer(now: { now }, makeID: { "x" }).defaultState()
        s.books = books
        return s
    }

    // MARK: - Review

    @Test("a year is summarised from the books finished in it")
    func summarises() {
        let state = Self.state([
            Self.book("a", title: "Best", pages: 300, finishedISO: "2026-03-01T00:00:00.000Z",
                      rating: 5, tags: ["Fantasy"], logs: [(Self.day(-100), 300)]),
            Self.book("b", title: "Longest", pages: 900, finishedISO: "2026-03-15T00:00:00.000Z",
                      rating: 3, tags: ["Fantasy", "Epic"], logs: [(Self.day(-90), 900)]),
            Self.book("c", title: "Last year's", pages: 200, finishedISO: "2025-05-01T00:00:00.000Z",
                      rating: 4, tags: ["Horror"], logs: [(ISO8601.date(from: "2025-05-01T00:00:00.000Z")!, 200)]),
        ])

        let review = state.yearReview(2026, calendar: Self.calendar)

        #expect(review.booksFinished == 2, "last year's book must not be counted")
        #expect(review.pagesRead == 1200)
        #expect(review.daysReading == 2)
        #expect(review.averageRating == 4)          // (5 + 3) / 2
        #expect(review.topGenre == "Fantasy")       // in both books
        #expect(review.busiestMonth == "March")
        #expect(review.favourite?.title == "Best")
        #expect(review.longest?.title == "Longest")
        #expect(review.hasData)
    }

    @Test("a tie on rating goes to the one you finished most recently")
    func favouriteTieBreak() {
        // The one you just put down is the one you're still thinking about.
        let state = Self.state([
            Self.book("a", title: "Earlier", finishedISO: "2026-01-01T00:00:00.000Z", rating: 5),
            Self.book("b", title: "Later", finishedISO: "2026-06-01T00:00:00.000Z", rating: 5),
        ])
        #expect(state.yearReview(2026, calendar: Self.calendar).favourite?.title == "Later")
    }

    @Test("an empty year says so instead of showing six dashes")
    func emptyYear() {
        // A review of a year you didn't use the app would otherwise invent a
        // "busiest month" out of nothing.
        let review = Self.state([]).yearReview(2026, calendar: Self.calendar)
        #expect(!review.hasData)
        #expect(review.busiestMonth == nil)
        #expect(review.topGenre == nil)
        #expect(review.averageRating == nil)
    }

    @Test("unrated books don't drag the average down")
    func unratedIgnored() {
        // An unrated book is not a zero-star book.
        let state = Self.state([
            Self.book("a", finishedISO: "2026-02-01T00:00:00.000Z", rating: 4),
            Self.book("b", finishedISO: "2026-02-02T00:00:00.000Z", rating: nil),
        ])
        #expect(state.yearReview(2026, calendar: Self.calendar).averageRating == 4)
    }

    @Test("only years with something in them can be reviewed")
    func yearsWithReading() {
        let state = Self.state([
            Self.book("a", finishedISO: "2026-02-01T00:00:00.000Z", logs: [(Self.day(-10), 50)]),
            Self.book("b", finishedISO: "2024-02-01T00:00:00.000Z",
                      logs: [(ISO8601.date(from: "2024-02-01T00:00:00.000Z")!, 50)]),
        ])
        #expect(state.yearsWithReading(calendar: Self.calendar) == [2026, 2024])
    }

    // MARK: - Heatmap

    @Test("the calendar is whole Sunday-aligned weeks")
    func heatmapShape() {
        // A grid whose first column starts partway down reads as crooked.
        let state = Self.state([])
        let grid = state.readingCalendar(weeks: 26, now: Self.now, calendar: Self.calendar)

        #expect(grid.allSatisfy { $0.count == 7 })
        let firstDay = try? #require(grid.first?.first ?? nil)
        if let firstDay {
            #expect(Self.calendar.component(.weekday, from: firstDay.date) == 1, "columns start on Sunday")
        }
    }

    @Test("days after today are left out, not drawn empty")
    func heatmapStopsAtToday() {
        let grid = Self.state([]).readingCalendar(weeks: 4, now: Self.now, calendar: Self.calendar)
        let days = grid.flatMap { $0 }.compactMap { $0 }
        let today = Self.calendar.startOfDay(for: Self.now)
        #expect(days.allSatisfy { $0.date <= today })
        #expect(days.contains { $0.date == today })
    }

    @Test("shading matches the web app's thresholds", arguments: [
        (0.0, 0), (1.0, 1), (24.0, 1), (25.0, 2), (59.0, 2),
        (60.0, 3), (119.0, 3), (120.0, 4), (500.0, 4),
    ])
    func heatLevels(_ pages: Double, _ expected: Int) {
        // A day should be the same shade in both clients.
        #expect(WireState.heatLevel(pages) == expected)
    }

    @Test("a logged day lands on the right square with the right shade")
    func heatmapPlacesReading() {
        let state = Self.state([
            Self.book("a", finishedISO: nil, logs: [(Self.day(-3), 80)]),
        ])
        let grid = state.readingCalendar(weeks: 4, now: Self.now, calendar: Self.calendar)
        let hit = grid.flatMap { $0 }.compactMap { $0 }.first { $0.pages > 0 }

        let day = try? #require(hit)
        #expect(day?.date == Self.day(-3))
        #expect(day?.pages == 80)
        #expect(day?.level == 3)
    }
}
