import Foundation

/// Building a brand-new book.
///
/// **Always through `normalize()`, never by hand.** The normalizer decides what a
/// book *is* — which fields exist, what their defaults are, how ids are minted —
/// and it is a rebuild whitelist. A `WireBook` assembled directly would differ in
/// shape from one the browser created, and the difference would only show up as a
/// spurious sync conflict later.
///
/// Extracted so the editor and the barcode scanner share one path. They had every
/// reason to drift: two call sites, one of them prefilled from a catalogue.
public enum NewBook {

    /// Fields a caller may supply. Anything omitted gets the normalizer's default
    /// rather than an empty string chosen here.
    public struct Draft: Sendable {
        public var title: String = ""
        public var author: String = ""
        public var status: BookStatus = .want
        public var totalPages: Double?
        public var isbn: String = ""
        public var coverURL: String = ""
        public var seriesName: String = ""
        public var seriesNumber: Double?
        public var publishedYear: Double?
        public var genre: String = ""
        public var description: String = ""
        public var review: String = ""
        public var format: BookFormat = .physical
        public var owned: Bool = false
        public var rating: Double?
        public var tags: [String] = []

        public init() {}
    }

    public static func make(
        _ draft: Draft,
        normalizer: Normalizer = Normalizer(),
        now: Date = Date()
    ) -> WireBook? {
        var seed: [String: JSONValue] = [
            "title": .string(draft.title.trimmingCharacters(in: .whitespaces)),
            "author": .string(draft.author.trimmingCharacters(in: .whitespaces)),
            "isbn": .string(draft.isbn.trimmingCharacters(in: .whitespaces)),
            "coverUrl": .string(draft.coverURL),
            "seriesName": .string(draft.seriesName.trimmingCharacters(in: .whitespaces)),
            "genre": .string(draft.genre),
            "description": .string(draft.description),
            "review": .string(draft.review),
            "format": .string(draft.format.rawValue),
            "status": .string(draft.status.rawValue),
            "owned": .bool(draft.owned),
            // Junk tags are dropped rather than stored: Goodreads exports are full
            // of "to-read" and "currently-reading", which duplicate the status.
            "tags": .array(draft.tags
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !Normalizer.isJunkTag($0) }
                .map { .string($0) }),
        ]
        if let pages = draft.totalPages, pages > 0 { seed["totalPages"] = .number(pages) }
        if let n = draft.seriesNumber { seed["seriesNumber"] = .number(n) }
        if let year = draft.publishedYear { seed["publishedYear"] = .number(year) }
        // Zero stars means unrated, matching the web app — not a rating of zero.
        if let rating = draft.rating, rating > 0 { seed["rating"] = .number(rating) }

        let built = normalizer.normalize(.object(["books": .array([.object(seed)])]))
        guard var book = built.books.first else { return nil }

        // The status stamps, applied here so every entry point agrees: a book
        // added straight to Reading has a start date, and one added as Finished
        // has both.
        let stamp = ISO8601.string(from: now)
        if draft.status == .reading || draft.status == .finished { book.startedAt = stamp }
        if draft.status == .finished { book.finishedAt = stamp }
        return book
    }
}
