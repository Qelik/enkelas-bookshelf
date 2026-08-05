import Foundation

/// A year's reading, summarised — ported from `openYearReview()` in `src/app.ts`.
///
/// Computed in Core rather than in the view because it's also what the shareable
/// card renders, and the two must agree: a card that claims a different "top
/// genre" than the screen it was made from is worse than no card.
public struct YearReview: Sendable, Hashable {
    public let year: Int
    public let booksFinished: Int
    public let pagesRead: Int
    /// Distinct days with any reading logged this year.
    public let daysReading: Int
    public let averageRating: Double?
    public let topGenre: String?
    public let busiestMonth: String?
    /// Highest-rated, most recent wins a tie.
    public let favourite: WireBook?
    public let longest: WireBook?

    /// True when there is anything worth showing. A review of a year you didn't
    /// use the app is six dashes and a lie about a "busiest month".
    public var hasData: Bool { booksFinished > 0 || pagesRead > 0 }
}

public extension WireState {

    func yearReview(_ year: Int, calendar: Calendar = .current) -> YearReview {
        let finished = booksFinished(inYear: year, calendar: calendar)
        let pages = Int(pagesRead(inYear: year, calendar: calendar))

        let daysThisYear = readingDays(calendar: calendar)
            .filter { calendar.component(.year, from: $0) == year }
            .count

        let rated = finished.compactMap { book -> (WireBook, Double)? in
            book.rating.map { (book, $0) }
        }
        let average = rated.isEmpty ? nil : rated.reduce(0) { $0 + $1.1 } / Double(rated.count)

        // Best rating first; a tie goes to whichever you finished most recently,
        // which is the one you're likelier to still be thinking about.
        let favourite = rated
            .sorted { a, b in
                a.1 == b.1
                    ? (a.0.finishedDate ?? .distantPast) > (b.0.finishedDate ?? .distantPast)
                    : a.1 > b.1
            }
            .first?.0

        let longest = finished
            .filter { $0.totalPages > 0 }
            .max { $0.totalPages < $1.totalPages }

        var genreCounts: [String: Int] = [:]
        for book in finished {
            for tag in book.tags where !tag.isEmpty { genreCounts[tag, default: 0] += 1 }
        }
        // Alphabetical on a tie, so the answer doesn't change between launches.
        let topGenre = genreCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key

        var monthCounts = [Int](repeating: 0, count: 12)
        for book in finished {
            guard let date = book.finishedDate else { continue }
            monthCounts[calendar.component(.month, from: date) - 1] += 1
        }
        let busiest: String? = {
            guard let peak = monthCounts.max(), peak > 0,
                  let index = monthCounts.firstIndex(of: peak),
                  // Format a real date rather than reading `calendar.monthSymbols`,
                  // which yields "M03" instead of "March" on a locale-less
                  // calendar. Formatting also gives the reader their own language.
                  let date = calendar.date(from: DateComponents(year: year, month: index + 1, day: 1))
            else { return nil }
            return date.formatted(.dateTime.locale(calendar.displayLocale).month(.wide))
        }()

        return YearReview(
            year: year,
            booksFinished: finished.count,
            pagesRead: pages,
            daysReading: daysThisYear,
            averageRating: average,
            topGenre: topGenre,
            busiestMonth: busiest,
            favourite: favourite,
            longest: longest
        )
    }

    /// Every year that has anything in it, newest first — so the review can only
    /// be paged to years the reader actually used.
    func yearsWithReading(calendar: Calendar = .current) -> [Int] {
        var years: Set<Int> = []
        for book in books {
            if let finished = book.finishedDate, book.status == .finished {
                years.insert(calendar.component(.year, from: finished))
            }
            for log in book.logs {
                if let date = ISO8601.date(from: log.date) {
                    years.insert(calendar.component(.year, from: date))
                }
            }
        }
        return years.sorted(by: >)
    }
}

extension Calendar {
    /// The locale to format with.
    ///
    /// `Calendar(identifier:)` carries a locale that is **non-nil but empty**, so
    /// the obvious `calendar.locale ?? .current` never falls back and every month
    /// name comes out as the root locale's "M03". Checking the identifier is what
    /// actually catches it.
    var displayLocale: Locale {
        guard let locale, !locale.identifier.isEmpty else { return .current }
        return locale
    }
}

// MARK: - Calendar heatmap

/// One square in the reading calendar.
public struct HeatmapDay: Sendable, Hashable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let pages: Double
    /// 0–4, matching the web app's five shades.
    public let level: Int
}

public extension WireState {

    /// The last `weeks` weeks as columns of seven days, Sunday-aligned.
    ///
    /// Aligned to Sunday and padded so every column is a full week — otherwise
    /// the first column starts partway down and the whole grid reads as
    /// crooked. Days after today are omitted rather than drawn empty.
    func readingCalendar(weeks: Int = 26, now: Date = Date(), calendar: Calendar = .current) -> [[HeatmapDay?]] {
        let perDay = pagesPerDay(calendar: calendar)
        let today = calendar.startOfDay(for: now)

        guard let rawStart = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: today) else { return [] }
        // Step back to the Sunday on or before the start.
        let weekday = calendar.component(.weekday, from: rawStart) - 1
        guard let start = calendar.date(byAdding: .day, value: -weekday, to: rawStart) else { return [] }

        var columns: [[HeatmapDay?]] = []
        var cursor = start
        while cursor <= today {
            var column: [HeatmapDay?] = []
            for _ in 0..<7 {
                if cursor > today {
                    column.append(nil)
                } else {
                    let pages = perDay[cursor] ?? 0
                    column.append(HeatmapDay(date: cursor, pages: pages, level: Self.heatLevel(pages)))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            columns.append(column)
        }
        return columns
    }

    /// The web app's thresholds, kept so a day looks the same shade in both.
    static func heatLevel(_ pages: Double) -> Int {
        switch pages {
        case 0: 0
        case ..<25: 1
        case ..<60: 2
        case ..<120: 3
        default: 4
        }
    }
}
