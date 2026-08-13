import Foundation

/// Everything the Progress screen shows, derived once.
///
/// **Why this exists.** Those statistics were being read straight out of the view
/// body — `insights()`, `goalPacing()`, `readingStreak()`, `readingCalendar()`,
/// `challenges()`, `badges()`, twice over in places. Each walks every book and
/// every session log, and a SwiftUI body re-runs whenever *anything* it observes
/// changes. Measured on a 300-book shelf with 12,000 sessions, one pass was
/// ~200 ms — on the main thread, on every redraw. That was the app freezing.
///
/// Computing it here, once per change to the shelf and off the main actor, makes
/// rendering free. The individual derivations are deliberately left untouched:
/// they're the ones with golden tests proving they match the web app, and this
/// changes *when* they run, not what they produce.
public struct ProgressDigest: Sendable {
    public let pacing: GoalPacing
    public let streak: ReadingStreak
    public let insights: [String]
    public let calendar: [[HeatmapDay?]]
    public let challenges: [Challenge]
    public let badges: [Badge]
    public let totalPagesRead: Double
    public let pagesGoal: (target: Int, done: Int)?
    public let yearsWithReading: [Int]
    /// Measured reading speed, or nil while there aren't enough timed sittings
    /// to claim one. Derived here with the rest: it walks every log too.
    public let pace: ReadingPace?

    /// Cheap series for the charts, also derived once.
    public let pagesPerDay: [StatPoint]
    public let pagesPerMonth: [StatPoint]
    public let genres: [CountPoint]
    public let ratings: [CountPoint]

    /// What this was built from, so a caller can tell a stale digest from a fresh
    /// one without comparing the whole thing.
    public let sourceUpdatedAt: String

    public static func make(
        from state: WireState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProgressDigest {
        ProgressDigest(
            pacing: state.goalPacing(now: now, calendar: calendar),
            streak: state.readingStreak(now: now, calendar: calendar),
            insights: state.insights(now: now, calendar: calendar),
            calendar: state.readingCalendar(weeks: 26, now: now, calendar: calendar),
            challenges: state.challenges(now: now, calendar: calendar),
            badges: state.badges(now: now, calendar: calendar),
            totalPagesRead: state.totalPagesRead,
            pagesGoal: state.pagesGoal,
            yearsWithReading: state.yearsWithReading(calendar: calendar),
            pace: state.readingPace(now: now, calendar: calendar),
            pagesPerDay: state.dailyPages(days: 30),
            pagesPerMonth: state.monthlyPages(months: 12),
            genres: state.topGenres(),
            ratings: state.ratingSpread,
            sourceUpdatedAt: state.updatedAt
        )
    }

    /// An empty digest, for the moment before the first one has been computed.
    public static let placeholder = ProgressDigest(
        pacing: GoalPacing(target: 0, done: 0, year: 0, expectedByNow: 0, isCurrentYear: false),
        streak: .none,
        insights: [],
        calendar: [],
        challenges: [],
        badges: [],
        totalPagesRead: 0,
        pagesGoal: nil,
        yearsWithReading: [],
        pace: nil,
        pagesPerDay: [],
        pagesPerMonth: [],
        genres: [],
        ratings: [],
        sourceUpdatedAt: ""
    )
}
