import Foundation
import Testing
@testable import BookshelfCore

/// Badges, challenges, streaks and goal pacing.
///
/// These are claims about someone's reading shown on both clients. A badge the
/// phone grants and the browser doesn't reads as one of them lying, so the
/// thresholds here are the web app's, transcribed.
struct AchievementsTests {

    /// Fixed "now" so a test written in August still passes in December.
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

    static func book(
        id: String = "b", status: BookStatus = .finished, pages: Double = 300,
        finished: Date? = nil, started: Date? = nil, rating: Double? = nil,
        tags: [String] = [], review: String = "", published: Double? = nil,
        owned: Bool = false, logs: [(Date, Double)] = []
    ) -> WireBook {
        var b = Fixture.book(id: id, status: status, totalPages: pages)
        b.finishedAt = finished.map(ISO8601.string(from:))
        b.startedAt = started.map(ISO8601.string(from:))
        b.rating = rating
        b.tags = tags
        b.review = review
        b.publishedYear = published
        b.owned = owned
        b.logs = logs.enumerated().map { i, entry in
            WireReadingLog(id: "\(id)-l\(i)", date: ISO8601.string(from: entry.0),
                           pages: entry.1, minutes: 0, mood: "", note: "")
        }
        return b
    }

    // MARK: - Streaks

    @Test("a streak counts consecutive days, and today or yesterday keeps it alive")
    func streakBasics() {
        let cal = Self.calendar
        // Read on each of the last three days.
        let days: Set<Date> = [Self.day(0), Self.day(-1), Self.day(-2)]
        let streak = WireState.streak(from: days, now: Self.now, calendar: cal)
        #expect(streak.current == 3)
        #expect(streak.longest == 3)
    }

    @Test("not having read yet today doesn't break the streak")
    func yesterdayKeepsItAlive() {
        // At 9am someone who read every day up to last night has not broken
        // anything, and telling them otherwise is the fastest way to lose them.
        let days: Set<Date> = [Self.day(-1), Self.day(-2), Self.day(-3)]
        let streak = WireState.streak(from: days, now: Self.now, calendar: Self.calendar)
        #expect(streak.current == 3)
    }

    @Test("a gap ends the current streak but not the longest")
    func gapEndsCurrent() {
        // Five days in a row a while back, nothing since.
        let days = Set((5...9).map { Self.day(-$0) })
        let streak = WireState.streak(from: days, now: Self.now, calendar: Self.calendar)
        #expect(streak.current == 0)
        #expect(streak.longest == 5, "a streak that ended was still earned")
    }

    @Test("an empty shelf has no streak")
    func emptyStreak() {
        #expect(WireState.streak(from: [], now: Self.now, calendar: Self.calendar) == .none)
    }

    @Test("reading days are bucketed in local time, not UTC")
    func localDayBuckets() {
        // A session at 11pm belongs to that evening. Bucketing by UTC would move
        // half of everyone's late-night reading onto the next day and silently
        // break streaks for anyone west of Greenwich.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let lateNight = ISO8601.date(from: "2026-08-04T03:30:00.000Z")!   // 11:30pm on the 3rd in New York
        let state = Self.state([Self.book(status: .reading, logs: [(lateNight, 40)])])

        let days = state.readingDays(calendar: cal)
        let expected = cal.startOfDay(for: lateNight)
        #expect(days == [expected])
        #expect(cal.component(.day, from: expected) == 3)
    }

    // MARK: - Badges

    @Test("page and book milestones unlock at the web app's thresholds")
    func milestoneThresholds() {
        let state = Self.state([
            Self.book(id: "a", finished: Self.day(-5), logs: [(Self.day(-5), 250)]),
            Self.book(id: "b", finished: Self.day(-4), logs: [(Self.day(-4), 260)]),
        ])
        let badges = state.badges(now: Self.now, calendar: Self.calendar)
        func badge(_ id: String) -> Badge? { badges.first { $0.id == id } }

        // 510 pages, 2 books finished.
        #expect(badge("pages-500")?.unlocked == true)
        #expect(badge("pages-1000")?.unlocked == false)
        #expect(badge("books-1")?.unlocked == true)
        #expect(badge("books-5")?.unlocked == false)
    }

    @Test("the goal badge stays locked when no goal is set")
    func goalBadgeNeedsAGoal() {
        // A target of zero is "no goal", not "a goal of nothing" — unlocking it
        // on day one for everybody would make the badge meaningless.
        let state = Self.state([Self.book(finished: Self.now)], goal: ["target": .number(0)])
        let badges = state.badges(now: Self.now, calendar: Self.calendar)
        #expect(badges.first { $0.id.hasPrefix("goal-") }?.unlocked == false)
    }

    @Test("the goal badge unlocks on hitting the target")
    func goalBadgeUnlocks() {
        let books = (1...3).map { Self.book(id: "b\($0)", finished: Self.now) }
        let state = Self.state(books, goal: ["target": .number(3), "year": .number(2026)])
        let badges = state.badges(now: Self.now, calendar: Self.calendar)
        #expect(badges.first { $0.id == "goal-2026" }?.unlocked == true)
    }

    @Test("streak badges use the longest run, not the current one")
    func streakBadgesUseLongest() {
        // Earned is earned: losing today's streak shouldn't take the badge away.
        let logs = (5...11).map { (Self.day(-$0), 20.0) }
        let state = Self.state([Self.book(status: .reading, logs: logs)])
        let badges = state.badges(now: Self.now, calendar: Self.calendar)

        #expect(state.readingStreak(now: Self.now, calendar: Self.calendar).current == 0)
        #expect(badges.first { $0.id == "streak-7" }?.unlocked == true)
        #expect(badges.first { $0.id == "streak-30" }?.unlocked == false)
    }

    @Test("the critic badge needs an actual rating")
    func criticBadge() {
        let unrated = Self.state([Self.book(rating: nil)])
        #expect(unrated.badges(now: Self.now, calendar: Self.calendar).first { $0.id == "first-rating" }?.unlocked == false)
        let rated = Self.state([Self.book(rating: 4)])
        #expect(rated.badges(now: Self.now, calendar: Self.calendar).first { $0.id == "first-rating" }?.unlocked == true)
    }

    // MARK: - Challenges

    @Test("challenges match the web app's rules")
    func challengeRules() {
        let state = Self.state([
            Self.book(id: "a", pages: 620, finished: Self.now, rating: 5,
                      tags: ["Fantasy", "Adventure"], review: "Loved it", published: 1998),
            Self.book(id: "b", pages: 200, finished: Self.now,
                      started: Self.calendar.date(byAdding: .day, value: -3, to: Self.now),
                      tags: ["Classics"], published: 1965),
            Self.book(id: "c", pages: 300, finished: Self.now, tags: ["Horror"], published: 2021),
        ], goal: ["year": .number(2026)])

        let challenges = state.challenges(now: Self.now, calendar: Self.calendar)
        func challenge(_ id: String) -> Challenge? { challenges.first { $0.id == id } }

        #expect(challenge("genres5")?.value == 4)          // four distinct tags
        #expect(challenge("genres5")?.unlocked == false)
        #expect(challenge("chunky")?.unlocked == true)     // the 620-page one
        #expect(challenge("decades3")?.value == 3)         // 1990s, 1960s, 2020s
        #expect(challenge("decades3")?.unlocked == true)
        #expect(challenge("reviews5")?.value == 1)
        #expect(challenge("fivestar")?.unlocked == true)
        #expect(challenge("speed")?.unlocked == true)      // finished 3 days after starting
    }

    @Test("the every-month challenge only asks for the months that have happened")
    func everyMonthIsProRated() {
        // In August, "a book each month" means eight — not twelve. Otherwise the
        // challenge reads as failed all year.
        let state = Self.state([Self.book(finished: Self.now)], goal: ["year": .number(2026)])
        let months = state.challenges(now: Self.now, calendar: Self.calendar).first { $0.id == "months" }
        #expect(months?.target == 8)

        // A past year is judged on the full twelve.
        let past = Self.state([Self.book(finished: Self.now)], goal: ["year": .number(2025)])
        let pastMonths = past.challenges(now: Self.now, calendar: Self.calendar).first { $0.id == "months" }
        #expect(pastMonths?.target == 12)
    }

    // MARK: - Goal pacing

    @Test("pacing says whether you're ahead or behind, not just the count")
    func goalPacing() {
        // 4 August is a little over 59% through the year. A target of 12 means
        // roughly 7 by now.
        let onTrack = Self.state(
            (1...7).map { Self.book(id: "b\($0)", finished: Self.now) },
            goal: ["target": .number(12), "year": .number(2026)]
        ).goalPacing(now: Self.now, calendar: Self.calendar)
        #expect(onTrack.expectedByNow > 6.5 && onTrack.expectedByNow < 7.5)
        #expect(onTrack.pacingDescription?.contains("on pace") == true)

        let behind = Self.state(
            [Self.book(finished: Self.now)],
            goal: ["target": .number(12), "year": .number(2026)]
        ).goalPacing(now: Self.now, calendar: Self.calendar)
        #expect(behind.pacingDescription?.contains("behind") == true)

        let ahead = Self.state(
            (1...11).map { Self.book(id: "b\($0)", finished: Self.now) },
            goal: ["target": .number(12), "year": .number(2026)]
        ).goalPacing(now: Self.now, calendar: Self.calendar)
        #expect(ahead.pacingDescription?.contains("ahead") == true)
    }

    @Test("a met goal is celebrated rather than counted down")
    func goalComplete() {
        let pacing = Self.state(
            (1...5).map { Self.book(id: "b\($0)", finished: Self.now) },
            goal: ["target": .number(5), "year": .number(2026)]
        ).goalPacing(now: Self.now, calendar: Self.calendar)
        #expect(pacing.isComplete)
        #expect(pacing.pacingDescription?.contains("smashed") == true)
        #expect(pacing.remaining == 0)
    }

    @Test("no goal set means no pacing sentence at all")
    func noGoalNoSentence() {
        // Better nothing than "0 to go".
        let pacing = Self.state([], goal: ["target": .number(0)])
            .goalPacing(now: Self.now, calendar: Self.calendar)
        #expect(pacing.pacingDescription == nil)
    }

    // MARK: - Charts

    @Test("the daily chart includes days with no reading")
    func dailyIncludesEmptyDays() {
        // A bar chart with the empty days missing makes a quiet fortnight look
        // like a busy one.
        let state = Self.state([Self.book(status: .reading, logs: [(Self.day(-2), 40)])])
        let points = state.dailyPages(days: 30, now: Self.now, calendar: Self.calendar)
        #expect(points.count == 30)
        #expect(points.filter { $0.value > 0 }.count == 1)
        #expect(points.last?.date == Self.calendar.startOfDay(for: Self.now))
    }

    @Test("the monthly chart covers twelve months ending with this one")
    func monthlyWindow() {
        let state = Self.state([Self.book(status: .reading, logs: [(Self.now, 120)])])
        let points = state.monthlyPages(months: 12, now: Self.now, calendar: Self.calendar)
        #expect(points.count == 12)
        #expect(points.last?.value == 120)
    }

    @Test("ratings round to the nearest star so halves aren't lost")
    func ratingSpreadRounds() {
        let state = Self.state([
            Self.book(id: "a", rating: 4.5),
            Self.book(id: "b", rating: 4),
            Self.book(id: "c", rating: nil),
        ])
        let spread = state.ratingSpread
        #expect(spread.count == 5)
        // 4.5 rounds up to 5; the unrated book counts nowhere.
        #expect(spread[4].value == 1)
        #expect(spread[3].value == 1)
        #expect(spread.reduce(0) { $0 + $1.value } == 2)
    }

    @Test("genre counts are ordered, capped and stable")
    func genreOrdering() {
        let state = Self.state([
            Self.book(id: "a", tags: ["Fantasy", "Horror"]),
            Self.book(id: "b", tags: ["Fantasy"]),
            Self.book(id: "c", tags: ["Classics"]),
        ])
        let genres = state.topGenres(limit: 8)
        #expect(genres.first?.label == "Fantasy")
        #expect(genres.first?.value == 2)
        // Ties break alphabetically, so the order doesn't shuffle between launches.
        #expect(genres.map(\.label) == ["Fantasy", "Classics", "Horror"])
    }

    @Test("insights only speak when they have something to say")
    func insightsAreQuietWhenEmpty() {
        // A card reading "0 books this month" is noise.
        #expect(Self.state([]).insights(now: Self.now, calendar: Self.calendar).isEmpty)

        let busy = Self.state([
            Self.book(id: "a", pages: 700, finished: Self.now, rating: 5, tags: ["Fantasy"], logs: [(Self.day(0), 100)]),
            Self.book(id: "b", finished: Self.now, rating: 4, tags: ["Fantasy"]),
            Self.book(id: "c", finished: Self.now, rating: 3, tags: ["Fantasy"]),
        ])
        let lines = busy.insights(now: Self.now, calendar: Self.calendar)
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.contains("Fantasy") })
        #expect(lines.contains { $0.contains("700 pages") })
    }
}
