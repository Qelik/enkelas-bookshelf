import Foundation
import Testing
@testable import BookshelfCore

/// The verdict you get standing in a shop. Every test here is a question you'd
/// actually ask with the book in your hand, and a wrong answer costs real money.
struct ShelfVerdictTests {

    static let now = Date(timeIntervalSince1970: 1_781_006_400)

    static func shelf(_ books: [WireBook]) -> WireState {
        WireState(
            version: 1, updatedAt: ISO8601.string(from: now),
            settings: WireSettings(goal: [:]), shelfOrder: [], books: books
        )
    }

    static func book(
        id: String,
        title: String,
        author: String = "",
        status: BookStatus = .want,
        owned: Bool = false,
        isbn: String = "",
        series: String = "",
        number: Double? = nil,
        rating: Double? = nil,
        format: BookFormat = .physical
    ) -> WireBook {
        var b = Fixture.book(id: id, title: title, status: status)
        b.author = author
        b.owned = owned
        b.isbn = isbn
        b.seriesName = series
        b.seriesNumber = number
        b.rating = rating
        b.format = format
        return b
    }

    static func doc(title: String, author: String = "") -> OpenLibrary.Doc {
        var d = OpenLibrary.Doc()
        d.title = title
        d.author_name = author.isEmpty ? nil : [author]
        return d
    }

    // MARK: - The core question

    @Test("a book you own is recognised by its ISBN alone")
    func ownedByISBN() {
        // The offline case, and the one that matters most: a shop's signal is
        // terrible, and "do I already have this" is answerable without a lookup.
        let mine = Self.book(id: "b1", title: "Dune", owned: true, isbn: "9780441013593")
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))

        #expect(verdict.outcome == .owned)
        #expect(verdict.matchedBookID == "b1")
        #expect(verdict.headline == "You own this")
    }

    @Test("an ISBN-10 on the shelf matches the ISBN-13 on the barcode")
    func tenAndThirteenDigitISBNsAreTheSameBook() {
        // Barcodes are always 13 digits; shelves are full of 10s — that's what
        // Goodreads exports and what's printed in older books. Comparing them as
        // stored meant a book never matched itself and the scanner said "safe to
        // buy" about a copy already at home.
        let mine = Self.book(id: "b1", title: "Le petit prince", owned: true, isbn: "2070516458")
        let verdict = ShelfVerdict.make(isbn: "9782070516452", catalogue: nil, state: Self.shelf([mine]))
        #expect(verdict.outcome == .owned)
        #expect(verdict.matchedBookID == "b1")
    }

    @Test("an ISBN-less shelf still matches on the title the catalogue reports")
    func matchesByTitleWhenTheShelfHasNoISBNs() {
        // A Goodreads import arrives almost entirely without ISBNs. Matching on
        // ISBN alone would tell those users they own nothing.
        let mine = Self.book(id: "b1", title: "Dune", owned: true)
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "Dune (Dune, #1): 50th Anniversary Edition"),
            state: Self.shelf([mine])
        )
        #expect(verdict.outcome == .owned)
        #expect(verdict.matchedBookID == "b1")
    }

    @Test("a book on your list but not at home is a different answer from owning it")
    func onTheListButNotOwned() {
        let mine = Self.book(id: "b1", title: "Dune", status: .want, owned: false, isbn: "9780441013593")
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))

        #expect(verdict.outcome == .onShelf(.want))
        // The whole point of the distinction: this is a book to buy, not a
        // duplicate to put back.
        #expect(!verdict.outcome.isDuplicate)
        #expect(verdict.notes.contains { $0.id == "not-owned" })
    }

    @Test("a book you abandoned says so, with the reason you gave")
    func dnfIsRemembered() {
        var mine = Self.book(id: "b1", title: "Ulysses", status: .dnf, isbn: "9780441013593")
        mine.dnfReason = "Could not get past chapter three"
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))

        #expect(verdict.outcome == .onShelf(.dnf))
        #expect(verdict.detail.contains("Could not get past chapter three"))
    }

    @Test("nothing matching is a clear yes")
    func newBookIsSafeToBuy() {
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "Piranesi", author: "Susanna Clarke"),
            state: Self.shelf([Self.book(id: "b1", title: "Dune")])
        )
        #expect(verdict.outcome == .new)
        #expect(verdict.title == "Piranesi")
        #expect(verdict.author == "Susanna Clarke")
    }

    @Test("with no lookup and no match, the ISBN is still shown back")
    func offlineAndUnknown() {
        // Failing to a blank card would leave the reader unsure whether the scan
        // even worked.
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([]))
        #expect(verdict.outcome == .new)
        #expect(verdict.title.contains("978-0-441"))
    }

    // MARK: - Owning it in another form

    @Test("owning the audiobook isn't a reason not to buy the paperback")
    func aDifferentFormatIsNotADuplicate() {
        let mine = Self.book(id: "b1", title: "Dune", owned: true, isbn: "9780441013593", format: .audio)
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))
        #expect(verdict.notes.contains { $0.id == "format" && $0.text.contains("audiobook") })
    }

    @Test("a copy that's lent out is flagged, because it isn't on your shelf")
    func lentOutIsWorthKnowing() {
        var mine = Self.book(id: "b1", title: "Dune", owned: true, isbn: "9780441013593")
        mine.lentTo = "Ana"
        mine.lentAt = ISO8601.string(from: Self.now)
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))
        #expect(verdict.notes.contains { $0.id == "lent" && $0.text.contains("Ana") })
    }

    @Test("where the copy lives is repeated back, since that's why you're unsure")
    func locationIsShown() {
        var mine = Self.book(id: "b1", title: "Dune", owned: true, isbn: "9780441013593")
        mine.location = "Bedroom, top shelf"
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))
        #expect(verdict.notes.contains { $0.id == "location" && $0.text == "Bedroom, top shelf" })
    }

    // MARK: - Series

    @Test("a series title in brackets is understood")
    func parsesSeriesFromTitle() {
        let parsed = ShelfVerdict.parseSeries(fromTitle: "The Well of Ascension (Mistborn, #2)")
        #expect(parsed?.name == "Mistborn")
        #expect(parsed?.number == 2)

        #expect(ShelfVerdict.parseSeries(fromTitle: "Dune (Illustrated Edition)") == nil)
        #expect(ShelfVerdict.parseSeries(fromTitle: "Piranesi") == nil)
    }

    @Test("buying book three while book two is unread is the warning worth having")
    func outOfOrderWarning() {
        let state = Self.shelf([
            Self.book(id: "b1", title: "Mistborn", status: .finished, owned: true, series: "Mistborn", number: 1),
            Self.book(id: "b2", title: "The Well of Ascension", status: .want, owned: true, series: "Mistborn", number: 2),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "The Hero of Ages (Mistborn, #3)"),
            state: state
        )
        #expect(verdict.outcome == .new)
        #expect(verdict.notes.contains { $0.id == "series-gap" && $0.text.contains("#2") })
        #expect(verdict.notes.contains { $0.id == "series" && $0.text.contains("You have 2 from Mistborn") })
    }

    @Test("a series read in order gets no scolding")
    func noWarningWhenCaughtUp() {
        let state = Self.shelf([
            Self.book(id: "b1", title: "Mistborn", status: .finished, owned: true, series: "Mistborn", number: 1),
            Self.book(id: "b2", title: "The Well of Ascension", status: .finished, owned: true, series: "Mistborn", number: 2),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "The Hero of Ages (Mistborn, #3)"),
            state: state
        )
        #expect(!verdict.notes.contains { $0.id == "series-gap" })
        #expect(verdict.notes.contains { $0.id == "series-next" })
    }

    @Test("a series string from the edition record is understood too")
    func parsesSeriesFromEditionString() {
        // The form Open Library's edition records use. Titles can't be read this
        // way — "Fahrenheit 451" is not book 451 — but a series string already
        // says it's a series, so a bare trailing number is safe here.
        let numbered = ShelfVerdict.parseSeries(fromSeriesString: "The Mistborn Saga #3")
        #expect(numbered?.name == "The Mistborn Saga")
        #expect(numbered?.number == 3)

        // Plenty of series records carry no number at all.
        let bare = ShelfVerdict.parseSeries(fromSeriesString: "The Kingkiller Chronicle")
        #expect(bare?.name == "The Kingkiller Chronicle")
        #expect(bare?.number == nil)

        #expect(ShelfVerdict.parseSeries(fromSeriesString: "") == nil)
    }

    @Test("the catalogue's name for a series matches the reader's")
    func seriesNamesNeedNotMatchExactly() {
        // This is the case that actually happens: Open Library files The Hero of
        // Ages under "The Mistborn Saga" and the shelf calls it "Mistborn". Exact
        // matching meant the warning never fired on a real book.
        #expect(ShelfVerdict.seriesMatches("The Mistborn Saga", "Mistborn"))
        #expect(ShelfVerdict.seriesMatches("The Kingkiller Chronicle", "Kingkiller Chronicle"))
        #expect(!ShelfVerdict.seriesMatches("Mistborn", "Discworld"))
        #expect(!ShelfVerdict.seriesMatches("", "Mistborn"))
    }

    @Test("the reading-order warning fires on a series only the edition record named")
    func editionSeriesDrivesTheWarning() {
        // End to end for the real Hero of Ages case: the title carries no series
        // tail, so without the edition lookup there is no warning at all.
        let state = Self.shelf([
            Self.book(id: "b1", title: "Mistborn", status: .finished, owned: true, series: "Mistborn", number: 1),
            Self.book(id: "b2", title: "The Well of Ascension", status: .want, owned: true, series: "Mistborn", number: 2),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780765316899",
            catalogue: Self.doc(title: "The Hero of Ages", author: "Brandon Sanderson"),
            series: "The Mistborn Saga #3",
            state: state
        )
        #expect(verdict.notes.contains { $0.id == "series-gap" && $0.text.contains("#2") })
        // Named the way the reader files it, not the way the publisher does.
        #expect(verdict.notes.contains { $0.id == "series" && $0.text.contains("from Mistborn") })
        #expect(verdict.seriesNumber == 3)
    }

    @Test("already owning this exact instalment is called out")
    func duplicateInstalment() {
        // The expensive mistake: two copies of book two, bought a year apart,
        // because the covers were redesigned.
        let state = Self.shelf([
            Self.book(id: "b2", title: "The Well of Ascension", status: .finished, owned: true, series: "Mistborn", number: 2),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "The Well of Ascension: Mistborn Book Two"),
            state: state
        )
        // Title matched, so this resolves as owned — and that already says it.
        #expect(verdict.outcome == .owned)
    }

    // MARK: - Author history

    @Test("giving up on an author twice is said out loud")
    func repeatedDNFsByTheSameAuthor() {
        let state = Self.shelf([
            Self.book(id: "b1", title: "One", author: "China Miéville", status: .dnf),
            Self.book(id: "b2", title: "Two", author: "China Miéville", status: .dnf),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "Perdido Street Station", author: "China Miéville"),
            state: state
        )
        #expect(verdict.notes.contains { $0.id == "author-dnf" && $0.text.contains("2 of their books") })
    }

    @Test("an author you love is worth knowing about too")
    func authorYouRate() {
        let state = Self.shelf([
            Self.book(id: "b1", title: "One", author: "Susanna Clarke", status: .finished, rating: 5),
            Self.book(id: "b2", title: "Two", author: "Susanna Clarke", status: .finished, rating: 4),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "Piranesi", author: "Susanna Clarke"),
            state: state
        )
        #expect(verdict.notes.contains { $0.id == "author-read" && $0.text.contains("4.5★") })
    }

    @Test("an author is matched on surname, because catalogues spell names differently")
    func authorMatchedLoosely() {
        let state = Self.shelf([
            Self.book(id: "b1", title: "One", author: "Rothfuss", status: .finished, rating: 5),
            Self.book(id: "b2", title: "Two", author: "Rothfuss", status: .finished, rating: 5),
        ])
        let verdict = ShelfVerdict.make(
            isbn: "9780441013593",
            catalogue: Self.doc(title: "The Wise Man's Fear", author: "Patrick Rothfuss"),
            state: state
        )
        #expect(verdict.notes.contains { $0.id == "author-read" })
    }

    @Test("the book being scanned is not counted as its own author history")
    func matchedBookIsExcludedFromItsOwnHistory() {
        // "You've finished 1 by them" about the very book you're holding is not
        // a fact about anything.
        let mine = Self.book(
            id: "b1", title: "Piranesi", author: "Susanna Clarke",
            status: .finished, isbn: "9780441013593", rating: 5
        )
        let verdict = ShelfVerdict.make(isbn: "9780441013593", catalogue: nil, state: Self.shelf([mine]))
        #expect(!verdict.notes.contains { $0.id == "author-read" })
    }

    // MARK: - The pile

    @Test("the unread pile is mentioned only when the book is genuinely new")
    func pileIsOnlyForNewBooks() {
        var books = (1...6).map { Self.book(id: "p\($0)", title: "Pile \($0)", status: .want, owned: true) }
        let newVerdict = ShelfVerdict.make(
            isbn: "9780441013593", catalogue: Self.doc(title: "Piranesi"), state: Self.shelf(books)
        )
        #expect(newVerdict.notes.contains { $0.id == "pile" && $0.text.contains("6 books") })

        // Holding a book you already own, being told about your pile is just
        // scolding — the answer is already "put it back".
        books.append(Self.book(id: "own", title: "Piranesi", owned: true, isbn: "9780441013593"))
        let ownedVerdict = ShelfVerdict.make(
            isbn: "9780441013593", catalogue: Self.doc(title: "Piranesi"), state: Self.shelf(books)
        )
        #expect(!ownedVerdict.notes.contains { $0.id == "pile" })
    }
}
