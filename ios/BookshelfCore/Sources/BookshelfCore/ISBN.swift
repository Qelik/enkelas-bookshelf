import Foundation

/// Turning what a barcode scanner saw into an ISBN worth looking up.
///
/// A book's barcode is an EAN-13, and for books the EAN-13 *is* the ISBN-13. But
/// a camera pointed at a book sees more than one barcode: many have a second
/// EAN-5 alongside for the price, and a phone waved around a room will happily
/// read the EAN-13 off a cereal box. Validating here means a misread costs
/// nothing instead of a wasted network round trip and a wrong book on the shelf.
public enum ISBN {

    /// A valid ISBN-13, or nil.
    ///
    /// Accepts ISBN-10 (converting it, since Open Library indexes both and the
    /// 13 is the canonical form), ISBN-13, and either with hyphens or spaces.
    /// Rejects anything whose check digit doesn't add up, and any EAN-13 outside
    /// the Bookland prefixes — those are real barcodes for things that aren't
    /// books.
    public static func normalize(_ raw: String) -> String? {
        let digits = raw.uppercased().filter { $0.isNumber || $0 == "X" }

        switch digits.count {
        case 10:
            guard isValidISBN10(digits) else { return nil }
            return toISBN13(digits)
        case 13:
            // 978 and 979 are the two prefixes assigned to books. A 13-digit
            // code starting anything else is a grocery item, and looking it up
            // would either fail or — worse — match something unrelated.
            guard digits.hasPrefix("978") || digits.hasPrefix("979") else { return nil }
            guard isValidISBN13(digits) else { return nil }
            return digits
        default:
            return nil
        }
    }

    /// True when `raw` is a book barcode we can use. For gating a scanner's
    /// candidate before committing to it.
    public static func isValid(_ raw: String) -> Bool { normalize(raw) != nil }

    // MARK: - Check digits

    /// ISBN-10: weights 10…1, sum divisible by 11, final digit may be `X` = 10.
    static func isValidISBN10(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        var sum = 0
        for (i, ch) in s.enumerated() {
            let value: Int
            if ch == "X" {
                // Only the check digit may be X.
                guard i == 9 else { return false }
                value = 10
            } else if let d = ch.wholeNumberValue {
                value = d
            } else {
                return false
            }
            sum += value * (10 - i)
        }
        return sum % 11 == 0
    }

    /// ISBN-13/EAN-13: weights alternating 1 and 3, sum divisible by 10.
    static func isValidISBN13(_ s: String) -> Bool {
        guard s.count == 13 else { return false }
        var sum = 0
        for (i, ch) in s.enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            sum += i % 2 == 0 ? d : d * 3
        }
        return sum % 10 == 0
    }

    /// ISBN-10 → ISBN-13: prefix `978`, drop the old check digit, recompute.
    static func toISBN13(_ isbn10: String) -> String? {
        guard isbn10.count == 10 else { return nil }
        let body = "978" + isbn10.dropLast()
        guard body.allSatisfy({ $0.isNumber }) else { return nil }

        var sum = 0
        for (i, ch) in body.enumerated() {
            guard let d = ch.wholeNumberValue else { return nil }
            sum += i % 2 == 0 ? d : d * 3
        }
        let check = (10 - sum % 10) % 10
        return body + String(check)
    }

    /// Grouped the way it's printed on a book, for showing back to the user.
    ///
    /// Not a real ISBN registrant split — that needs the full range table — just
    /// a readable grouping so a 13-digit run isn't a wall of digits.
    public static func formatted(_ isbn13: String) -> String {
        guard isbn13.count == 13 else { return isbn13 }
        let d = Array(isbn13)
        return "\(String(d[0...2]))-\(d[3])-\(String(d[4...6]))-\(String(d[7...11]))-\(d[12])"
    }
}
