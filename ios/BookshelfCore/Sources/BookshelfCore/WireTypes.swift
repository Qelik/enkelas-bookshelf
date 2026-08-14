import Foundation

/// The on-the-wire shape of a bookshelf — a 1:1 mirror of `src/types.d.ts`, and
/// the format both `PUT /api/data` and `⬇ Export` speak.
///
/// Three rules keep this honest, and all three are load-bearing:
///
/// 1. **Dates stay strings.** Round-tripping through `Date` reformats them
///    (`…T00:00:00.000Z` becomes `…T00:00:00Z`), so a blob written by the phone
///    would differ from the identical blob written by the browser. Parse to
///    `Date` at the view-model boundary, never here.
/// 2. **Numbers are `Double`.** Everything in JavaScript is a double, so a
///    `totalPages` of `12.5` survives `normalize()` intact over there. Modelling
///    it as `Int` here would silently rewrite the value on the next sync.
///    Ergonomic `Int` accessors belong in the domain layer above this one.
/// 3. **Unknown keys are dropped, deliberately.** `normalize()` is a rebuild
///    whitelist — it constructs a fresh object from known fields only. Carrying
///    unknown book fields through would make the phone and the browser produce
///    *different* blobs from the same input, which is the exact failure this
///    type exists to prevent. The one exception is `settings.goal`, where the
///    web app uses `Object.assign` and extra keys really do survive.
public struct WireState: Codable, Sendable, Hashable {
    public var version: Int
    public var updatedAt: String
    public var settings: WireSettings
    /// The order of *things* on the shelf — book ids and object ids alike,
    /// which is what lets one drag gesture move either.
    public var shelfOrder: [String]
    public var books: [WireBook]
    /// The plant, the cat, the bust. Decorative, and tiny — an id, a kind and a
    /// hue — so unlike spine photographs these are cheap enough to sync.
    public var shelfObjects: [ShelfObject]

    public init(
        version: Int,
        updatedAt: String,
        settings: WireSettings,
        shelfOrder: [String],
        books: [WireBook],
        shelfObjects: [ShelfObject] = []
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.settings = settings
        self.shelfOrder = shelfOrder
        self.books = books
        self.shelfObjects = shelfObjects
    }
}

/// `settings.goal` is merged with `Object.assign` on the web side, not rebuilt,
/// so unknown keys survive and known ones are *not* coerced — a `target` of
/// `"abc"` stays the string `"abc"`. Modelling it as a raw dictionary is what
/// makes that reproducible; the accessors below cover the four known fields.
public struct WireSettings: Codable, Sendable, Hashable {
    public var goal: [String: JSONValue]

    public init(goal: [String: JSONValue]) { self.goal = goal }

    public var goalYear: Int? { goal["year"].flatMap { JS.numberIfTruthy($0).map(Int.init) } }
    public var goalTarget: Int? { goal["target"].flatMap { JS.numberIfTruthy($0).map(Int.init) } }
    public var goalPagesTarget: Int? { goal["pagesTarget"].flatMap { JS.numberIfTruthy($0).map(Int.init) } }
    public var goalDailyPages: Int? { goal["dailyPages"].flatMap { JS.numberIfTruthy($0).map(Int.init) } }
}

public enum BookStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case want, reading, finished, dnf
}

public enum BookFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case physical, ebook, audio
}

public struct WireBook: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var author: String
    public var totalPages: Double
    public var coverUrl: String
    public var isbn: String
    public var review: String
    public var description: String
    public var tags: [String]
    public var collections: [String]
    public var format: BookFormat
    public var seriesName: String
    public var seriesNumber: Double?
    public var publishedYear: Double?
    public var quotes: [WireQuote]
    public var readCount: Double
    public var finishHistory: [WireFinishRecord]
    public var journal: [WireJournalEntry]
    public var characters: [WireCharacter]
    public var vocab: [WireVocabEntry]
    public var bookmark: WireBookmark?
    public var dnfReason: String
    public var pickReason: String
    public var expectation: Double?
    public var loanDue: String
    public var owned: Bool
    public var location: String
    public var coverTriedAt: String?
    public var lentTo: String
    public var lentAt: String?
    /// When you asked for it back, as a bare `YYYY-MM-DD` — the same shape as
    /// `loanDue`, and for the same reason: a date somebody named, not an instant.
    public var lentDue: String
    public var status: BookStatus
    public var rating: Double?
    public var startedAt: String?
    public var finishedAt: String?
    public var addedAt: String
    public var logs: [WireReadingLog]
}

public struct WireReadingLog: Codable, Sendable, Hashable {
    public var id: String
    public var date: String
    /// Per-session delta. The form asks for the current page; the delta is stored.
    public var pages: Double
    public var minutes: Double
    public var mood: String
    public var note: String
}

public struct WireQuote: Codable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var page: Double?
    public var at: String?
}

/// A past finish. The web app accepts a bare date string here as well as an
/// object, because early versions stored `finishHistory: ["2024-01-01", …]`.
public struct WireFinishRecord: Codable, Sendable, Hashable {
    public var date: String?
    public var rating: Double?
}

public struct WireJournalEntry: Codable, Sendable, Hashable {
    public var id: String
    public var date: String
    public var page: Double?
    public var text: String
}

public struct WireCharacter: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var desc: String
}

public struct WireVocabEntry: Codable, Sendable, Hashable {
    public var id: String
    public var word: String
    public var def: String
    public var page: Double?
}

public struct WireBookmark: Codable, Sendable, Hashable {
    public var page: Double?
    public var note: String
    public var date: String?
}

// MARK: - Optionals must encode as explicit null

// Swift omits a nil property; JavaScript writes `"rating": null`. A missing key
// and a null key both read back as nil, so nothing breaks either way — but the
// golden comparison is structural, and "key absent" is not "key null". Encoding
// them explicitly keeps a phone-written blob byte-comparable with a browser one.
extension WireBook {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encode(totalPages, forKey: .totalPages)
        try c.encode(coverUrl, forKey: .coverUrl)
        try c.encode(isbn, forKey: .isbn)
        try c.encode(review, forKey: .review)
        try c.encode(description, forKey: .description)
        try c.encode(tags, forKey: .tags)
        try c.encode(collections, forKey: .collections)
        try c.encode(format, forKey: .format)
        try c.encode(seriesName, forKey: .seriesName)
        try c.encode(seriesNumber, forKey: .seriesNumber)
        try c.encode(publishedYear, forKey: .publishedYear)
        try c.encode(quotes, forKey: .quotes)
        try c.encode(readCount, forKey: .readCount)
        try c.encode(finishHistory, forKey: .finishHistory)
        try c.encode(journal, forKey: .journal)
        try c.encode(characters, forKey: .characters)
        try c.encode(vocab, forKey: .vocab)
        try c.encode(bookmark, forKey: .bookmark)
        try c.encode(dnfReason, forKey: .dnfReason)
        try c.encode(pickReason, forKey: .pickReason)
        try c.encode(expectation, forKey: .expectation)
        try c.encode(loanDue, forKey: .loanDue)
        try c.encode(owned, forKey: .owned)
        try c.encode(location, forKey: .location)
        try c.encode(coverTriedAt, forKey: .coverTriedAt)
        try c.encode(lentTo, forKey: .lentTo)
        try c.encode(lentAt, forKey: .lentAt)
        try c.encode(lentDue, forKey: .lentDue)
        try c.encode(status, forKey: .status)
        try c.encode(rating, forKey: .rating)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(logs, forKey: .logs)
    }
}

extension WireQuote {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(page, forKey: .page)
        try c.encode(at, forKey: .at)
    }
}

extension WireFinishRecord {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(rating, forKey: .rating)
    }
}

extension WireJournalEntry {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(page, forKey: .page)
        try c.encode(text, forKey: .text)
    }
}

extension WireVocabEntry {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(word, forKey: .word)
        try c.encode(def, forKey: .def)
        try c.encode(page, forKey: .page)
    }
}

extension WireBookmark {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(page, forKey: .page)
        try c.encode(note, forKey: .note)
        try c.encode(date, forKey: .date)
    }
}
