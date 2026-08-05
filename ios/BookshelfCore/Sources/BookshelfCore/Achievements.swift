import Foundation

/// Badges, challenges and streaks, ported from `computeBadges()`,
/// `computeChallenges()` and `streakFromDays()` in `src/app.ts`.
///
/// These are user-visible claims about someone's reading. A badge the phone
/// grants and the browser doesn't — or a streak that disagrees by a day — reads
/// as one of the two lying, so the thresholds and the day maths are transcribed
/// rather than reinvented.

public struct Badge: Sendable, Identifiable, Hashable {
    public enum Group: String, Sendable, CaseIterable {
        case pages, books, special
        public var label: String {
            switch self {
            case .pages: "Pages read"
            case .books: "Books finished"
            case .special: "Milestones"
            }
        }
    }

    public let id: String
    public let group: Group
    public let emoji: String
    public let title: String
    public let detail: String
    public let value: Int
    public let target: Int

    public var unlocked: Bool { value >= target }
    public var progress: Double { target > 0 ? min(1, Double(value) / Double(target)) : 0 }
}

public struct Challenge: Sendable, Identifiable, Hashable {
    public let id: String
    public let emoji: String
    public let title: String
    public let detail: String
    public let value: Int
    public let target: Int

    public var unlocked: Bool { value >= target }
    public var progress: Double { target > 0 ? min(1, Double(value) / Double(target)) : 0 }
}

public struct ReadingStreak: Sendable, Hashable {
    public let current: Int
    public let longest: Int
    public static let none = ReadingStreak(current: 0, longest: 0)
}

public extension WireState {

    // MARK: - Days and streaks

    /// Every distinct day something was read, at local midnight.
    ///
    /// Local, not UTC: a session logged at 11pm belongs to that evening, and
    /// bucketing by UTC would move half of everyone's late-night reading onto
    /// the next day and break their streak.
    func readingDays(calendar: Calendar = .current) -> Set<Date> {
        var days: Set<Date> = []
        for book in books {
            for log in book.logs {
                guard let date = ISO8601.date(from: log.date) else { continue }
                days.insert(calendar.startOfDay(for: date))
            }
        }
        return days
    }

    /// Pages read per day.
    func pagesPerDay(calendar: Calendar = .current) -> [Date: Double] {
        var map: [Date: Double] = [:]
        for book in books {
            for log in book.logs {
                guard let date = ISO8601.date(from: log.date) else { continue }
                map[calendar.startOfDay(for: date), default: 0] += log.pages
            }
        }
        return map
    }

    func readingStreak(now: Date = Date(), calendar: Calendar = .current) -> ReadingStreak {
        Self.streak(from: readingDays(calendar: calendar), now: now, calendar: calendar)
    }

    /// Split out so the day maths can be tested without building a shelf.
    static func streak(from days: Set<Date>, now: Date = Date(), calendar: Calendar = .current) -> ReadingStreak {
        guard !days.isEmpty else { return .none }
        let sorted = days.sorted()

        var longest = 1
        var run = 1
        for i in 1..<max(1, sorted.count) {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               calendar.isDate(next, inSameDayAs: sorted[i]) {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        // Today *or* yesterday keeps a streak alive: someone who hasn't read yet
        // today at 9am has not broken anything.
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var current = 0
        var cursor: Date?
        if days.contains(today) { cursor = today }
        else if days.contains(yesterday) { cursor = yesterday }
        while let c = cursor, days.contains(c) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: c)
        }
        return ReadingStreak(current: current, longest: longest)
    }

    // MARK: - Year totals

    func booksFinished(inYear year: Int, calendar: Calendar = .current) -> [WireBook] {
        books.filter { book in
            book.status == .finished
                && book.finishedDate.map { calendar.component(.year, from: $0) == year } == true
        }
    }

    func pagesRead(inYear year: Int, calendar: Calendar = .current) -> Double {
        books.reduce(0) { total, book in
            total + book.logs.reduce(0) { sum, log in
                guard let date = ISO8601.date(from: log.date),
                      calendar.component(.year, from: date) == year
                else { return sum }
                return sum + log.pages
            }
        }
    }

    // MARK: - Badges

    static let pageMilestones: [(n: Int, emoji: String, title: String, detail: String)] = [
        (100, "🌱", "First Chapter", "100 pages read"),
        (200, "📖", "Page Turner", "200 pages read"),
        (500, "🔖", "Bookmark Worthy", "500 pages read"),
        (1000, "📚", "Avid Reader", "1,000 pages read"),
        (2500, "🦉", "Night Owl", "2,500 pages read"),
        (5000, "🏛️", "Scholar", "5,000 pages read"),
        (10000, "🐉", "Page Dragon", "10,000 pages read"),
        (25000, "🌌", "Lost in Worlds", "25,000 pages read"),
        (50000, "👑", "Reading Royalty", "50,000 pages read"),
    ]

    static let bookMilestones: [(n: Int, emoji: String, title: String, detail: String)] = [
        (1, "🎉", "First Book", "Finished your 1st book"),
        (5, "⭐", "High Five", "Finished 5 books"),
        (10, "🏅", "Bookworm", "Finished 10 books"),
        (25, "🎖️", "Bibliophile", "Finished 25 books"),
        (50, "🏆", "Shelf Master", "Finished 50 books"),
        (100, "💎", "Centurion", "Finished 100 books"),
    ]

    func badges(now: Date = Date(), calendar: Calendar = .current) -> [Badge] {
        let totalPages = Int(totalPagesRead)
        let finished = books.filter { $0.status == .finished }.count
        let goalYear = settings.goalYear ?? calendar.component(.year, from: now)
        let goalTarget = settings.goalTarget ?? 0
        let finishedThisYear = booksFinished(inYear: goalYear, calendar: calendar).count
        let streak = readingStreak(now: now, calendar: calendar)

        var list: [Badge] = []
        for m in Self.pageMilestones {
            list.append(Badge(id: "pages-\(m.n)", group: .pages, emoji: m.emoji, title: m.title,
                              detail: m.detail, value: totalPages, target: m.n))
        }
        for m in Self.bookMilestones {
            list.append(Badge(id: "books-\(m.n)", group: .books, emoji: m.emoji, title: m.title,
                              detail: m.detail, value: finished, target: m.n))
        }
        list.append(Badge(
            id: "goal-\(goalYear)", group: .special, emoji: "🎯", title: "Goal Crusher",
            detail: "Hit your \(goalYear) reading goal",
            value: finishedThisYear,
            // A target of zero would otherwise unlock on day one for anyone who
            // hasn't set a goal.
            target: goalTarget > 0 ? goalTarget : Int.max
        ))
        let hasRating = books.contains { $0.rating != nil }
        list.append(Badge(id: "first-rating", group: .special, emoji: "🌟", title: "Critic",
                          detail: "Rated your first book", value: hasRating ? 1 : 0, target: 1))

        // Streak badges measure the *longest* run, not the current one — losing
        // a streak shouldn't take a badge away that was genuinely earned.
        for s in [(3, "🔥", "On a Roll"), (7, "📅", "Weekly Habit"), (30, "🚀", "Unstoppable")] {
            list.append(Badge(id: "streak-\(s.0)", group: .special, emoji: s.1, title: s.2,
                              detail: "\(s.0)-day reading streak", value: streak.longest, target: s.0))
        }
        return list
    }

    // MARK: - Challenges

    func challenges(now: Date = Date(), calendar: Calendar = .current) -> [Challenge] {
        let year = settings.goalYear ?? calendar.component(.year, from: now)
        let finishedThisYear = booksFinished(inYear: year, calendar: calendar)

        let genres = Set(finishedThisYear.flatMap { $0.tags.map { $0.lowercased() } })
        let chunky = books.contains { $0.status == .finished && $0.totalPages >= 500 }
        let decades = Set(books.compactMap { book -> Int? in
            guard book.status == .finished, let year = book.publishedYear else { return nil }
            return Int(year / 10)
        })
        let reviews = books.filter {
            $0.status == .finished && !$0.review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let months = Set(finishedThisYear.compactMap { $0.finishedDate.map { calendar.component(.month, from: $0) } })
        let fiveStar = books.contains { $0.status == .finished && $0.rating == 5 }
        let speedy = books.contains { book in
            guard book.status == .finished,
                  let started = book.startedDate, let finished = book.finishedDate
            else { return false }
            let days = finished.timeIntervalSince(started) / 86400
            return days >= 0 && days <= 7
        }

        // Part-way through a year, "a book every month" means every month *so
        // far* — otherwise the challenge reads as failed until December.
        let isCurrentYear = calendar.component(.year, from: now) == year
        let monthTarget = isCurrentYear ? calendar.component(.month, from: now) : 12

        return [
            Challenge(id: "genres5", emoji: "🌈", title: "Well-Rounded",
                      detail: "Read 5 genres in \(year)", value: genres.count, target: 5),
            Challenge(id: "chunky", emoji: "🧱", title: "Chunky Read",
                      detail: "Finish a 500+ page book", value: chunky ? 1 : 0, target: 1),
            Challenge(id: "decades3", emoji: "🕰️", title: "Time Traveler",
                      detail: "Books from 3 decades", value: decades.count, target: 3),
            Challenge(id: "reviews5", emoji: "✍️", title: "The Reviewer",
                      detail: "Write 5 reviews", value: reviews, target: 5),
            Challenge(id: "months", emoji: "📆", title: "Every Month",
                      detail: "A book each month of \(year)", value: months.count, target: monthTarget),
            Challenge(id: "fivestar", emoji: "💯", title: "Instant Classic",
                      detail: "Give a 5-star rating", value: fiveStar ? 1 : 0, target: 1),
            Challenge(id: "speed", emoji: "⚡", title: "Speed Reader",
                      detail: "Finish a book in ≤7 days", value: speedy ? 1 : 0, target: 1),
        ]
    }
}
