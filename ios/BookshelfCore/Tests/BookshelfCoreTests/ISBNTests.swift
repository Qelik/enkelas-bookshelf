import Foundation
import Testing
@testable import BookshelfCore

/// A scanner reads whatever is in front of the lens. These are the cases that
/// decide whether a wave of the phone adds the right book, the wrong book, or
/// nothing at all.
struct ISBNTests {

    @Test("real ISBN-13s off real books", arguments: [
        "9780553573404",   // A Game of Thrones
        "9780575081406",   // The Name of the Wind
        "9781408855652",   // Harry Potter, Bloomsbury
        "9780141439518",   // Pride and Prejudice, Penguin
    ])
    func acceptsRealThirteens(_ raw: String) {
        #expect(ISBN.normalize(raw) == raw)
    }

    @Test("hyphens and spaces as printed on the cover")
    func stripsSeparators() {
        #expect(ISBN.normalize("978-0-553-57340-4") == "9780553573404")
        #expect(ISBN.normalize("978 0 553 57340 4") == "9780553573404")
        #expect(ISBN.normalize("  9780553573404  ") == "9780553573404")
    }

    @Test("an ISBN-10 is converted, because the 13 is the canonical form")
    func convertsTens() {
        // Same book, both forms — an older paperback prints only the 10.
        #expect(ISBN.normalize("0553573403") == "9780553573404")
        #expect(ISBN.normalize("0-553-57340-3") == "9780553573404")
    }

    @Test("an X check digit is the one place a letter is allowed")
    func handlesXCheckDigit() {
        // 043942089X — a real ISBN-10 whose check digit is 10.
        #expect(ISBN.normalize("043942089X") == ISBN.toISBN13("043942089X"))
        #expect(ISBN.isValidISBN10("043942089X"))
        // But not anywhere else in the number.
        #expect(ISBN.normalize("04394208X9") == nil)
    }

    @Test("a single mistyped or misread digit is refused")
    func rejectsBadCheckDigits() {
        // The check digit exists precisely so a misread fails loudly. If these
        // passed, a bad scan would put the wrong book on the shelf.
        #expect(ISBN.normalize("9780553573405") == nil)
        #expect(ISBN.normalize("9780553573414") == nil)
        // One digit off the real ISBN-10 (0553573403).
        #expect(ISBN.normalize("0553573404") == nil)
    }

    @Test("an EAN-13 that isn't a book is refused", arguments: [
        "5449000000996",   // a can of Coke
        "4006381333931",   // a Stabilo pen
        "0012345678905",   // valid EAN-13, not Bookland
    ])
    func rejectsNonBookBarcodes(_ raw: String) {
        // These are valid barcodes with correct check digits — only the Bookland
        // prefix tells them apart from a book. Scanning a cereal box should do
        // nothing, not search for a cereal box.
        #expect(ISBN.isValidISBN13(raw), "test fixture should be a valid EAN-13")
        #expect(ISBN.normalize(raw) == nil)
    }

    @Test("979 is Bookland too")
    func acceptsThe979Prefix() {
        // Newer ISBNs and most sheet music sit under 979; refusing it would
        // reject recently published books.
        let body = "979012345678"
        var sum = 0
        for (i, ch) in body.enumerated() { sum += i % 2 == 0 ? ch.wholeNumberValue! : ch.wholeNumberValue! * 3 }
        let full = body + String((10 - sum % 10) % 10)
        #expect(ISBN.normalize(full) == full)
    }

    @Test("the price barcode beside the ISBN is not an ISBN")
    func rejectsPriceAddOn() {
        // Most paperbacks carry a second EAN-5 for the price. A scanner will read
        // it, and it must not be mistaken for a book.
        #expect(ISBN.normalize("51299") == nil)
        #expect(ISBN.normalize("90000") == nil)
    }

    @Test("junk of every length is refused", arguments: [
        "", "978", "97805535734040", "abcdefghij", "XXXXXXXXXX", "----------",
    ])
    func rejectsJunk(_ raw: String) {
        #expect(ISBN.normalize(raw) == nil)
    }

    @Test("formatting is for reading back, and never loses digits")
    func formatting() {
        #expect(ISBN.formatted("9780553573404") == "978-0-553-57340-4")
        // Anything unexpected passes through rather than being mangled.
        #expect(ISBN.formatted("123") == "123")
        #expect(ISBN.formatted("9780553573404").filter(\.isNumber) == "9780553573404")
    }
}
