import Foundation

/// A book from the catalogue that isn't on the shelf yet.
///
/// Deliberately not a `WireBook`: nothing here has been decided by the reader,
/// and a half-built shelf entry floating around would be the easiest possible way
/// to get an un-normalized book into the store. Adding one goes through
/// `NewBook.make` like every other entry point.
public struct ExploreBook: Identifiable, Sendable, Hashable, Codable {
    /// Open Library's work id, `/works/OL…W`. Absent on the odd feed entry, which
    /// is why `id` has a fallback rather than making this non-optional.
    public var workKey: String?
    public var title: String
    public var author: String
    public var year: Int?
    public var pages: Int?
    public var isbn: String?
    public var coverID: Int?
    /// A cover that arrived as a URL rather than as an Open Library id — which is
    /// how the community board stores it, having been handed the URL by whichever
    /// client posted the recommendation.
    public var coverURLString: String?
    public var subjects: [String]
    /// How many editions exist — a rough stand-in for how well known a book is,
    /// and the only popularity signal the free API gives away.
    public var editions: Int?

    public init(
        workKey: String? = nil, title: String, author: String = "", year: Int? = nil,
        pages: Int? = nil, isbn: String? = nil, coverID: Int? = nil,
        coverURLString: String? = nil, subjects: [String] = [], editions: Int? = nil
    ) {
        self.workKey = workKey
        self.title = title
        self.author = author
        self.year = year
        self.pages = pages
        self.isbn = isbn
        self.coverID = coverID
        self.coverURLString = coverURLString
        self.subjects = subjects
        self.editions = editions
    }

    /// Stable across a reload of the same feed, which is what `ForEach` needs. Two
    /// different works with the same title *and* author would collide; they'd also
    /// be the same book to a reader.
    public var id: String {
        workKey ?? "\(title)|\(author)".lowercased()
    }

    /// An explicit URL wins over an id: it's the one the recommendation actually
    /// carries, and looking a cover up by id would just be a guess at the edition.
    public var coverURL: URL? {
        if let coverURLString, !coverURLString.isEmpty, let url = URL(string: coverURLString) {
            return url
        }
        return coverID.flatMap { OpenLibrary.coverURL(id: $0) }
    }

    /// "1954 · 320 pages" — whichever of the two the catalogue actually knows.
    public var detailLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let pages, pages > 0 { parts.append("\(pages) pages") }
        return parts.joined(separator: " · ")
    }

    /// The subjects a person would call genres.
    ///
    /// Open Library's list is twenty entries of cataloguing exhaust — "nyt:
    /// mass-market-monthly=2021-11-07", "award:hugo_award=1966", "Dune (imaginary
    /// place), fiction". What's left after dropping the machine-readable keys, the
    /// sentence-long facets and the shelf names is two or three real genres.
    public var genres: [String] {
        var seen = Set<String>()
        return subjects.filter { subject in
            let trimmed = subject.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
            // Machine-readable facets and multi-part descriptors: a colon, an
            // equals sign, a comma or a parenthesis never appears in a genre
            // somebody would type. That drops "nyt:trade-fiction-paperback=…",
            // "Fiction, science fiction, general" and "Dune (Imaginary place)".
            guard !trimmed.contains(where: { ":=,()".contains($0) }) else { return false }
            // Accolades and press mentions are facts about a book, not shelves to
            // file it under. Kept separate from the normalizer's `isJunkTag`, whose
            // behaviour has to keep matching the web app exactly.
            guard !Self.accolade.contains(where: { trimmed.range(of: $0, options: .caseInsensitive) != nil })
            else { return false }
            guard !Normalizer.isJunkTag(trimmed) else { return false }
            // "Science fiction" and "Science-fiction" are one genre spelled twice.
            let key = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
            return seen.insert(key).inserted
        }
    }

    private static let accolade = [
        "award", "bestseller", "best seller", "winner", "new york times", "nyt", "reviewed",
    ]

    /// The single best genre, for the one-value `genre` field.
    public var genre: String { genres.first ?? "" }
}

// MARK: - Discovery

public extension OpenLibrary {

    /// What Open Library's trending feed covers. Weekly is the default: daily is
    /// noisy enough to be a different list every visit, and yearly barely moves.
    enum TrendingPeriod: String, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly
    }

    /// What everyone else is reading right now.
    func trending(_ period: TrendingPeriod = .weekly, limit: Int = 24) async throws -> [ExploreBook] {
        var comps = URLComponents(string: "https://openlibrary.org/trending/\(period.rawValue).json")!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else { return [] }
        return try Self.parseWorks(try await get(url))
    }

    /// A genre shelf — `slug` is Open Library's subject key, e.g. `fantasy`.
    func subject(_ slug: String, limit: Int = 24) async throws -> [ExploreBook] {
        let path = slug.lowercased().replacingOccurrences(of: " ", with: "_")
        var comps = URLComponents(string: "https://openlibrary.org/subjects/\(path).json")!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else { return [] }
        return try Self.parseSubject(try await get(url))
    }

    /// Free-text search. Uses `q=` rather than the `title=`/`author=` pair that
    /// `search(title:author:isbn:)` uses: someone exploring types "books about
    /// grief" or half a title, and a fielded query finds neither.
    func discover(_ query: String, limit: Int = 24) async throws -> [ExploreBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(
                name: "fields",
                value: "key,title,author_name,cover_i,number_of_pages_median,first_publish_year,isbn,subject,edition_count"
            ),
        ]
        guard let url = comps.url else { return [] }
        return try Self.parseWorks(try await get(url))
    }

    /// The blurb from the work record, for the detail sheet.
    ///
    /// Returns nil rather than throwing: a book with no description is still worth
    /// showing, and every caller would have to swallow the error anyway.
    func blurb(workKey: String) async -> String? {
        let key = workKey.hasPrefix("/") ? workKey : "/" + workKey
        guard let url = URL(string: "https://openlibrary.org\(key).json"),
              let data = try? await get(url)
        else { return nil }
        return Self.parseBlurb(data)
    }

    /// Fills in what the trending and subject feeds leave out.
    ///
    /// Neither returns a page count or an ISBN, and a book added with no page
    /// count has no progress bar and no reading estimate — the two things the
    /// shelf is for. One search closes the gap, so it runs when a book is being
    /// added rather than for every row in a feed.
    func fill(_ book: ExploreBook) async -> ExploreBook {
        guard book.pages == nil || book.isbn == nil || book.workKey == nil else { return book }
        guard let hits = try? await search(title: book.title, author: book.author) else { return book }
        // Guard the match: a bare title search happily returns a different book
        // with the same name, and attaching its page count would be worse than
        // having none.
        guard let hit = hits.first(where: {
            book.author.isEmpty || Self.authorMatches(book.author, $0.author_name)
        }) else { return book }

        var filled = book
        if filled.pages == nil { filled.pages = hit.number_of_pages_median }
        if filled.isbn == nil { filled.isbn = hit.isbn?.first }
        if filled.coverID == nil { filled.coverID = hit.cover_i }
        if filled.subjects.isEmpty { filled.subjects = hit.subject ?? [] }
        if filled.year == nil { filled.year = hit.first_publish_year }
        // The work id too: a book that arrived from somewhere other than a
        // catalogue feed — a recommendation off the community board, say — has no
        // id of its own, and without one there's no blurb to show.
        if filled.workKey == nil { filled.workKey = hit.key }
        return filled
    }

    // MARK: - Parsing

    /// `search.json` and `/trending/*.json` use the same field names — one under
    /// `docs`, the other under `works`.
    static func parseWorks(_ data: Data) throws -> [ExploreBook] {
        struct Payload: Decodable {
            var docs: [Doc]?
            var works: [Doc]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.docs ?? payload.works ?? [])
            .compactMap(ExploreBook.init(doc:))
            // A row with neither a cover nor an ISBN is a catalogue stub: no
            // picture to recognise it by and nothing to look the real book up
            // with. They cluster at the bottom of a query and only add noise.
            .filter { $0.coverID != nil || $0.isbn != nil }
    }

    /// `/subjects/<slug>.json` answers in its own shape: authors are objects, the
    /// cover field is `cover_id`, and page counts are absent entirely.
    static func parseSubject(_ data: Data) throws -> [ExploreBook] {
        struct Author: Decodable { var name: String? }
        struct Work: Decodable {
            var key: String?
            var title: String?
            var authors: [Author]?
            var cover_id: Int?
            var first_publish_year: Int?
            var edition_count: Int?
            var subject: [String]?
        }
        struct Payload: Decodable { var works: [Work]? }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.works ?? []).compactMap { work in
            guard let title = work.title, !title.isEmpty else { return nil }
            return ExploreBook(
                workKey: work.key,
                title: title,
                author: (work.authors ?? []).compactMap(\.name).joined(separator: ", "),
                year: work.first_publish_year,
                coverID: work.cover_id,
                subjects: work.subject ?? [],
                editions: work.edition_count
            )
        }
    }

    /// Open Library stores a work's description either as a plain string or as
    /// `{ "type": …, "value": … }`, depending on how old the record is.
    static func parseBlurb(_ data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let field = json["description"]
        let text = field.stringValue ?? field["value"].stringValue
        guard let text else { return nil }

        // Open Library blurbs are editor-written markdown, and a good number end in
        // link spam — "[**Atomic Habits pdf**](https://…)" and the like. Rendered as
        // plain text that's worse than useless, so the links come out. Order
        // matters: the reference forms first, then inline links, then whatever bare
        // URL is left over.
        let stripped = text
            .replacingOccurrences(of: #"\(\[[^\]]*\]\[\d+\]\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*\[\d+\]:.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            // Markdown emphasis reads as literal asterisks with no renderer —
            // "*Le Petit Prince* est une œuvre…" is a real Open Library blurb.
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}

extension ExploreBook {
    /// A search or trending row. Both feeds omit the title on the odd broken
    /// record, and a nameless book can't be shown or added.
    init?(doc: OpenLibrary.Doc) {
        guard let title = doc.title, !title.isEmpty else { return nil }
        self.init(
            workKey: doc.key,
            title: title,
            author: doc.authorLine,
            year: doc.first_publish_year,
            pages: doc.number_of_pages_median,
            isbn: (doc.isbn ?? []).first,
            coverID: doc.cover_i,
            subjects: doc.subject ?? [],
            editions: doc.edition_count
        )
    }
}
