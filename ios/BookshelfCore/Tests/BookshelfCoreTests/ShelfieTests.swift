import CoreGraphics
import Foundation
import Testing
@testable import BookshelfCore

/// Reading a shelf out of a photograph. Every rule here comes from a way a real
/// spine fails to become a book — which is why the review step exists and why
/// this logic is worth testing rather than eyeballing.
struct ShelfieTests {

    /// An upright spine of the given width, at `x`, spanning most of the height.
    static func spine(x: Double, width: Double = 0.05, top: Double = 0.1, bottom: Double = 0.9) -> SpineQuad {
        SpineQuad(
            topLeft: CGPoint(x: x, y: top),
            topRight: CGPoint(x: x + width, y: top),
            bottomRight: CGPoint(x: x + width, y: bottom),
            bottomLeft: CGPoint(x: x, y: bottom)
        )
    }

    // MARK: - Finding many spines

    @Test("spines come back in reading order, not detector order")
    func leftToRight() {
        // The review list is checked against the real shelf by eye. In confidence
        // order that comparison is impossible.
        let found = ShelfieDetection.spines(from: [
            Self.spine(x: 0.6), Self.spine(x: 0.1), Self.spine(x: 0.35),
        ])
        #expect(found.count == 3)
        #expect(found.map { $0.boundingBox.midX }.sorted() == found.map { $0.boundingBox.midX })
    }

    @Test("two detections of one spine become one book")
    func overlappingDetectionsCollapse() {
        // Vision routinely returns a spine and its own bottom half. Offering both
        // means every book on the shelf appears twice in the review list.
        let whole = Self.spine(x: 0.2, width: 0.06, top: 0.1, bottom: 0.9)
        let half = Self.spine(x: 0.21, width: 0.05, top: 0.5, bottom: 0.9)
        let found = ShelfieDetection.spines(from: [half, whole])
        #expect(found.count == 1)
        #expect(found[0].longSide == whole.longSide, "the full spine survives, not the fragment")
    }

    @Test("books standing side by side stay separate")
    func neighboursAreNotMerged() {
        // The other half of the same rule: adjacent spines touch, and collapsing
        // them would silently drop half the shelf.
        let found = ShelfieDetection.spines(from: [
            Self.spine(x: 0.20, width: 0.05),
            Self.spine(x: 0.25, width: 0.05),
            Self.spine(x: 0.30, width: 0.05),
        ])
        #expect(found.count == 3)
    }

    @Test("a shelf seen from a metre away still counts as spines")
    func thresholdsSuitAShelfNotASingleBook() {
        // SpineDetection wants 0.35 of the frame — tuned for one book held to the
        // lens. Thirty books in shot are a fifth of that each, and the stricter
        // rule rejected essentially the whole shelf.
        let distant = Self.spine(x: 0.3, width: 0.03, top: 0.4, bottom: 0.6)
        #expect(!SpineDetection.isPlausible(distant), "too small for the single-book detector")
        #expect(ShelfieDetection.isPlausible(distant))
    }

    @Test("the shelf edge and a poster are not books")
    func rejectsNonSpines() {
        // A shelf board is a long flat rectangle; a poster is a big square one.
        let board = SpineQuad(
            topLeft: CGPoint(x: 0.05, y: 0.8), topRight: CGPoint(x: 0.95, y: 0.8),
            bottomRight: CGPoint(x: 0.95, y: 0.86), bottomLeft: CGPoint(x: 0.05, y: 0.86)
        )
        let poster = SpineQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1), topRight: CGPoint(x: 0.8, y: 0.1),
            bottomRight: CGPoint(x: 0.8, y: 0.9), bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        #expect(!ShelfieDetection.isPlausible(board))
        #expect(!ShelfieDetection.isPlausible(poster))
    }

    // MARK: - Reading a spine

    @Test("the publisher's name is not the book")
    func dropsImprints() {
        // Sending "PENGUIN" to a catalogue search returns a thousand books.
        let read = SpineTextParser.parse(["PENGUIN", "The Remains of the Day", "Kazuo Ishiguro"])
        #expect(read.title == "The Remains of the Day")
        #expect(read.author == "Kazuo Ishiguro")
        #expect(!read.lines.isEmpty, "what was actually read is kept, so a person can check")
    }

    @Test("a publisher inside a title is left alone")
    func doesNotOverreach() {
        let read = SpineTextParser.parse(["The Penguin Book of English Verse"])
        #expect(read.title == "The Penguin Book of English Verse")
    }

    @Test("blurb furniture is dropped")
    func dropsNoise() {
        let read = SpineTextParser.parse([
            "A NOVEL", "WINNER OF THE BOOKER PRIZE", "Wolf Hall", "HILARY MANTEL", "4th Estate",
        ])
        #expect(read.usefulLines == ["Wolf Hall", "HILARY MANTEL"])
        // "Wolf Hall" has a name's exact shape — two capitalised words, no
        // articles. What separates them is that the author is caps-set and the
        // title isn't.
        #expect(read.title == "Wolf Hall")
        #expect(read.author == "HILARY MANTEL")
    }

    @Test("when the title and the author can't be told apart, neither is claimed")
    func ambiguousSplitIsLeftOpen() {
        // Both caps, both name-shaped. A confident wrong split sends the
        // catalogue looking for a book by nobody; leaving it open sends both
        // lines to a free-text search, which finds it either way round.
        let read = SpineTextParser.parse(["DARK MATTER", "BLAKE CROUCH"])
        #expect(read.author.isEmpty)
        #expect(read.query.contains("DARK MATTER"))
        #expect(read.query.contains("BLAKE CROUCH"))
    }

    @Test("an author is not mistaken for the title, however long their name")
    func authorIsNotTheTitle() {
        // The naive "longest line is the title" rule picks the author here, and
        // then every search is for a person rather than a book.
        let read = SpineTextParser.parse(["Dune", "Frank Herbert"])
        #expect(read.title == "Dune")
        #expect(read.author == "Frank Herbert")
    }

    @Test("a two-word title isn't handed over to the author")
    func titlesThatLookLikeNames() {
        // "Wolf Hall" and "Dark Matter" have a name's shape. The article rule and
        // the punctuation rule are what keep them titles.
        let hall = SpineTextParser.parse(["The Secret History", "Donna Tartt"])
        #expect(hall.title == "The Secret History")
        #expect(hall.author == "Donna Tartt")
    }

    @Test("ISBNs, prices and colophons are noise")
    func dropsNumbers() {
        let read = SpineTextParser.parse(["9780141439518", "£9.99", "III", "Middlemarch", "George Eliot"])
        #expect(read.title == "Middlemarch")
        #expect(read.author == "George Eliot")
    }

    @Test("a spine nothing could be read from says so rather than guessing")
    func unreadableSpine() {
        // Worn cloth, a shadow, a crop that missed. Offering a confident wrong
        // answer here is how a bulk import poisons a library.
        let read = SpineTextParser.parse(["|", "//", "8"])
        #expect(read.isEmpty)
        #expect(read.query.isEmpty)

        let candidate = ShelfieCandidate(quad: Self.spine(x: 0.1), text: read)
        #expect(!candidate.isUsable)
        #expect(candidate.displayTitle == "Couldn't read this one")
    }

    @Test("the search query carries both title and author when there is one")
    func query() {
        let read = SpineTextParser.parse(["Beloved", "Toni Morrison"])
        #expect(read.query == "Beloved Toni Morrison")
    }

    // MARK: - Not importing what's already there

    @Test("a book already on the shelf is recognised before it's added twice")
    func duplicateDetection() {
        // A shelfie of a bookcase you've already catalogued must offer to skip
        // what you have, not double every title.
        var mine = Fixture.book(id: "b1", title: "The Hobbit", status: .finished)
        mine.author = "J.R.R. Tolkien"
        let state = WireState(
            version: 1, updatedAt: "2026-08-13T00:00:00.000Z",
            settings: WireSettings(goal: [:]), shelfOrder: [], books: [mine]
        )

        let sameBook = ShelfieCandidate(
            quad: Self.spine(x: 0.1),
            text: SpineTextParser.parse(["HOBBIT", "TOLKIEN"])
        )
        #expect(state.existingBook(matching: sameBook)?.id == "b1")

        let other = ShelfieCandidate(
            quad: Self.spine(x: 0.2),
            text: SpineTextParser.parse(["Beloved", "Toni Morrison"])
        )
        #expect(state.existingBook(matching: other) == nil)
    }

    @Test("titles match across articles, case, accents and punctuation")
    func titleKeys() {
        #expect(ShelfieMatching.titleKey("The Hobbit") == ShelfieMatching.titleKey("HOBBIT,"))
        #expect(ShelfieMatching.titleKey("Émile") == ShelfieMatching.titleKey("emile"))
        #expect(ShelfieMatching.titleKey("Dune (Dune, #1)") == ShelfieMatching.titleKey("Dune"))
        #expect(ShelfieMatching.titleKey("Beloved") != ShelfieMatching.titleKey("Belated"))
    }
}
