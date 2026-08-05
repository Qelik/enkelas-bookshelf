import Foundation

/// What the widgets and Siri need, and nothing else.
///
/// The widgets deliberately do *not* read `bookshelf.json`. A widget extension
/// runs in about 30 MB and is killed outright if it exceeds that, while the
/// shelf is an unbounded document — every book, every session log, every note —
/// that has to be decoded and normalized in full before a single field can be
/// read. Deriving a few dozen bytes here, in the app, where there is memory and
/// time to do it, means the widget's job is to decode one small struct.
///
/// It also keeps the coupling honest: the widget depends on this shape, not on
/// the wire format, so the shelf can change without a widget rewrite.
public struct WidgetSnapshot: Codable, Sendable, Hashable {

    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var author: String
        public var currentPage: Int
        public var pages: Int
        /// 0…1. Precomputed rather than derived in the widget, so the two can't
        /// disagree about what "progress" means.
        public var progress: Double
        /// The same placeholder-cover hue the app and the web version use, so a
        /// book looks like itself on the Home Screen.
        public var hue: Int

        public init(
            id: String, title: String, author: String,
            currentPage: Int, pages: Int, progress: Double, hue: Int
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.currentPage = currentPage
            self.pages = pages
            self.progress = progress
            self.hue = hue
        }
    }

    /// Currently reading, most recently read first. Capped — see `make`.
    public var reading: [Item]
    public var streakCurrent: Int
    public var streakLongest: Int
    /// True once something has been logged today, which is what decides whether
    /// the streak widget is a reminder or a pat on the back.
    public var readToday: Bool
    public var pagesToday: Int
    /// Pages a day needed to finish the year's page goal on time, or nil when no
    /// page goal is set.
    public var pagesTargetToday: Int?
    public var goalTarget: Int
    public var goalDone: Int
    public var goalYear: Int
    /// Books the year's pace says should be finished by now.
    public var goalExpected: Double
    /// "Çelik's Bookshelf" — the widget is on the same Home Screen as the icon,
    /// so it says whose shelf it is the same way the app does.
    public var title: String
    /// Whoever's shelf this is picked a colour; a widget in the app's colour and
    /// an app in another is worse than no colour at all.
    public var theme: AppTheme
    public var updatedAt: Date

    public init(
        reading: [Item] = [], streakCurrent: Int = 0, streakLongest: Int = 0,
        readToday: Bool = false, pagesToday: Int = 0, pagesTargetToday: Int? = nil,
        goalTarget: Int = 0, goalDone: Int = 0, goalYear: Int = 0, goalExpected: Double = 0,
        title: String = "Bookshelf", theme: AppTheme = .fallback, updatedAt: Date = Date()
    ) {
        self.reading = reading
        self.streakCurrent = streakCurrent
        self.streakLongest = streakLongest
        self.readToday = readToday
        self.pagesToday = pagesToday
        self.pagesTargetToday = pagesTargetToday
        self.goalTarget = goalTarget
        self.goalDone = goalDone
        self.goalYear = goalYear
        self.goalExpected = goalExpected
        self.title = title
        self.theme = theme
        self.updatedAt = updatedAt
    }

    /// Books ahead of (or behind) the year's pace — the number the goal widget
    /// shows. Positive is ahead.
    public var booksAhead: Double { Double(goalDone) - goalExpected }

    /// How many books the goal still needs.
    public var goalRemaining: Int { max(0, goalTarget - goalDone) }

    /// Pages still to read today to stay on the year's page pace.
    public var pagesLeftToday: Int? {
        guard let pagesTargetToday else { return nil }
        return max(0, pagesTargetToday - pagesToday)
    }

    /// The most-recently-read book, which is what the small widget shows.
    public var current: Item? { reading.first }
}

// MARK: - Derivation

public extension WidgetSnapshot {

    /// At most this many books ride along. A widget shows one or two; carrying
    /// the whole Reading shelf would defeat the point of a snapshot.
    static let readingLimit = 4

    static func make(
        from state: WireState,
        title: String,
        theme: AppTheme = .fallback,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        let streak = state.readingStreak(now: now, calendar: calendar)
        let goal = state.goalPacing(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let perDay = state.pagesPerDay(calendar: calendar)

        // Most recently read first: the shelf's own order is the user's, but a
        // widget has room for one book and it should be the one in their hand.
        let reading = state.books
            .filter { $0.status == .reading }
            .map { book -> (WireBook, Date) in
                let last = book.logs
                    .compactMap { ISO8601.date(from: $0.date) }
                    .max()
                // Never read: sort behind everything that has been, rather than
                // ahead of it, which `Date.distantPast` gets right and `now`
                // would get exactly backwards.
                return (book, last ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(readingLimit)
            .map { book, _ in
                Item(
                    id: book.id,
                    title: book.title,
                    author: book.author,
                    currentPage: Int(book.pagesRead),
                    pages: Int(book.totalPages),
                    progress: book.progress ?? 0,
                    hue: book.title.stableHue
                )
            }

        return WidgetSnapshot(
            reading: Array(reading),
            streakCurrent: streak.current,
            streakLongest: streak.longest,
            readToday: (perDay[today] ?? 0) > 0,
            pagesToday: Int(perDay[today] ?? 0),
            pagesTargetToday: dailyPageTarget(for: state, now: now, calendar: calendar),
            goalTarget: goal.target,
            goalDone: goal.done,
            goalYear: goal.year,
            goalExpected: goal.expectedByNow,
            title: title,
            theme: theme,
            updatedAt: now
        )
    }

    /// Pages a day to finish the year's page goal on time.
    ///
    /// Spread over the days *remaining*, not the whole year: someone who falls a
    /// week behind should see the number go up, which is the honest signal, not
    /// a fixed quota that quietly becomes unreachable.
    static func dailyPageTarget(
        for state: WireState, now: Date = Date(), calendar: Calendar = .current
    ) -> Int? {
        guard let goal = state.pagesGoal, goal.target > goal.done else { return nil }
        let year = state.settings.goalYear ?? calendar.component(.year, from: now)
        guard calendar.component(.year, from: now) == year,
              let startOfNext = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return nil }

        let daysLeft = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: startOfNext).day ?? 0
        // On the last day of the year the whole remainder is today's target,
        // and dividing by zero days would make it infinite.
        return Int(ceil(Double(goal.target - goal.done) / Double(max(1, daysLeft))))
    }
}

// MARK: - Storage

/// The App Group container the app and its extensions share.
///
/// An extension gets its own sandbox, so nothing the app writes to its own
/// container is visible to a widget. The group container is the one directory
/// both can see, and it is the only thing that makes a widget possible at all.
public enum SharedContainer {
    public static let groupIdentifier = "group.com.enkela.bookshelf"

    /// Nil when the entitlement is missing — on a build without the App Group
    /// capability, or in a unit test process. Callers degrade to showing
    /// placeholder content rather than crashing.
    public static func url(forFile name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: name)
    }
}

public extension WidgetSnapshot {
    static let filename = "widget-snapshot.json"

    /// Read whatever the app last published. Returns nil rather than throwing:
    /// a widget with no data should render its placeholder, not fail to draw.
    static func published() -> WidgetSnapshot? {
        guard let url = SharedContainer.url(forFile: filename),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder.snapshot.decode(WidgetSnapshot.self, from: data)
    }

    /// Publish for the widgets. Atomic, because a widget reload can land in the
    /// middle of a write and half a JSON document decodes as nothing.
    func publish() throws {
        guard let url = SharedContainer.url(forFile: Self.filename) else { return }
        try JSONEncoder.snapshot.encode(self).write(to: url, options: [.atomic])
    }
}

extension JSONDecoder {
    static let snapshot: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let snapshot: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
