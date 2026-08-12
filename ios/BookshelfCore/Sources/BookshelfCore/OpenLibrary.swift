import Foundation

/// Book metadata and cover lookup, ported from `searchOpenLibrary()` and
/// `findCoverFor()` in `src/app.ts`.
///
/// The waterfall order is not arbitrary and is worth preserving: Open Library
/// title/author search has the best coverage, its ISBN *image* endpoint knows
/// fewer editions and has to be validated, and Google Books is unauthenticated
/// and therefore rate-limited, so it goes last.
public struct OpenLibrary: Sendable {

    public struct Doc: Decodable, Sendable, Hashable {
        public var key: String?
        public var title: String?
        public var author_name: [String]?
        public var first_publish_year: Int?
        public var number_of_pages_median: Int?
        public var cover_i: Int?
        public var isbn: [String]?
        public var subject: [String]?
        public var edition_count: Int?

        public var authorLine: String { (author_name ?? []).joined(separator: ", ") }
        public var coverURL: URL? { cover_i.flatMap { OpenLibrary.coverURL(id: $0) } }
    }

    /// Why a lookup produced nothing. "No results" and "the service is down"
    /// look identical to the code that returns an empty array, but they are
    /// opposite instructions to the person waiting: one means *type it in
    /// yourself*, the other means *try again in a minute*.
    public enum LookupError: LocalizedError, Equatable {
        case unreachable
        case serviceUnavailable(status: Int)

        public var errorDescription: String? {
            switch self {
            case .unreachable:
                return "Couldn't reach Open Library. Check your connection, or fill this in yourself."
            case .serviceUnavailable:
                // Open Library answers 504 under load, and does it after a full
                // minute — common enough to be worth its own wording.
                return "Open Library is busy right now. Try again in a moment, or fill this in yourself."
            }
        }
    }

    private let session: URLSession

    /// Ten seconds, not URLSession's default sixty. Open Library routinely takes
    /// a minute to fail under load, and nobody watches a spinner that long — the
    /// keyboard is right there and typing the author is faster.
    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    private var timeout: TimeInterval = 10

    /// Not private: the discovery calls in `Explore.swift` need the same timeout
    /// and the same "an empty result and an outage are different things" error
    /// mapping, and duplicating either would let them drift.
    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LookupError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError.serviceUnavailable(status: status) }
        return data
    }

    // MARK: - Cover URLs

    public static func coverURL(id: Int, size: String = "L") -> URL? {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-\(size).jpg")
    }

    /// `default=false` makes Open Library 404 instead of serving its 1×1 "no
    /// cover" placeholder, which would otherwise load successfully and leave a
    /// blank rectangle where a cover should be.
    public static func coverURL(isbn: String, size: String = "L") -> URL? {
        let digits = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "https://covers.openlibrary.org/b/isbn/\(digits)-\(size).jpg?default=false")
    }

    // MARK: - Search

    public func search(title: String, author: String = "", isbn: String = "") async throws -> [Doc] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,number_of_pages_median,first_publish_year,isbn,subject"),
        ]
        let digits = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if !digits.isEmpty { items.append(URLQueryItem(name: "isbn", value: digits)) }
        if !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
        if !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }

        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        comps.queryItems = items
        guard let url = comps.url else { return [] }

        let data = try await get(url)

        struct Payload: Decodable { var docs: [Doc]? }
        var docs = (try JSONDecoder().decode(Payload.self, from: data).docs ?? [])
            .filter { $0.cover_i != nil || !($0.isbn ?? []).isEmpty }

        // Float author matches to the top, so the caller's first pick is the
        // right edition rather than whatever Open Library ranked highest.
        if !author.isEmpty {
            docs = docs.enumerated()
                .sorted { a, b in
                    let am = Self.authorMatches(author, a.element.author_name)
                    let bm = Self.authorMatches(author, b.element.author_name)
                    return am == bm ? a.offset < b.offset : am
                }
                .map(\.element)
        }
        return docs
    }

    /// Full cover waterfall for a book that hasn't got one. Returns nil rather
    /// than throwing: a missing cover is cosmetic, and a thrown error here would
    /// have to be swallowed by every caller anyway.
    public func findCover(for book: WireBook) async -> URL? {
        // Goodreads titles carry "(Series, #1)" and ": subtitle" tails that break
        // a strict title search, so try progressively barer forms.
        for title in Self.titleForms(book.title) {
            if let hit = try? await search(title: title, author: book.author).first(where: { $0.cover_i != nil }),
               let url = hit.coverURL {
                return url
            }
        }

        if !book.isbn.isEmpty, let url = Self.coverURL(isbn: book.isbn), await imageExists(url) {
            return url
        }

        // Fuzzy search: translated books are indexed under their original-language
        // title ("Emerald Green" lives as "Smaragdgrün"), which a strict title
        // search never finds. Guarded by an author match so a fuzzy hit can't
        // attach a completely wrong cover.
        if let url = await fuzzyCover(for: book) { return url }

        return await googleBooksCover(for: book)
    }

    // MARK: - Waterfall steps

    private func fuzzyCover(for book: WireBook) async -> URL? {
        let forms = Self.titleForms(book.title)
        let query = ((forms.last ?? book.title) + " " + book.author).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fields", value: "cover_i,author_name"),
        ]
        guard let url = comps.url, let data = try? await get(url) else { return nil }

        struct Payload: Decodable { var docs: [Doc]? }
        guard let docs = try? JSONDecoder().decode(Payload.self, from: data).docs else { return nil }
        let hit = docs.first {
            $0.cover_i != nil && (book.author.isEmpty || Self.authorMatches(book.author, $0.author_name))
        }
        return hit?.coverURL
    }

    private func googleBooksCover(for book: WireBook) async -> URL? {
        let digits = book.isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        let q = !digits.isEmpty
            ? "isbn:\(digits)"
            : "intitle:\(Self.bareTitle(book.title))" + (book.author.isEmpty ? "" : " inauthor:\(book.author)")

        var comps = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "3"),
            URLQueryItem(name: "fields", value: "items(volumeInfo(imageLinks))"),
        ]
        guard let url = comps.url, let data = try? await get(url) else { return nil }

        struct Links: Decodable { var thumbnail: String?; var smallThumbnail: String? }
        struct Info: Decodable { var imageLinks: Links? }
        struct Item: Decodable { var volumeInfo: Info? }
        struct Payload: Decodable { var items: [Item]? }

        guard let items = try? JSONDecoder().decode(Payload.self, from: data).items else { return nil }
        let link = items.lazy
            .compactMap { $0.volumeInfo?.imageLinks }
            .compactMap { $0.thumbnail ?? $0.smallThumbnail }
            .first
        guard var link else { return nil }
        // Google hands back http:// (blocked by App Transport Security) and a
        // page-curl overlay nobody wants on a cover.
        if link.hasPrefix("http:") { link = "https:" + link.dropFirst("http:".count) }
        link = link.replacingOccurrences(of: "&edge=curl", with: "")
        return URL(string: link)
    }

    /// Open Library answers 200 with a 1×1 placeholder for covers it hasn't got,
    /// so "did the request succeed" isn't the question — "is there an actual
    /// image here" is.
    private func imageExists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5      // a hung cover must not stall a backfill
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return data.count > 1000         // anything smaller is the placeholder
    }

    // MARK: - Title and author matching

    /// "The Name of the Wind (Kingkiller Chronicle, #1): A Novel" →
    /// ["The Name of the Wind", …] — bare form first, then the part before the
    /// colon, deduplicated and in search order.
    static func titleForms(_ title: String) -> [String] {
        let bare = bareTitle(title)
        var forms = [bare]
        if let colon = bare.firstIndex(of: ":"), colon > bare.startIndex {
            let core = String(bare[bare.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if !core.isEmpty, core != bare { forms.append(core) }
        }
        return forms.filter { !$0.isEmpty }
    }

    static func bareTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s*\[.*?\]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(.*?\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ported from `authorMatches()`. Compares on normalized full names and on
    /// surname alone, so "Rothfuss" matches "Patrick Rothfuss" — Open Library and
    /// Goodreads rarely spell an author the same way.
    public static func authorMatches(_ query: String, _ names: [String]?) -> Bool {
        guard let names, !names.isEmpty else { return false }
        let q = normalizeName(query)
        guard !q.isEmpty else { return false }
        let qLast = lastToken(q)
        for name in names {
            let n = normalizeName(name)
            if n.isEmpty { continue }
            if n == q || n.contains(q) || q.contains(n) { return true }
            let nLast = lastToken(n)
            if !qLast.isEmpty, qLast == nLast { return true }
        }
        return false
    }

    private static func normalizeName(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func lastToken(_ s: String) -> String {
        s.split(separator: " ").last.map(String.init) ?? ""
    }
}
