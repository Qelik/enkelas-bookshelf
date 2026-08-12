import BookshelfCore
import SwiftUI

/// Putting a book found in a catalogue onto the shelf.
///
/// Shared by Explore and the community board, which are two ways of meeting the
/// same thing: a book that isn't yours yet, described by somebody else's data. The
/// interesting part is what has to happen *before* `NewBook.make` — filling in the
/// page count, finding the blurb — and duplicating that per screen is how one of
/// them quietly stops setting the genre.
@MainActor
enum CatalogueAdd {

    /// Adds the book and returns what actually went onto the shelf.
    ///
    /// Enriches first: the trending and subject feeds, and every community
    /// recommendation, arrive without a page count — and a book with no page count
    /// has no progress bar and no reading estimate, which are the two things the
    /// shelf is for.
    @discardableResult
    static func add(
        _ book: ExploreBook,
        as status: BookStatus,
        owned: Bool,
        store: BookshelfStore,
        catalogue: OpenLibrary = OpenLibrary()
    ) async -> WireBook? {
        async let filled = catalogue.fill(book)
        async let fetchedBlurb = blurb(for: book, catalogue: catalogue)

        let final = await filled
        var draft = NewBook.Draft()
        draft.title = final.title
        draft.author = final.author
        draft.status = status
        draft.totalPages = final.pages.map(Double.init)
        draft.isbn = final.isbn ?? ""
        draft.coverURL = final.coverURL?.absoluteString ?? ""
        draft.publishedYear = final.year.map(Double.init)
        draft.genre = final.genre
        // Tags are what the library's genre filter reads, and the web app fills
        // them from Open Library subjects on add too — so a book added here is
        // filterable straight away rather than needing an edit.
        draft.tags = Array(final.genres.prefix(3))
        draft.description = await fetchedBlurb ?? ""
        draft.owned = owned

        guard let made = NewBook.make(draft) else { return nil }
        store.add(book: made)
        Haptics.saved()
        return made
    }

    /// The blurb, from the session cache when it's already been fetched.
    static func blurb(for book: ExploreBook, catalogue: OpenLibrary = OpenLibrary()) async -> String? {
        guard let key = book.workKey else { return nil }
        if ExploreCache.shared.knowsBlurb(for: key) { return ExploreCache.shared.blurb(for: key) }
        let fetched = await catalogue.blurb(workKey: key)
        ExploreCache.shared.store(blurb: fetched, for: key)
        return fetched
    }

    /// The shelf entry this catalogue book already corresponds to, if any.
    ///
    /// Matched on ISBN when both sides have one and on title plus author
    /// otherwise: the catalogue, a Goodreads import and somebody else's
    /// recommendation spell the same book differently often enough that an
    /// exact-string check would call almost nothing a duplicate.
    static func onShelf(_ book: ExploreBook, in state: WireState) -> WireBook? {
        state.books.first { existing in
            if let isbn = book.isbn, !existing.isbn.isEmpty,
               let a = ISBN.normalize(isbn), let b = ISBN.normalize(existing.isbn), a == b {
                return true
            }
            guard existing.title.compare(
                book.title, options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame else { return false }
            // Same title by a different author is a different book — but a shelf
            // entry with no author at all shouldn't block the match.
            return book.author.isEmpty || existing.author.isEmpty
                || OpenLibrary.authorMatches(book.author, [existing.author])
        }
    }
}

extension ExploreBook {
    /// A board recommendation, as a catalogue book.
    ///
    /// The board stores only what the recommender typed plus a cover URL, so there
    /// is no work id and no page count here — `CatalogueAdd` looks those up.
    init(recommendation rec: Recommendation) {
        self.init(
            title: rec.title,
            author: rec.author,
            isbn: rec.book_isbn?.isEmpty == false ? rec.book_isbn : nil,
            coverURLString: rec.cover_url,
            subjects: rec.category.isEmpty ? [] : [rec.category]
        )
    }
}
