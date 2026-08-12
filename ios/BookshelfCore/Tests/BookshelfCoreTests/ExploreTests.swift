import Foundation
import Testing
@testable import BookshelfCore

/// The three discovery feeds answer in three shapes, and the app treats them as
/// one list. These are the real payload shapes, trimmed — the field names are
/// what actually breaks when Open Library changes something.
struct ExploreTests {

    // MARK: - search.json / trending

    @Test("a search payload maps docs onto explore books")
    func parsesSearchDocs() throws {
        let json = """
        {"numFound": 2, "docs": [
          {"key": "/works/OL27448W", "title": "The Lord of the Rings",
           "author_name": ["J.R.R. Tolkien"], "cover_i": 9255566,
           "number_of_pages_median": 1193, "first_publish_year": 1954,
           "isbn": ["9780618640157", "0618640150"],
           "subject": ["Fantasy fiction", "Middle Earth (Imaginary place)"],
           "edition_count": 120},
          {"key": "/works/OL1W", "title": "A Stub With No Cover"}
        ]}
        """
        let books = try OpenLibrary.parseWorks(Data(json.utf8))

        // The stub has neither a cover nor an ISBN, so there is nothing to show it
        // by and nothing to look the real book up with.
        #expect(books.count == 1)
        let book = try #require(books.first)
        #expect(book.workKey == "/works/OL27448W")
        #expect(book.title == "The Lord of the Rings")
        #expect(book.author == "J.R.R. Tolkien")
        #expect(book.year == 1954)
        #expect(book.pages == 1193)
        #expect(book.isbn == "9780618640157")
        #expect(book.coverID == 9255566)
        #expect(book.editions == 120)
        #expect(book.detailLine == "1954 · 1193 pages")
        #expect(book.genre == "Fantasy fiction")
    }

    @Test("cataloguing exhaust doesn't become a genre")
    func filtersSubjectsDownToGenres() throws {
        // Dune's real subject list. Two of these twenty are genres.
        let json = """
        {"docs": [{"title": "Dune", "cover_i": 1, "subject": [
          "Dune (Imaginary place)", "Fiction", "Fiction, science fiction, general",
          "Dune (imaginary place), fiction", "New York Times reviewed", "Science fiction",
          "Science-fiction", "nyt:mass-market-monthly=2021-11-07",
          "award:hugo_award=1966", "Hugo Award Winner"]}]}
        """
        let book = try #require(try OpenLibrary.parseWorks(Data(json.utf8)).first)
        // Two genres survive: the facet strings, the parenthesised place, the
        // machine-readable keys and the accolades all go, and "Science-fiction"
        // dedupes against "Science fiction".
        #expect(book.genres == ["Fiction", "Science fiction"])
        #expect(book.genre == "Fiction")
    }

    @Test("the trending feed uses works rather than docs")
    func parsesTrendingWorks() throws {
        // Same field names as a search doc, different envelope key — which is the
        // whole reason one parser handles both.
        let json = """
        {"query": "", "works": [
          {"key": "/works/OL17930368W", "title": "Atomic Habits",
           "author_name": ["James Clear"], "cover_i": 12539702,
           "first_publish_year": 2016, "edition_count": 40}
        ]}
        """
        let books = try OpenLibrary.parseWorks(Data(json.utf8))
        #expect(books.count == 1)
        #expect(books.first?.title == "Atomic Habits")
        #expect(books.first?.author == "James Clear")
        // Trending carries no page count; the row still has to render.
        #expect(books.first?.pages == nil)
        #expect(books.first?.detailLine == "2016")
    }

    @Test("multiple authors join into one line")
    func joinsAuthors() throws {
        let json = """
        {"docs": [{"title": "Good Omens", "author_name": ["Terry Pratchett", "Neil Gaiman"],
                   "cover_i": 1}]}
        """
        let books = try OpenLibrary.parseWorks(Data(json.utf8))
        #expect(books.first?.author == "Terry Pratchett, Neil Gaiman")
    }

    @Test("a titleless record is dropped rather than shown as blank")
    func dropsTitleless() throws {
        let json = #"{"docs": [{"key": "/works/OL9W", "cover_i": 5}]}"#
        #expect(try OpenLibrary.parseWorks(Data(json.utf8)).isEmpty)
    }

    // MARK: - subjects

    @Test("a subject payload maps its own field names")
    func parsesSubjectFeed() throws {
        let json = """
        {"key": "/subjects/fantasy", "name": "Fantasy", "work_count": 12345, "works": [
          {"key": "/works/OL138052W", "title": "Alice's Adventures in Wonderland",
           "authors": [{"key": "/authors/OL22098A", "name": "Lewis Carroll"}],
           "cover_id": 10527843, "first_publish_year": 1865, "edition_count": 3547,
           "subject": ["Fantasy", "Children's fiction"]}
        ]}
        """
        let books = try OpenLibrary.parseSubject(Data(json.utf8))
        let book = try #require(books.first)
        #expect(book.title == "Alice's Adventures in Wonderland")
        #expect(book.author == "Lewis Carroll")
        #expect(book.coverID == 10527843)      // cover_id here, cover_i in search
        #expect(book.year == 1865)
        #expect(book.editions == 3547)
        #expect(book.pages == nil)             // subjects never carry one
    }

    @Test("a subject work with no cover is kept — the shelf is the point, not the picture")
    func keepsCoverlessSubjectWork() throws {
        // Unlike a search stub, a subject shelf is already a curated list; dropping
        // its coverless entries would leave holes in a browse of 24.
        let json = #"{"works": [{"key": "/works/OL2W", "title": "An Obscure Classic"}]}"#
        #expect(try OpenLibrary.parseSubject(Data(json.utf8)).count == 1)
    }

    // MARK: - blurbs

    @Test("a plain-string description is read straight off")
    func parsesStringBlurb() {
        let json = #"{"title": "Dune", "description": "A desert planet."}"#
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "A desert planet.")
    }

    @Test("an older record wraps its description in a value object")
    func parsesWrappedBlurb() {
        let json = """
        {"title": "Dune", "description": {"type": "/type/text", "value": "A desert planet."}}
        """
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "A desert planet.")
    }

    @Test("editorial reference tails are stripped out of a blurb")
    func stripsBlurbReferences() {
        let json = """
        {"description": "A desert planet. ([source][1])\\n\\n[1]: https://example.org/dune"}
        """
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "A desert planet.")
    }

    @Test("link spam is stripped out of a blurb")
    func stripsInlineLinks() {
        // The real Atomic Habits record, which ends in a download-site plug. There
        // is no markdown renderer behind this text, so the link would show verbatim.
        let json = """
        {"description": "Atomic Habits offers a proven framework. \
        [**Atomic Habits pdf**](https://example.com/doc/atomic-habits-pdf/)"}
        """
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "Atomic Habits offers a proven framework.")
    }

    @Test("markdown emphasis doesn't survive as literal asterisks")
    func stripsEmphasis() {
        // Straight from the Le Petit Prince record — there is no renderer behind
        // this text, so the asterisks would show.
        let json = #"{"description": "*Le Petit Prince* est une **œuvre** de langue française."}"#
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "Le Petit Prince est une œuvre de langue française.")
    }

    @Test("a bare URL left in the prose comes out too")
    func stripsBareURL() {
        let json = #"{"description": "See also https://example.org/dune for more."}"#
        #expect(OpenLibrary.parseBlurb(Data(json.utf8)) == "See also for more.")
    }

    @Test("no description at all is nil, not an empty string")
    func missingBlurbIsNil() {
        #expect(OpenLibrary.parseBlurb(Data(#"{"title": "Dune"}"#.utf8)) == nil)
        #expect(OpenLibrary.parseBlurb(Data(#"{"description": "   "}"#.utf8)) == nil)
    }

    // MARK: - Identity

    @Test("a book with no work key still has a stable id")
    func fallsBackToTitleAndAuthor() {
        let a = ExploreBook(title: "Dune", author: "Frank Herbert")
        let b = ExploreBook(title: "dune", author: "frank herbert")
        // Same book, differently cased in two feeds — ForEach must not see two rows.
        #expect(a.id == b.id)
    }
}
