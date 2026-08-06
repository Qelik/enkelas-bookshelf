import Foundation
import Testing
@testable import BookshelfCore

/// Packing books onto shelves. The arithmetic that looks obviously right and is
/// off by one gap.
struct ShelfLayoutTests {

    static func book(id: String, title: String, pages: Double = 300,
                     status: BookStatus = .reading) -> WireBook {
        var b = Fixture.book(id: id, title: title, status: status, totalPages: pages)
        b.author = "An Author"
        return b
    }

    // MARK: - Sizing

    @Test("a thicker book has a thicker spine")
    func pagesDriveThickness() {
        let novella = ShelfLayout.spine(for: Self.book(id: "a", title: "Short", pages: 120))
        let doorstop = ShelfLayout.spine(for: Self.book(id: "b", title: "Long", pages: 1100))
        #expect(novella.width < doorstop.width)
        #expect(novella.width >= ShelfLayout.minWidth)
        #expect(doorstop.width <= ShelfLayout.maxWidth)
    }

    @Test("a book with no page count still gets a usable spine")
    func unknownLengthIsStillABook() {
        // Plenty of shelves have books with no page count. A zero-width spine
        // would vanish, and a max-width one would lie.
        let spine = ShelfLayout.spine(for: Self.book(id: "a", title: "Unknown", pages: 0))
        #expect(spine.width >= ShelfLayout.minWidth)
        #expect(spine.width < ShelfLayout.maxWidth)
    }

    @Test("an absurd page count is clamped rather than running off the shelf")
    func clampsExtremes() {
        let spine = ShelfLayout.spine(for: Self.book(id: "a", title: "Everything", pages: 90_000))
        #expect(spine.width <= ShelfLayout.maxWidth)
        // Negative pages come from bad imports; they must not produce NaN, which
        // would propagate into the layout and blank the screen.
        let broken = ShelfLayout.spine(for: Self.book(id: "b", title: "Broken", pages: -50))
        #expect(broken.width.isFinite)
        #expect(broken.width >= ShelfLayout.minWidth)
    }

    @Test("the same book always looks the same")
    func sizingIsDeterministic() {
        // Height and lean come from a hash, not from randomness: a shelf that
        // reshuffles on every redraw is a lava lamp, not a bookshelf.
        let book = Self.book(id: "steady", title: "Steady")
        let a = ShelfLayout.spine(for: book)
        let b = ShelfLayout.spine(for: book)
        #expect(a == b)
        #expect(a.height >= ShelfLayout.minHeight)
        #expect(a.height <= ShelfLayout.maxHeight)
    }

    @Test("the spine colour matches the placeholder cover")
    func hueMatchesCovers() {
        // Same book, same colour, whether shown as a cover or as a spine.
        let book = Self.book(id: "a", title: "The Name of the Wind")
        #expect(ShelfLayout.spine(for: book).hue == "The Name of the Wind".stableHue)
    }

    // MARK: - Packing

    @Test("a row fills to the shelf width and no further")
    func rowsRespectWidth() {
        let spines = (0..<40).map { ShelfLayout.spine(for: Self.book(id: "b\($0)", title: "Book \($0)")) }
        let width = 340.0
        let rows = ShelfLayout.rows(spines, width: width, gap: 2)

        for row in rows {
            let used = row.reduce(0) { $0 + $1.width } + Double(max(0, row.count - 1)) * 2
            #expect(used <= width, "a row overflowed: \(used) > \(width)")
        }
        // Nothing lost, nothing duplicated, order preserved.
        #expect(rows.flatMap { $0 }.map(\.id) == spines.map(\.id))
    }

    @Test("order is the shelf's, not whatever packs tightest")
    func orderIsPreserved() {
        // A shelf that reorders itself to save space is one you can't find
        // anything on.
        let spines = [
            ShelfLayout.spine(for: Self.book(id: "wide", title: "Wide", pages: 1200)),
            ShelfLayout.spine(for: Self.book(id: "thin", title: "Thin", pages: 90)),
            ShelfLayout.spine(for: Self.book(id: "mid", title: "Mid", pages: 400)),
        ]
        let rows = ShelfLayout.rows(spines, width: 80)
        #expect(rows.flatMap { $0 }.map(\.id) == ["wide", "thin", "mid"])
    }

    @Test("a book wider than the shelf gets its own row instead of disappearing")
    func oversizedBookSurvives() {
        let spines = [ShelfLayout.spine(for: Self.book(id: "a", title: "A", pages: 1200))]
        let rows = ShelfLayout.rows(spines, width: 10)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["a"])
    }

    @Test("an empty shelf has no rows, and a zero width doesn't hang")
    func degenerateInputs() {
        #expect(ShelfLayout.rows([], width: 300).isEmpty)
        // Width is 0 on the first layout pass before geometry resolves; returning
        // one row beats looping forever or dropping every book.
        let one = [ShelfLayout.spine(for: Self.book(id: "a", title: "A"))]
        #expect(ShelfLayout.rows(one, width: 0).count == 1)
        #expect(ShelfLayout.rows([], width: 0).isEmpty)
    }
}

/// A photographed spine is as thick as the photograph says.
struct ShelfPhotoWidthTests {

    @Test("a photo's proportions win over the page-count guess")
    func photoOverridesPages() {
        // The page count only estimates thickness; a photograph of the actual
        // book knows. Forcing the photo into the guessed width would crop it,
        // and by a different amount for every book.
        let book = ShelfLayoutTests.book(id: "a", title: "A", pages: 200)
        let guessed = ShelfLayout.spine(for: book)
        let photographed = ShelfLayout.spine(for: book, photoAspect: 0.4)

        #expect(photographed.width != guessed.width)
        #expect(abs(photographed.width / photographed.height - 0.4) < 0.02)
        // A wide photo shortens the book rather than squashing it; the aspect
        // is what a photograph is meant to preserve.
        #expect(photographed.height <= guessed.height)
    }

    @Test("a wild aspect can't produce a spine as wide as the screen")
    func clampsPhotoWidth() {
        let book = ShelfLayoutTests.book(id: "a", title: "A")
        for aspect in [5.0, 0.0001, .infinity, Double.nan] {
            let spine = ShelfLayout.spine(for: book, photoAspect: aspect)
            #expect(spine.width >= ShelfLayout.minWidth)
            #expect(spine.width <= ShelfLayout.maxWidth)
            #expect(spine.width.isFinite)
        }
    }

    @Test("packing uses the photo width, so a row still fits")
    func packingRespectsPhotoWidth() {
        // The bug this guards: the packer measuring a guessed width while the
        // view drew a photo width, so rows overflowed the shelf.
        let books = (0..<12).map { ShelfLayoutTests.book(id: "b\($0)", title: "Book \($0)", pages: 150) }
        let spines = books.map { ShelfLayout.spine(for: $0, photoAspect: 0.42) }
        let width = 340.0
        for row in ShelfLayout.rows(spines, width: width, gap: 2) {
            let used = row.reduce(0) { $0 + $1.width } + Double(max(0, row.count - 1)) * 2
            #expect(used <= width)
        }
    }
}
