import BookshelfCore
import Foundation

/// What Explore has already fetched.
///
/// Every visit to the tab used to clear the list and re-fetch it — a spinner and a
/// round-trip to see the same twenty-four books you saw a minute ago, and the same
/// again for every chip you tapped back to. Now a feed you've already seen is on
/// screen in the first frame and refreshed behind you only if it's old.
///
/// Browse feeds are kept on disk too, so opening Explore on a cold launch shows
/// books immediately. Searches stay in memory: a search is a deliberate question,
/// and answering yesterday's question from disk is not obviously right.
@MainActor
final class ExploreCache {
    static let shared = ExploreCache()

    /// How long each kind of feed stays fresh. Trending genuinely moves; a genre
    /// shelf of 24 books out of 14,000 does not, and a repeated search within a
    /// sitting is the same search.
    enum Kind {
        case trending, subject, search

        var ttl: TimeInterval {
            switch self {
            case .trending: 30 * 60
            case .subject: 6 * 3600
            case .search: 10 * 60
            }
        }

        /// Only browse feeds are worth keeping across launches.
        var persists: Bool {
            switch self {
            case .trending, .subject: true
            case .search: false
            }
        }
    }

    private struct Entry: Codable, Sendable {
        var books: [ExploreBook]
        var savedAt: Date
    }

    private var feeds: [String: Entry] = [:]
    /// Blurbs, in memory only — a book you open twice in one sitting shouldn't
    /// fetch twice. A key present with a nil value means "asked, there isn't one",
    /// which is the difference between not knowing and knowing there's nothing.
    private var blurbs: [String: String?] = [:]

    private let disk = DiskCache<[String: Entry]>(filename: "explore-feeds.json")
    /// Enough for the trending feed and every genre chip; beyond that the oldest
    /// go, so the file can't grow without bound.
    private static let persistLimit = 16

    private init() {
        feeds = disk.read()?.value ?? [:]
    }

    // MARK: - Feeds

    /// The cached books and their age, whatever that age is. The caller decides
    /// whether it's too old to keep, having already put it on screen.
    func feed(_ key: String) -> (books: [ExploreBook], savedAt: Date)? {
        guard let entry = feeds[key], !entry.books.isEmpty else { return nil }
        return (entry.books, entry.savedAt)
    }

    func store(_ books: [ExploreBook], for key: String, kind: Kind) {
        guard !books.isEmpty else { return }
        feeds[key] = Entry(books: books, savedAt: Date())
        guard kind.persists else { return }
        persist()
    }

    private func persist() {
        // Searches are dropped on the way out rather than filtered on the way in,
        // so an in-memory search hit still works for the rest of the session.
        let keepable = feeds.filter { !$0.key.hasPrefix(Self.searchPrefix) }
        let trimmed = keepable
            .sorted { $0.value.savedAt > $1.value.savedAt }
            .prefix(Self.persistLimit)
        disk.write(Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) }))
    }

    // MARK: - Keys

    private static let searchPrefix = "q:"

    static func key(trending period: OpenLibrary.TrendingPeriod) -> String { "trending:\(period.rawValue)" }
    static func key(subject slug: String) -> String { "subject:\(slug)" }
    static func key(search query: String) -> String {
        searchPrefix + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Blurbs

    /// True once this book's blurb has been looked up, whether or not it had one.
    func knowsBlurb(for workKey: String) -> Bool { blurbs.index(forKey: workKey) != nil }

    func blurb(for workKey: String) -> String? { blurbs[workKey] ?? nil }

    func store(blurb: String?, for workKey: String) { blurbs[workKey] = blurb }
}
