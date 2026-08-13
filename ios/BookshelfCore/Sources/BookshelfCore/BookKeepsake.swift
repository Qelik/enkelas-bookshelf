import Foundation

/// Everything you left behind in a book, gathered into one page.
///
/// **Why this instead of a star rating.** Competitors give you five stars and a
/// review box, which is a rating *of* the book. This app already collects the
/// things that are actually yours — the lines you marked, the characters you
/// kept track of, the words you looked up, what you wrote halfway through and
/// how long the whole thing took. Those are worth keeping; a rating isn't.
///
/// Derived rather than stored: every field comes from data the book already
/// carries, so a keepsake can't drift out of date and nothing new crosses the
/// wire.
public struct BookKeepsake: Sendable {
    public let title: String
    public let author: String
    public let rating: Double?
    public let started: Date?
    public let finished: Date?
    /// Calendar days from the first session to the last, inclusive.
    public let daysTaken: Int?
    public let sessions: Int
    public let pagesRead: Double
    public let minutesRead: Double
    public let readCount: Int

    public let quotes: [WireQuote]
    public let characters: [WireCharacter]
    public let vocab: [WireVocabEntry]
    public let journal: [WireJournalEntry]
    /// The review, when one was written.
    public let review: String

    /// Hours of measured reading, when any session was timed.
    public var hoursRead: Double? {
        minutesRead > 0 ? minutesRead / 60 : nil
    }

    /// Whether there's anything here worth showing.
    ///
    /// A book finished without a single note, quote or timed session has no
    /// keepsake — and offering an empty page as though it were a memento is
    /// worse than not offering one.
    public var hasAnything: Bool {
        !quotes.isEmpty || !characters.isEmpty || !vocab.isEmpty
            || !journal.isEmpty || !review.isEmpty || sessions > 0
    }

    /// What you'd put on a card: the counts that aren't zero.
    public var highlights: [(value: String, label: String)] {
        var out: [(String, String)] = []
        if let daysTaken { out.append(("\(daysTaken)", daysTaken == 1 ? "day" : "days")) }
        if pagesRead > 0 { out.append((Int(pagesRead).formatted(), "pages")) }
        if let hours = hoursRead, hours >= 0.5 {
            out.append((hours < 10 ? String(format: "%.1f", hours) : "\(Int(hours.rounded()))", "hours"))
        }
        if !quotes.isEmpty { out.append(("\(quotes.count)", quotes.count == 1 ? "quote" : "quotes")) }
        if !characters.isEmpty { out.append(("\(characters.count)", "characters")) }
        if !vocab.isEmpty { out.append(("\(vocab.count)", "new words")) }
        return out
    }

    /// One line summing up the reading itself, for the top of the card.
    public var summaryLine: String? {
        guard let finished else { return nil }
        let when = finished.formatted(.dateTime.month(.wide).year())
        guard let daysTaken else { return "Finished in \(when)" }
        if daysTaken <= 1 { return "Read in a day, \(when)" }
        return "\(daysTaken) days, finishing in \(when)"
    }
}

public extension WireBook {

    /// Gather this book's keepsake.
    func keepsake(calendar: Calendar = .current) -> BookKeepsake {
        let dates = logs
            .compactMap { ISO8601.date(from: $0.date) }
            .map { calendar.startOfDay(for: $0) }
            .sorted()

        // From the first session to the last, not from `startedAt` — a book
        // shelved as "reading" months before it was opened would otherwise claim
        // a year of reading that never happened.
        var days: Int?
        if let first = dates.first, let last = dates.last {
            days = max(1, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
        }

        return BookKeepsake(
            title: title,
            author: author,
            rating: rating,
            started: startedDate ?? dates.first,
            finished: finishedDate ?? dates.last,
            daysTaken: days,
            sessions: logs.count,
            pagesRead: pagesRead,
            minutesRead: logs.reduce(0) { $0 + $1.minutes },
            readCount: Int(max(1, readCount)),
            // Newest first everywhere: the last thing you marked is the one you
            // remember, and it's what a card should lead with.
            quotes: quotes.reversed(),
            characters: characters,
            vocab: vocab,
            journal: journal.sorted {
                (ISO8601.date(from: $0.date) ?? .distantPast) > (ISO8601.date(from: $1.date) ?? .distantPast)
            },
            review: review.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
