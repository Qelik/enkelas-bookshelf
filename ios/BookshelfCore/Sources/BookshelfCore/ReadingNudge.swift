import Foundation

/// The daily nudge to pick your book back up.
///
/// Written around one rule: **only say things that are true.** It is tempting to
/// write "it's just getting good" — but the app has never read the book and
/// doesn't know. What it does know is real and quite enough to be warm about:
/// how far in you are, how many pages are left, how long the book has sat there,
/// and whether a streak is on the line. The playfulness goes in the framing, not
/// in invented facts about the plot.
public struct ReadingNudge: Sendable, Equatable {
    public let title: String
    public let body: String
    /// The book this is about, so tapping the notification opens it.
    public let bookID: String?

    public init(title: String, body: String, bookID: String?) {
        self.title = title
        self.body = body
        self.bookID = bookID
    }
}

public enum ReadingNudges {

    /// A nudge for `day`.
    ///
    /// Deterministic: the same shelf and the same day always produce the same
    /// message. Notifications are scheduled days ahead and re-armed whenever the
    /// app opens, so a random pick would rewrite tomorrow's message every launch
    /// — and a user who opened the app twice would get a different promise about
    /// the same evening.
    public static func nudge(
        for state: WireState,
        on day: Date,
        calendar: Calendar = .current
    ) -> ReadingNudge {
        guard let book = currentBook(in: state, by: day, calendar: calendar) else {
            return generic(for: state, on: day, calendar: calendar)
        }

        let title = book.title
        let daysAway = daysSinceLastRead(book, before: day, calendar: calendar)
        let percent = Int((book.progress ?? 0) * 100)
        let pagesLeft = Int(book.pagesRemaining)
        let knowsLength = book.totalPages > 0
        let streak = state.readingStreak(now: day, calendar: calendar)
        let readToday = (state.pagesPerDay(calendar: calendar)[calendar.startOfDay(for: day)] ?? 0) > 0

        // Ordered by how much the situation deserves saying. A book three pages
        // from the end beats a generic "keep going" every time.
        if readToday {
            return pick(alreadyRead(title: title, streak: streak.current), book: book, day: day, calendar: calendar)
        }
        if knowsLength, pagesLeft > 0, pagesLeft <= 40 {
            return pick(nearlyDone(title: title, pagesLeft: pagesLeft), book: book, day: day, calendar: calendar)
        }
        if streak.current >= 3 {
            return pick(streakAtRisk(title: title, streak: streak.current), book: book, day: day, calendar: calendar)
        }
        if daysAway >= 7 {
            return pick(longNeglect(title: title, days: daysAway), book: book, day: day, calendar: calendar)
        }
        if daysAway >= 2 {
            return pick(shortNeglect(title: title, days: daysAway), book: book, day: day, calendar: calendar)
        }
        if knowsLength, percent >= 45, percent <= 65 {
            return pick(halfway(title: title, percent: percent), book: book, day: day, calendar: calendar)
        }
        if knowsLength, percent > 0 {
            return pick(underway(title: title, percent: percent, pagesLeft: pagesLeft), book: book, day: day, calendar: calendar)
        }
        return pick(justStarted(title: title), book: book, day: day, calendar: calendar)
    }

    // MARK: - Lines
    //
    // Several per situation so a fortnight of notifications doesn't read like one
    // message on repeat, which is when people turn them off.

    private static func alreadyRead(title: String, streak: Int) -> [(String, String)] {
        [
            ("Nice one 📖", "You've already read today. \(title) will keep."),
            ("Done for the day ✅", streak > 1
                ? "\(streak) days in a row now. \(title) is in good hands."
                : "You've put the time in today. \(title) can wait until tomorrow."),
        ]
    }

    private static func nearlyDone(title: String, pagesLeft: Int) -> [(String, String)] {
        [
            ("So close 🏁", "\(pagesLeft) pages left of \(title). That's one sitting."),
            ("Nearly there", "\(title) has \(pagesLeft) pages to go. You could finish it tonight."),
            ("The home stretch 🏃", "Only \(pagesLeft) pages of \(title) left. Go on."),
        ]
    }

    private static func streakAtRisk(title: String, streak: Int) -> [(String, String)] {
        [
            ("\(streak) days running 🔥", "Keep it going with a few pages of \(title)."),
            ("Don't break the run", "\(streak) days so far. \(title) is waiting."),
            ("Your streak says hello 👋", "\(streak) days. A page or two of \(title) keeps it alive."),
        ]
    }

    private static func longNeglect(title: String, days: Int) -> [(String, String)] {
        [
            ("Still on the shelf", "\(title) hasn't been opened in \(days) days. No judgement — just saying."),
            ("Remember \(title)? 👀", "It's been \(days) days. Pick up where you left off."),
            ("A book misses you", "\(days) days since \(title). Five minutes would do it."),
        ]
    }

    private static func shortNeglect(title: String, days: Int) -> [(String, String)] {
        [
            ("Where were we?", "\(days) days since you opened \(title). Easy to get back in."),
            ("\(title) is waiting", "It's been \(days) days. Just a few pages."),
        ]
    }

    private static func halfway(title: String, percent: Int) -> [(String, String)] {
        [
            ("Past the middle 🎯", "\(percent)% through \(title). This is usually where it stops being work."),
            ("Halfway there", "\(percent)% of \(title) done. The second half tends to go faster."),
        ]
    }

    private static func underway(title: String, percent: Int, pagesLeft: Int) -> [(String, String)] {
        [
            ("Pick up \(title) 📖", "You're \(percent)% in. \(pagesLeft) pages to go."),
            ("A few pages?", "\(title) is \(percent)% read. Tonight's the night."),
            ("Your bookmark hasn't moved", "\(percent)% through \(title). Nudge it along."),
        ]
    }

    private static func justStarted(title: String) -> [(String, String)] {
        [
            ("You started \(title) 🌱", "The first chapter is the hardest. Keep going."),
            ("A new one on the go", "\(title) is open. A few pages tonight?"),
        ]
    }

    private static func generic(for state: WireState, on day: Date, calendar: Calendar) -> ReadingNudge {
        // Nothing is being read, so there is nothing to name. Suggesting a book
        // from the want-to-read pile is more useful than a bare "time to read".
        let waiting = state.want.first
        let options: [(String, String)] = waiting.map { book in
            [
                ("Fancy starting something? 📚", "\(book.title) has been on your list a while."),
                ("Nothing on the go", "\(book.title) is waiting whenever you are."),
            ]
        } ?? [
            ("Time to read", "A few pages is all it takes."),
            ("Reading time 📖", "Even ten minutes counts."),
        ]
        let choice = options[stableIndex(seed: "generic-\(dayKey(day, calendar))", count: options.count)]
        return ReadingNudge(title: choice.0, body: choice.1, bookID: waiting?.id)
    }

    // MARK: - Choosing

    /// The book the nudge should be about: the one most recently read.
    ///
    /// Someone reading three books at once means the one they touched last, not
    /// whichever sits first in the array.
    static func currentBook(in state: WireState, by day: Date, calendar: Calendar) -> WireBook? {
        state.books
            .filter { $0.status == .reading }
            .map { book -> (WireBook, Date) in
                (book, book.logs.compactMap { ISO8601.date(from: $0.date) }.max() ?? .distantPast)
            }
            .max { $0.1 < $1.1 }
            .map(\.0)
    }

    static func daysSinceLastRead(_ book: WireBook, before day: Date, calendar: Calendar) -> Int {
        guard let last = book.logs.compactMap({ ISO8601.date(from: $0.date) }).max() else { return 0 }
        let from = calendar.startOfDay(for: last)
        let to = calendar.startOfDay(for: day)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    private static func pick(
        _ options: [(String, String)],
        book: WireBook,
        day: Date,
        calendar: Calendar
    ) -> ReadingNudge {
        let choice = options[stableIndex(seed: "\(book.id)-\(dayKey(day, calendar))", count: options.count)]
        return ReadingNudge(title: choice.0, body: choice.1, bookID: book.id)
    }

    private static func dayKey(_ day: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// Stable across launches — see `nudge(for:on:)` on why this can't be random.
    private static func stableIndex(seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(seed.stableFileHash % UInt32(count))
    }
}
