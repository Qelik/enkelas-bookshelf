import Foundation

/// Chart data and goal pacing.
///
/// Everything here is derived on demand. The web app memoises it behind an epoch
/// cache because it recomputes on every full re-render; SwiftUI only recomputes
/// what changed, so a second source of truth would be a liability rather than a
/// saving.
public struct StatPoint: Sendable, Identifiable, Hashable {
    public var id: Date { date }
    public let date: Date
    public let value: Double
}

public struct CountPoint: Sendable, Identifiable, Hashable {
    public var id: String { label }
    public let label: String
    public let value: Int
}

/// How a yearly goal is tracking, and whether that's ahead or behind.
public struct GoalPacing: Sendable, Hashable {
    public let target: Int
    public let done: Int
    public let year: Int
    /// Where you'd be on this date to finish exactly on 31 December.
    public let expectedByNow: Double
    public let isCurrentYear: Bool

    public var progress: Double { target > 0 ? min(1, Double(done) / Double(target)) : 0 }
    public var remaining: Int { max(0, target - done) }
    public var isComplete: Bool { target > 0 && done >= target }
    public var booksAhead: Double { Double(done) - expectedByNow }

    /// One line for the goal card. Nil when there's no goal set — an empty
    /// string would leave a gap where a sentence should be.
    public var pacingDescription: String? {
        guard target > 0 else { return nil }
        if isComplete { return "Goal smashed — \(done) book\(done == 1 ? "" : "s") in \(year)." }
        guard isCurrentYear else { return "\(done) of \(target) in \(year)." }
        let diff = booksAhead
        if diff >= 1 { return "\(remaining) to go — you're \(Int(diff)) ahead of schedule." }
        if diff <= -1 { return "\(remaining) to go — \(Int(-diff)) behind schedule." }
        return "\(remaining) to go — right on pace."
    }
}

public extension WireState {

    // MARK: - Goal

    func goalPacing(now: Date = Date(), calendar: Calendar = .current) -> GoalPacing {
        let year = settings.goalYear ?? calendar.component(.year, from: now)
        let target = settings.goalTarget ?? 0
        let done = booksFinished(inYear: year, calendar: calendar).count
        let isCurrentYear = calendar.component(.year, from: now) == year

        // Fraction of the year elapsed, computed from real day counts so leap
        // years and partial days don't skew it.
        var expected = Double(target)
        if isCurrentYear,
           let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let startOfNext = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
            let total = startOfNext.timeIntervalSince(startOfYear)
            let elapsed = now.timeIntervalSince(startOfYear)
            expected = Double(target) * max(0, min(1, elapsed / total))
        }

        return GoalPacing(
            target: target, done: done, year: year,
            expectedByNow: expected, isCurrentYear: isCurrentYear
        )
    }

    var pagesGoal: (target: Int, done: Int)? {
        guard let target = settings.goalPagesTarget, target > 0 else { return nil }
        let year = settings.goalYear ?? Calendar.current.component(.year, from: Date())
        return (target, Int(pagesRead(inYear: year)))
    }

    /// Pages read today against the daily goal, if one is set.
    func dailyGoal(now: Date = Date(), calendar: Calendar = .current) -> (target: Int, done: Int)? {
        guard let target = settings.goalDailyPages, target > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        return (target, Int(pagesPerDay(calendar: calendar)[today] ?? 0))
    }

    // MARK: - Charts

    /// Pages per day for the last `days` days, including days with none — a bar
    /// chart with the empty days missing makes a gap look like a busy week.
    func dailyPages(days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [StatPoint] {
        let perDay = pagesPerDay(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return StatPoint(date: date, value: perDay[date] ?? 0)
        }
    }

    /// Pages per month for the last twelve months.
    func monthlyPages(months: Int = 12, now: Date = Date(), calendar: Calendar = .current) -> [StatPoint] {
        var buckets: [Date: Double] = [:]
        var order: [Date] = []
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        for back in (0..<months).reversed() {
            guard let date = calendar.date(byAdding: .month, value: -back, to: thisMonth) else { continue }
            buckets[date] = 0
            order.append(date)
        }
        for book in books {
            for log in book.logs {
                guard let date = ISO8601.date(from: log.date),
                      let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
                      buckets[month] != nil
                else { continue }
                buckets[month, default: 0] += log.pages
            }
        }
        return order.map { StatPoint(date: $0, value: buckets[$0] ?? 0) }
    }

    /// The eight most-used tags. More than that and the labels stop being
    /// readable on a phone.
    func topGenres(limit: Int = 8) -> [CountPoint] {
        var counts: [String: Int] = [:]
        for book in books {
            for tag in book.tags where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        // Broken into steps: as one chain the type checker gives up on it.
        let points = counts.map { CountPoint(label: $0.key, value: $0.value) }
        let sorted = points.sorted { a, b in
            // Alphabetical within a tie, so the order doesn't shuffle between
            // launches for tags used the same number of times.
            a.value == b.value ? a.label < b.label : a.value > b.value
        }
        return Array(sorted.prefix(limit))
    }

    /// How many books at each star rating. Halves round to the nearest star, so
    /// a 4.5 counts once rather than falling between the bars.
    var ratingSpread: [CountPoint] {
        var counts = [0, 0, 0, 0, 0]
        for book in books {
            guard let rating = book.rating else { continue }
            let star = Int(rating.rounded())
            if (1...5).contains(star) { counts[star - 1] += 1 }
        }
        return counts.enumerated().map { CountPoint(label: "\($0.offset + 1)★", value: $0.element) }
    }

    // MARK: - Insight lines

    /// A few plain sentences about the shelf. Only ones with something to say
    /// are returned — a card reading "0 books this month" is noise.
    func insights(now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var out: [String] = []
        let streak = readingStreak(now: now, calendar: calendar)
        if streak.current >= 2 {
            out.append("You've read \(streak.current) days in a row.")
        } else if streak.longest >= 3 {
            out.append("Your longest streak is \(streak.longest) days.")
        }

        let year = calendar.component(.year, from: now)
        let finishedThisYear = booksFinished(inYear: year, calendar: calendar)
        if !finishedThisYear.isEmpty {
            let pages = Int(pagesRead(inYear: year, calendar: calendar))
            out.append("\(finishedThisYear.count) book\(finishedThisYear.count == 1 ? "" : "s") and \(pages.formatted()) pages so far in \(year).")
        }

        if let longest = finishedThisYear.max(by: { $0.totalPages < $1.totalPages }), longest.totalPages > 0 {
            out.append("Your longest finish this year was “\(longest.title)” at \(Int(longest.totalPages)) pages.")
        }

        let rated = books.compactMap(\.rating)
        if rated.count >= 3 {
            let average = rated.reduce(0, +) / Double(rated.count)
            out.append("You rate books \(JS.numberToString((average * 10).rounded() / 10))★ on average.")
        }

        if let favourite = topGenres(limit: 1).first, favourite.value >= 3 {
            out.append("\(favourite.label) is your most-read genre (\(favourite.value) books).")
        }

        let unreadOwned = books.filter { $0.owned && $0.status == .want }
        if unreadOwned.count >= 3 {
            out.append("\(unreadOwned.count) books you own are still unread.")
        }

        return out
    }
}
