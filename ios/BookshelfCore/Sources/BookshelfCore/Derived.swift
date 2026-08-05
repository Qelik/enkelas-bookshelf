import Foundation

/// Reading maths, ported from `src/app.ts`.
///
/// Unlike the normalizer, none of this crosses the wire — two clients can
/// disagree about a progress bar without anyone losing a book. It is still
/// ported rather than reinvented, because a shelf that says "62%" in the browser
/// and "58%" on the phone reads as a bug in both.
///
/// The web app memoises these behind a `derived()` epoch cache because it
/// recomputes on every full re-render. SwiftUI recomputes only what changed, so
/// the cache is deliberately not ported — it would be a second source of truth
/// to keep in sync for no benefit.
public extension WireBook {

    /// Total pages (or minutes, for audiobooks) logged against this book.
    var pagesRead: Double {
        logs.reduce(0) { $0 + $1.pages }
    }

    /// Cumulative pages read *before* a given session — the page you were on when
    /// it began. Sessions are summed in date order, not array order, so editing
    /// an old session computes against the right baseline.
    func pagesBefore(_ log: WireReadingLog?) -> Double {
        guard let log else { return pagesRead }
        var sum: Double = 0
        for l in logs.sortedByDate() {
            if l.id == log.id { break }
            sum += l.pages
        }
        return sum
    }

    /// 0…1, or nil when the book has no length to measure against.
    var progress: Double? {
        guard totalPages > 0 else { return nil }
        return min(1, max(0, pagesRead / totalPages))
    }

    var pagesRemaining: Double {
        max(0, totalPages - pagesRead)
    }

    /// Audiobooks are tracked in minutes; everything else in pages.
    var unitLabel: String { format == .audio ? "minutes" : "pages" }
    var unitLabelShort: String { format == .audio ? "min" : "pages" }

    var startedDate: Date? { startedAt.flatMap(ISO8601.date(from:)) }
    var finishedDate: Date? { finishedAt.flatMap(ISO8601.date(from:)) }
    var addedDate: Date? { ISO8601.date(from: addedAt) }

    /// The date the shelf sorts and groups a finished book by — its finish date
    /// if it has one, otherwise when it was added, so a book imported without a
    /// date still lands somewhere sensible instead of at the epoch.
    var libraryDate: Date? { finishedDate ?? addedDate }

    /// Estimated finish date from recent pace, or nil when there isn't enough to
    /// go on. Needs at least two distinct reading days — one session tells you
    /// nothing about a rate.
    func estimatedFinish(now: Date = Date(), calendar: Calendar = .current) -> (date: Date, daysLeft: Int)? {
        guard status == .reading, totalPages > 0 else { return nil }
        let read = pagesRead
        let remaining = totalPages - read
        guard remaining > 0 else { return nil }

        let days = Set(logs.compactMap { ISO8601.date(from: $0.date).map { calendar.startOfDay(for: $0) } }).sorted()
        guard days.count >= 2, let first = days.first, let last = days.last else { return nil }

        let span = max(1, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
        let pace = read / Double(span)
        guard pace > 0 else { return nil }

        let daysLeft = Int((remaining / pace).rounded(.up))
        // Ten years out is not a prediction, it is noise from a single slow week.
        guard daysLeft <= 3650 else { return nil }
        guard let date = calendar.date(byAdding: .day, value: daysLeft, to: now) else { return nil }
        return (date, daysLeft)
    }

    /// Matches `bookMatches()` in the web app: title, author or tag, case- and
    /// diacritic-insensitive so "Bronte" finds "Brontë".
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystack = ([title, author, seriesName] + tags + collections).joined(separator: " ")
        return haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public extension String {
    /// Stable hue in 0..<360, ported from `hashHue()` in `src/app.ts`.
    ///
    /// Swift's `hashValue` is seeded per process, so using it would give a book a
    /// different placeholder colour on every launch — which looks like the app
    /// forgetting something. This is deterministic, and being the same function
    /// the web app uses means a coverless book is the same colour in both.
    var stableHue: Int {
        var h: UInt32 = 0
        for scalar in unicodeScalars {
            // JavaScript iterates UTF-16 code units, so anything outside the BMP
            // has to be split the same way or the two clients disagree.
            for unit in String(scalar).utf16 {
                h = h &* 31 &+ UInt32(unit)
            }
        }
        return Int(h % 360)
    }
}

public extension Array where Element == WireReadingLog {
    /// Oldest first. Log order in the blob is insertion order, which is *usually*
    /// chronological but isn't after an edit.
    func sortedByDate() -> [WireReadingLog] {
        sorted {
            (ISO8601.date(from: $0.date) ?? .distantPast) < (ISO8601.date(from: $1.date) ?? .distantPast)
        }
    }
}

public extension WireState {
    var reading: [WireBook] { books.filter { $0.status == .reading } }
    var want: [WireBook] { books.filter { $0.status == .want } }
    /// The Library tab is finished *and* did-not-finish — a DNF is still a book
    /// you have a history with, and hiding it loses that.
    var library: [WireBook] { books.filter { $0.status == .finished || $0.status == .dnf } }
    var owned: [WireBook] { books.filter(\.owned) }

    var totalPagesRead: Double { books.reduce(0) { $0 + $1.pagesRead } }

    func book(id: String) -> WireBook? { books.first { $0.id == id } }

    /// Every tag in use, deduplicated case-insensitively, keeping the first
    /// spelling seen so the filter list doesn't show "Fantasy" and "fantasy".
    var allTags: [String] { uniqueValues(\.tags) }
    var allCollections: [String] { uniqueValues(\.collections) }

    private func uniqueValues(_ key: KeyPath<WireBook, [String]>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for book in books {
            for value in book[keyPath: key] where !value.isEmpty {
                if seen.insert(value.lowercased()).inserted { out.append(value) }
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
