import Foundation
import Testing
@testable import BookshelfCore

/// The pace is the one number in the app that claims to be *measured* rather
/// than guessed, so every test here is about a way it could quietly stop being
/// true.
struct ReadingPaceTests {

    /// Fixed so the window arithmetic is reproducible: 20 June 2026, midday UTC.
    static let now = Date(timeIntervalSince1970: 1_781_006_400)
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func timed(_ id: String, pages: Double, minutes: Double, daysAgo: Int) -> WireReadingLog {
        let date = Self.calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return WireReadingLog(
            id: id, date: ISO8601.string(from: date),
            pages: pages, minutes: minutes, mood: "", note: ""
        )
    }

    static func shelf(_ books: [WireBook]) -> WireState {
        WireState(
            version: 1, updatedAt: ISO8601.string(from: now),
            settings: WireSettings(goal: [:]), shelfOrder: [], books: books
        )
    }

    // MARK: - Having enough to go on

    @Test("no pace is claimed from fewer than three timed sittings")
    func silentUntilThereIsEvidence() {
        // Two sittings is a coincidence. Showing "42 pages an hour" from them
        // would be a guess wearing a measurement's clothes, which is the exact
        // thing this feature exists not to be.
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 30, minutes: 30, daysAgo: 2),
            Self.timed("l2", pages: 30, minutes: 30, daysAgo: 1),
        ])
        #expect(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test("untimed sessions don't count towards a pace")
    func untimedSessionsAreNotEvidence() {
        // Pages with no minutes is the ordinary case — someone logging where they
        // got to. It says nothing about speed.
        let book = Fixture.book(logs: (1...10).map {
            Fixture.log("l\($0)", pages: 40, on: ISO8601.string(from: Self.now))
        })
        #expect(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test("a pace is measured once there are three timed sittings")
    func measuresFromThree() throws {
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 30, minutes: 30, daysAgo: 3),
            Self.timed("l2", pages: 40, minutes: 40, daysAgo: 2),
            Self.timed("l3", pages: 20, minutes: 20, daysAgo: 1),
        ])
        let pace = try #require(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar))
        #expect(pace.pagesPerMinute == 1)
        #expect(pace.pagesPerHour == 60)
        #expect(pace.timedSessions == 3)
        #expect(pace.typicalSessionMinutes == 30)
    }

    // MARK: - Staying honest

    @Test("one runaway timer doesn't move the pace")
    func medianSurvivesAnOutlier() throws {
        // The classic bad log: the timer ran all night. A mean would put this
        // reader at a third of their real speed and every estimate with it.
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 60, minutes: 60, daysAgo: 4),
            Self.timed("l2", pages: 60, minutes: 60, daysAgo: 3),
            Self.timed("l3", pages: 60, minutes: 60, daysAgo: 2),
            Self.timed("l4", pages: 60, minutes: 600, daysAgo: 1),
        ])
        let pace = try #require(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar))
        #expect(pace.pagesPerMinute == 1)
    }

    @Test("impossible rates are discarded, not averaged in")
    func implausibleSessionsAreDropped() {
        // 300 pages in three minutes is a mistyped page number, and one of them
        // sits far enough out that even a median can't be trusted to absorb it.
        // Dropping it leaves two valid sittings — under the threshold, so no
        // pace at all rather than a wrong one.
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 30, minutes: 30, daysAgo: 3),
            Self.timed("l2", pages: 30, minutes: 30, daysAgo: 2),
            Self.timed("l3", pages: 300, minutes: 3, daysAgo: 1),
        ])
        #expect(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test("audiobooks are excluded — their pages field holds minutes")
    func audiobooksCannotSetThePace() {
        // An audiobook logs 45 "pages" for 45 minutes, so counting it would
        // measure exactly one page a minute however fast anyone reads.
        var audio = Fixture.book(id: "a1", logs: [
            Self.timed("l1", pages: 45, minutes: 45, daysAgo: 3),
            Self.timed("l2", pages: 60, minutes: 60, daysAgo: 2),
            Self.timed("l3", pages: 30, minutes: 30, daysAgo: 1),
        ])
        audio.format = .audio
        #expect(Self.shelf([audio]).readingPace(now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test("a sitting under two minutes is noise, not a measurement")
    func veryShortSittingsAreIgnored() {
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 2, minutes: 1, daysAgo: 3),
            Self.timed("l2", pages: 2, minutes: 1, daysAgo: 2),
            Self.timed("l3", pages: 2, minutes: 1, daysAgo: 1),
        ])
        #expect(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar) == nil)
    }

    // MARK: - The calendar habit

    @Test("pages a day is measured from the first session, not the window edge")
    func habitDoesNotPunishANewReader() throws {
        // Someone four days into using the app read 100 pages a day for four
        // days. Dividing by the thirty-day window would tell them 13 — and then
        // that their next book takes two months.
        let book = Fixture.book(logs: (0..<4).map {
            Self.timed("l\($0)", pages: 100, minutes: 100, daysAgo: $0)
        })
        let pace = try #require(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar))
        #expect(pace.pagesPerDay == 100)
        #expect(pace.activeDays == 4)
    }

    @Test("days you didn't read still count against the daily average")
    func habitCountsTheEveningsYouSkipped() throws {
        // Three sittings spread over nine days is not "300 pages a day". A finish
        // date has to include the evenings the book stayed shut.
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 100, minutes: 100, daysAgo: 8),
            Self.timed("l2", pages: 100, minutes: 100, daysAgo: 4),
            Self.timed("l3", pages: 100, minutes: 100, daysAgo: 0),
        ])
        let pace = try #require(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar))
        #expect(pace.pagesPerDay == 300.0 / 9.0)
        #expect(pace.activeDays == 3)
    }

    @Test("a pace can exist without a habit to project it onto")
    func rateWithoutEnoughDaysStillGivesATimeButNoDate() throws {
        // Three sittings on one afternoon: enough to know how fast they read,
        // not enough to know how often. "Two hours of reading" is honest;
        // "finished by Thursday" would not be.
        let book = Fixture.book(logs: [
            Self.timed("l1", pages: 30, minutes: 30, daysAgo: 0),
            Self.timed("l2", pages: 30, minutes: 30, daysAgo: 0),
            Self.timed("l3", pages: 30, minutes: 30, daysAgo: 0),
        ])
        let pace = try #require(Self.shelf([book]).readingPace(now: Self.now, calendar: Self.calendar))
        #expect(pace.pagesPerDay == nil)
        #expect(pace.timeLeftDescription(pages: 120) == "about 2 hr left")
        #expect(pace.calendarDescription(pages: 600) == nil)
    }

    // MARK: - Per book

    @Test("a book with its own timed sittings is measured by them")
    func perBookPaceBeatsTheShelfAverage() throws {
        // A dense history read at half speed shouldn't inherit the pace of the
        // thrillers next to it — that's what makes "3 weeks" wrong by a fortnight.
        let thriller = Fixture.book(id: "fast", logs: (1...5).map {
            Self.timed("f\($0)", pages: 60, minutes: 60, daysAgo: $0)
        })
        let history = Fixture.book(id: "slow", logs: (1...5).map {
            Self.timed("s\($0)", pages: 15, minutes: 60, daysAgo: $0)
        })
        let state = Self.shelf([thriller, history])

        let own = try #require(state.readingPace(forBookID: "slow", now: Self.now, calendar: Self.calendar))
        #expect(own.source == .book)
        #expect(own.pagesPerMinute == 0.25)

        // …but the calendar habit stays shelf-wide: how many evenings you read is
        // a fact about you, not about the book.
        let shelf = try #require(state.readingPace(now: Self.now, calendar: Self.calendar))
        #expect(own.pagesPerDay == shelf.pagesPerDay)
    }

    @Test("a book with too little of its own history falls back to the shelf")
    func perBookFallsBack() throws {
        let known = Fixture.book(id: "known", logs: (1...5).map {
            Self.timed("k\($0)", pages: 60, minutes: 60, daysAgo: $0)
        })
        let fresh = Fixture.book(id: "fresh", logs: [Self.timed("n1", pages: 10, minutes: 40, daysAgo: 1)])
        let pace = try #require(
            Self.shelf([known, fresh]).readingPace(forBookID: "fresh", now: Self.now, calendar: Self.calendar)
        )
        #expect(pace.source == .shelf)
        #expect(pace.pagesPerMinute == 1)
    }

    // MARK: - Phrasing

    @Test("durations read the way people say them")
    func durationWording() {
        #expect(ReadingPace.describe(minutes: 0.4) == nil)
        #expect(ReadingPace.describe(minutes: 19) == "19 min")
        #expect(ReadingPace.describe(minutes: 60) == "1 hr")
        #expect(ReadingPace.describe(minutes: 125) == "2 hr 5 min")
    }

    @Test("calendar estimates get vaguer the further out they go")
    func calendarWording() {
        // Precision the data can't support reads as a promise. A thirty-day
        // window cannot honestly say "23 days".
        let pace = ReadingPace(
            pagesPerMinute: 1, timedSessions: 10, typicalSessionMinutes: 45,
            pagesPerDay: 30, activeDays: 20, windowDays: 30, source: .shelf
        )
        #expect(pace.calendarDescription(pages: 30) == "about a day")
        #expect(pace.calendarDescription(pages: 150) == "about 5 days")
        #expect(pace.calendarDescription(pages: 600) == "about 3 weeks")
        #expect(pace.calendarDescription(pages: 2000) == "about 2 months")
        #expect(pace.calendarDescription(pages: 0) == nil)
    }

    @Test("finishing tonight means it fits a sitting you actually manage")
    func oneSitting() {
        // Measured against a typical sitting, not against "an evening" — the
        // claim is about what this reader does, which is the only version of it
        // that turns out to be true.
        let pace = ReadingPace(
            pagesPerMinute: 1, timedSessions: 10, typicalSessionMinutes: 45,
            pagesPerDay: 30, activeDays: 20, windowDays: 30, source: .shelf
        )
        #expect(pace.fitsInOneSitting(pages: 40))
        #expect(pace.fitsInOneSitting(pages: 49))       // the last few pages count
        #expect(!pace.fitsInOneSitting(pages: 120))
        #expect(!pace.fitsInOneSitting(pages: 0))
    }

    @Test("the reader's characters a minute becomes a words-a-minute anyone recognises")
    func wordsPerMinute() {
        // The reader learns characters because that's what it can count. Nobody
        // describes their reading speed that way.
        #expect(ReadingPace.wordsPerMinute(charactersPerMinute: 1000) == 182)
        #expect(ReadingPace.wordsPerMinute(charactersPerMinute: 1650) == 300)
    }
}
