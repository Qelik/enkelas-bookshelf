import Foundation

/// How fast you actually read, measured from sittings you timed.
///
/// **Why this is worth having.** Every other tracker asks you how fast you read,
/// or assumes 200 words a minute for everybody. This app owns the reader and the
/// session timer, so the number can be *measured*: a log carrying both pages and
/// minutes is a stopwatched sitting, and enough of those is a pace.
///
/// Three rules keep the number honest, and all three exist because the failure
/// they prevent is one the reader can see:
///
/// - **Median, not mean.** One log where the timer was left running turns a mean
///   into nonsense; the median shrugs it off.
/// - **Nothing is claimed without evidence.** Under `minimumSessions` timed
///   sittings there is no pace, and the UI says so rather than showing a guess
///   dressed as a measurement.
/// - **Audiobooks are excluded.** Their `pages` field holds minutes, so counting
///   them would measure one minute per minute and drag every estimate towards it.
public struct ReadingPace: Sendable, Hashable {

    /// Whose sittings the rate came from. Shown, because "your pace with this
    /// book" and "your pace generally" are different claims and only one of them
    /// is true of a 900-page history you're crawling through.
    public enum Source: Sendable, Hashable {
        case book
        case shelf
    }

    /// Pages a minute — the median of the timed sittings.
    public let pagesPerMinute: Double
    /// How many timed sittings it was measured from. Surfaced, because a pace
    /// from three sittings and one from ninety deserve different confidence.
    public let timedSessions: Int
    /// A typical sitting in minutes (median). What "you could finish this
    /// tonight" is measured against — an estimate of what you'll actually do,
    /// not of what's possible.
    public let typicalSessionMinutes: Double
    /// Pages a day recently, counting the days you didn't read. Nil when there
    /// isn't enough of a habit to project a finish date from.
    public let pagesPerDay: Double?
    /// Days in the window you read on, for the same reason `timedSessions` is here.
    public let activeDays: Int
    public let windowDays: Int
    public let source: Source

    // MARK: - Thresholds

    /// Below this there isn't enough evidence to claim a pace at all.
    public static let minimumSessions = 3
    /// A sitting under two minutes is a page glanced at, and its rate is noise.
    static let minimumSessionMinutes: Double = 2
    /// Outside this, a log is a typo or a timer left running — not a reader.
    /// 0.1 pages a minute is ten minutes a page; 4 is fifteen seconds a page.
    static let plausibleRate: ClosedRange<Double> = 0.1...4
    /// How far back the calendar habit looks.
    public static let habitWindowDays = 30
    /// Fewer active days than this in the window and "3 weeks" would be built on
    /// a single afternoon.
    static let minimumActiveDays = 3

    public init(
        pagesPerMinute: Double,
        timedSessions: Int,
        typicalSessionMinutes: Double,
        pagesPerDay: Double?,
        activeDays: Int,
        windowDays: Int,
        source: Source
    ) {
        self.pagesPerMinute = pagesPerMinute
        self.timedSessions = timedSessions
        self.typicalSessionMinutes = typicalSessionMinutes
        self.pagesPerDay = pagesPerDay
        self.activeDays = activeDays
        self.windowDays = windowDays
        self.source = source
    }

    // MARK: - Measuring

    /// The rate half: pages a minute, and what a sitting usually looks like.
    ///
    /// Separate from the habit half because they answer different questions —
    /// this one is "how long will this take me", the other is "when will I be
    /// done" — and a reader can have plenty of evidence for one and none for the
    /// other.
    static func rate(from books: [WireBook]) -> (pagesPerMinute: Double, sessions: Int, typicalMinutes: Double)? {
        var rates: [Double] = []
        var minutes: [Double] = []
        for book in books where book.format != .audio {
            for log in book.logs {
                guard log.pages > 0, log.minutes >= minimumSessionMinutes else { continue }
                let rate = log.pages / log.minutes
                guard plausibleRate.contains(rate) else { continue }
                rates.append(rate)
                minutes.append(log.minutes)
            }
        }
        guard rates.count >= minimumSessions,
              let median = rates.median,
              let typical = minutes.median
        else { return nil }
        return (median, rates.count, typical)
    }

    /// The habit half: pages a day over the recent window.
    ///
    /// Divided by elapsed calendar days rather than by the days actually read on
    /// — a finish date has to account for the evenings you don't pick the book
    /// up. The span starts at the first session *in the window* rather than at
    /// the window's edge, so somebody a week into the app isn't told they read a
    /// quarter as fast as they do.
    static func habit(
        from books: [WireBook],
        now: Date,
        calendar: Calendar,
        windowDays: Int
    ) -> (pagesPerDay: Double, activeDays: Int)? {
        let today = calendar.startOfDay(for: now)
        // `date(byAdding:)`, never `now - days * 86400`: local days aren't all
        // 86400 seconds, and past a DST change the arithmetic stops landing on
        // midnight and every day-keyed lookup misses.
        guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else { return nil }

        var perDay: [Date: Double] = [:]
        for book in books where book.format != .audio {
            for log in book.logs {
                guard log.pages > 0, let date = ISO8601.date(from: log.date) else { continue }
                let day = calendar.startOfDay(for: date)
                guard day >= windowStart, day <= today else { continue }
                perDay[day, default: 0] += log.pages
            }
        }

        guard perDay.count >= minimumActiveDays, let first = perDay.keys.min() else { return nil }
        let total = perDay.values.reduce(0, +)
        guard total > 0 else { return nil }

        let elapsed = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let span = max(1, elapsed)
        return (total / Double(span), perDay.count)
    }

    // MARK: - Using it

    public func minutes(forPages pages: Double) -> Double {
        guard pagesPerMinute > 0 else { return 0 }
        return max(0, pages) / pagesPerMinute
    }

    /// The headline number, in the unit people talk about their reading in.
    public var pagesPerHour: Int { Int((pagesPerMinute * 60).rounded()) }

    /// "40 min", "2 hr", "2 hr 40 min" — nil when there's under a minute in it
    /// and a duration would be more precision than the measurement supports.
    public static func describe(minutes: Double) -> String? {
        guard minutes.isFinite, minutes >= 1 else { return nil }
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "about 2 hr 40 min left".
    public func timeLeftDescription(pages: Double) -> String? {
        Self.describe(minutes: minutes(forPages: pages)).map { "about \($0) left" }
    }

    /// "about 9 hr" — for a book not started, where "left" would be wrong.
    public func readingTimeDescription(pages: Double) -> String? {
        Self.describe(minutes: minutes(forPages: pages)).map { "about \($0)" }
    }

    /// "about 5 days", "about 3 weeks", "about 2 months" — how long it'll take in
    /// evenings rather than in reading hours, which is the one people plan with.
    ///
    /// Rounded coarser the further out it goes: predicting "23 days" from a
    /// thirty-day window is precision the data can't support.
    public func calendarDescription(pages: Double) -> String? {
        guard let pagesPerDay, pagesPerDay > 0, pages > 0 else { return nil }
        let days = Int((pages / pagesPerDay).rounded(.up))
        // Past a decade it's noise from one slow fortnight, not a prediction.
        guard days >= 1, days <= 3650 else { return nil }
        if days == 1 { return "about a day" }
        if days < 14 { return "about \(days) days" }
        let weeks = Int((Double(days) / 7).rounded())
        if weeks <= 8 { return "about \(weeks) weeks" }
        let months = Int((Double(days) / 30.44).rounded())
        return months <= 1 ? "about a month" : "about \(months) months"
    }

    /// Whether what's left fits in a sitting of the length you usually manage.
    ///
    /// A tenth over still counts: nobody puts a book down thirty pages from the
    /// end because the arithmetic said to.
    public func fitsInOneSitting(pages: Double) -> Bool {
        guard pages > 0, typicalSessionMinutes > 0 else { return false }
        return minutes(forPages: pages) <= typicalSessionMinutes * 1.1
    }

    /// Where the number came from, in a sentence. Shown next to it, because a
    /// measured pace is only worth more than a guess if you can see it's measured.
    public var summary: String {
        let scope = source == .book ? "this book" : "your sessions"
        return "About \(pagesPerHour) pages an hour, from \(timedSessions) timed sitting\(timedSessions == 1 ? "" : "s") of \(scope)."
    }

    /// A typical sitting, phrased. Nil when it rounds to under a minute.
    public var sittingDescription: String? {
        Self.describe(minutes: typicalSessionMinutes)
    }

    /// Roughly how many words a minute a measured characters-per-minute is.
    ///
    /// 5.5 characters a word, counting the space after it — the convention
    /// reading-speed research uses, and the one that puts the reader's 1000 cpm
    /// default at the ~180 wpm it was meant to represent.
    public static func wordsPerMinute(charactersPerMinute: Double) -> Int {
        Int((charactersPerMinute / 5.5).rounded())
    }
}

// MARK: - Deriving one from a shelf

public extension WireState {

    /// Your pace across everything you've timed.
    func readingPace(
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = ReadingPace.habitWindowDays
    ) -> ReadingPace? {
        guard let rate = ReadingPace.rate(from: books) else { return nil }
        let habit = ReadingPace.habit(from: books, now: now, calendar: calendar, windowDays: windowDays)
        return ReadingPace(
            pagesPerMinute: rate.pagesPerMinute,
            timedSessions: rate.sessions,
            typicalSessionMinutes: rate.typicalMinutes,
            pagesPerDay: habit?.pagesPerDay,
            activeDays: habit?.activeDays ?? 0,
            windowDays: windowDays,
            source: .shelf
        )
    }

    /// Your pace *with this book* where there's enough of it, and your pace
    /// generally otherwise.
    ///
    /// Worth the branch: a dense history and a thriller are not read at the same
    /// speed, and once a book has a few timed sittings of its own they are the
    /// better evidence about it. The calendar habit stays shelf-wide either way —
    /// how many evenings you read is a fact about you, not about the book.
    func readingPace(
        forBookID bookID: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = ReadingPace.habitWindowDays
    ) -> ReadingPace? {
        let shelf = readingPace(now: now, calendar: calendar, windowDays: windowDays)
        guard let book = book(id: bookID), let own = ReadingPace.rate(from: [book]) else { return shelf }
        return ReadingPace(
            pagesPerMinute: own.pagesPerMinute,
            timedSessions: own.sessions,
            typicalSessionMinutes: own.typicalMinutes,
            pagesPerDay: shelf?.pagesPerDay,
            activeDays: shelf?.activeDays ?? 0,
            windowDays: windowDays,
            source: .book
        )
    }
}

extension Array where Element == Double {
    /// The middle value, averaging the two middles on an even count.
    var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
