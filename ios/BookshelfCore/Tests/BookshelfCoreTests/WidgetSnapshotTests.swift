import Foundation
import Testing
@testable import BookshelfCore

/// The snapshot the widgets read.
///
/// It is derived in the app and consumed in an extension that can't recompute
/// anything, so a wrong number here is a wrong number on someone's Home Screen
/// with nothing to correct it.
struct WidgetSnapshotTests {

    static let now = ISO8601.date(from: "2026-08-04T12:00:00.000Z")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    static func state(_ books: [WireBook], goal: [String: JSONValue] = [:]) -> WireState {
        var s = Normalizer(now: { now }, makeID: { "x" }).defaultState()
        s.books = books
        for (k, v) in goal { s.settings.goal[k] = v }
        return s
    }

    static func reading(
        id: String, title: String, pages: Double = 300, logs: [(Date, Double)] = []
    ) -> WireBook {
        var b = Fixture.book(id: id, status: .reading, totalPages: pages)
        b.title = title
        b.author = "An Author"
        b.logs = logs.enumerated().map { i, entry in
            WireReadingLog(id: "\(id)-l\(i)", date: ISO8601.string(from: entry.0),
                           pages: entry.1, minutes: 0, mood: "", note: "")
        }
        return b
    }

    // MARK: - Which books

    @Test("the most recently read book comes first, not the shelf's own order")
    func mostRecentFirst() {
        // A widget has room for one book, and it should be the one in their hand
        // — not whichever happens to sit at the top of the shelf.
        let state = Self.state([
            Self.reading(id: "stale", title: "Started In March", logs: [(Self.day(-90), 20)]),
            Self.reading(id: "fresh", title: "Reading Tonight", logs: [(Self.day(-1), 30)]),
            Self.reading(id: "mid", title: "Last Week", logs: [(Self.day(-6), 10)]),
        ])
        let snapshot = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar)
        #expect(snapshot.reading.map(\.id) == ["fresh", "mid", "stale"])
        #expect(snapshot.current?.title == "Reading Tonight")
    }

    @Test("a book never read sorts behind every book that has been")
    func unreadSortsLast() {
        // `.distantPast`, not `now`: a book just added with no sessions must not
        // outrank the one being read, which is exactly what a "now" default does.
        let state = Self.state([
            Self.reading(id: "never", title: "Just Added"),
            Self.reading(id: "read", title: "In Progress", logs: [(Self.day(-3), 40)]),
        ])
        let snapshot = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar)
        #expect(snapshot.reading.map(\.id) == ["read", "never"])
    }

    @Test("only currently-reading books ride along, capped")
    func onlyReadingAndCapped() {
        var books = (0..<8).map { i in
            Self.reading(id: "r\(i)", title: "Book \(i)", logs: [(Self.day(-i), 10)])
        }
        books.append(Fixture.book(id: "want", status: .want, totalPages: 100))
        books.append(Fixture.book(id: "done", status: .finished, totalPages: 100))

        let snapshot = WidgetSnapshot.make(from: Self.state(books), title: "T",
                                           now: Self.now, calendar: Self.calendar)
        #expect(snapshot.reading.count == WidgetSnapshot.readingLimit)
        #expect(!snapshot.reading.contains { $0.id == "want" || $0.id == "done" })
    }

    @Test("progress and the page numbers agree with the book")
    func progressMatchesTheBook() {
        let state = Self.state([
            Self.reading(id: "b", title: "A Book", pages: 400, logs: [(Self.day(-1), 100)]),
        ])
        let item = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar).current
        #expect(item?.currentPage == 100)
        #expect(item?.pages == 400)
        #expect(item?.progress == 0.25)
        // The same hue the app and the web version draw, so a book looks like
        // itself on the Home Screen.
        #expect(item?.hue == "A Book".stableHue)
    }

    // MARK: - Today

    @Test("read-today is about the local day, not the last 24 hours")
    func readTodayIsCalendarDay() {
        let atMidnightish = Self.calendar.date(byAdding: .minute, value: 30,
                                               to: Self.calendar.startOfDay(for: Self.now))!
        let state = Self.state([Self.reading(id: "b", title: "B", logs: [(atMidnightish, 12)])])
        let snapshot = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar)
        #expect(snapshot.readToday)
        #expect(snapshot.pagesToday == 12)

        // Yesterday evening is not today, however few hours ago it was.
        let lastNight = Self.calendar.date(byAdding: .hour, value: -14, to: Self.now)!
        let stale = Self.state([Self.reading(id: "b", title: "B", logs: [(lastNight, 12)])])
        let second = WidgetSnapshot.make(from: stale, title: "T", now: Self.now, calendar: Self.calendar)
        #expect(!second.readToday)
        #expect(second.pagesToday == 0)
    }

    @Test("today's page target spreads what's left over the days that remain")
    func dailyTargetUsesRemainingDays() {
        // Someone behind should see the number go up. A fixed yearly quota
        // divided by 365 quietly becomes unreachable and says nothing.
        let state = Self.state(
            [Self.reading(id: "b", title: "B", pages: 1000, logs: [(Self.day(-1), 300)])],
            goal: ["pagesTarget": .number(1000), "year": .number(2026)]
        )
        let snapshot = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar)
        // 4 Aug 2026 → 1 Jan 2027 is 150 days; 700 pages left over 150 days.
        #expect(snapshot.pagesTargetToday == 5)
        #expect(snapshot.pagesLeftToday == 5, "nothing read today yet")
    }

    @Test("no page goal means no daily target rather than a target of zero")
    func noPageGoalNoTarget() {
        // A widget showing "0 pages to go" when no goal exists reads as done.
        let state = Self.state([Self.reading(id: "b", title: "B")])
        let snapshot = WidgetSnapshot.make(from: state, title: "T", now: Self.now, calendar: Self.calendar)
        #expect(snapshot.pagesTargetToday == nil)
        #expect(snapshot.pagesLeftToday == nil)
    }

    @Test("a met page goal stops asking for more")
    func metPageGoalHasNoTarget() {
        let state = Self.state(
            [Self.reading(id: "b", title: "B", pages: 1000, logs: [(Self.day(-2), 1200)])],
            goal: ["pagesTarget": .number(1000), "year": .number(2026)]
        )
        #expect(WidgetSnapshot.dailyPageTarget(for: state, now: Self.now, calendar: Self.calendar) == nil)
    }

    // MARK: - Goal

    @Test("books ahead is signed the way the widget reads it")
    func booksAheadSign() {
        // Positive is ahead. Getting this backwards would congratulate someone
        // for being behind, which is worse than showing nothing.
        let behind = WidgetSnapshot(goalTarget: 24, goalDone: 5, goalExpected: 14)
        #expect(behind.booksAhead == -9)
        #expect(behind.goalRemaining == 19)

        let ahead = WidgetSnapshot(goalTarget: 24, goalDone: 20, goalExpected: 14)
        #expect(ahead.booksAhead == 6)

        // Past the target, "remaining" is zero rather than negative.
        let done = WidgetSnapshot(goalTarget: 10, goalDone: 12, goalExpected: 6)
        #expect(done.goalRemaining == 0)
    }

    // MARK: - Round trip

    @Test("a snapshot survives the trip through JSON")
    func codableRoundTrip() throws {
        // The app writes it and a different process reads it, so an encoder and
        // decoder that disagree about dates would show a widget nothing at all.
        let original = WidgetSnapshot.make(
            from: Self.state(
                [Self.reading(id: "b", title: "A Book", pages: 400, logs: [(Self.day(0), 40)])],
                goal: ["target": .number(24), "year": .number(2026)]
            ),
            title: "Çelik's Bookshelf", now: Self.now, calendar: Self.calendar
        )
        let data = try JSONEncoder.snapshot.encode(original)
        let decoded = try JSONDecoder.snapshot.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.reading == original.reading)
        #expect(decoded.title == "Çelik's Bookshelf")
        #expect(decoded.goalTarget == original.goalTarget)
        #expect(decoded.readToday == original.readToday)
        // Seconds precision through ISO8601 is all the widget needs, but the
        // date has to survive as a date rather than becoming a number.
        #expect(abs(decoded.updatedAt.timeIntervalSince(original.updatedAt)) < 1)
    }

    @Test("an empty shelf produces an empty snapshot, not a broken one")
    func emptyShelf() {
        let snapshot = WidgetSnapshot.make(from: Self.state([]), title: "T",
                                           now: Self.now, calendar: Self.calendar)
        #expect(snapshot.reading.isEmpty)
        #expect(snapshot.current == nil)
        #expect(snapshot.streakCurrent == 0)
        #expect(!snapshot.readToday)
    }
}
