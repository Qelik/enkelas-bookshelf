import Foundation

/// Date strings in exactly the shape JavaScript writes them.
///
/// `new Date().toISOString()` is always UTC, always has three fractional digits,
/// and always ends in `Z` — `2026-08-04T12:34:56.789Z`. Foundation's default
/// `ISO8601DateFormatter` drops the milliseconds, which would make a timestamp
/// written by the phone visibly different from the same instant written by the
/// browser. Everything the app *generates* goes through `string(from:)`.
public enum ISO8601 {

    /// `new Date().toISOString()`.
    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// Best-effort parse. Accepts ISO 8601 with or without fractional seconds and
    /// with `Z` or an explicit offset.
    ///
    /// **The fast path matters more than it looks.** Every reading statistic —
    /// streaks, the calendar, badges, challenges, the widget snapshot — walks every
    /// session log and parses its date. `ISO8601DateFormatter.date(from:)` costs
    /// roughly 25µs, so a shelf with a few thousand sessions spent tens of
    /// milliseconds *per derivation*, and the Progress screen calls eight of them.
    /// That was the app freezing.
    ///
    /// Nearly every string here was written by `string(from:)` or by
    /// `Date.toISOString()` in the browser, both of which emit exactly
    /// `2026-08-04T12:34:56.789Z`. Parsing that shape by hand is ~50× faster.
    /// Anything else falls through to the formatters, so odd input still works.
    public static func date(from string: String) -> Date? {
        if let fast = fastParse(string) { return fast }
        if let d = parserWithFraction.date(from: string) { return d }
        return parserWithoutFraction.date(from: string)
    }

    /// The formatter chain, exposed so a test can prove the fast path agrees
    /// with it rather than merely being self-consistent.
    static func slowParseForTesting(_ string: String) -> Date? {
        parserWithFraction.date(from: string) ?? parserWithoutFraction.date(from: string)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.sss]Z` only. Returns nil for anything else — an
    /// explicit offset, a missing `Z`, a two-digit year — rather than guessing.
    static func fastParse(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8 { b -> Date? in
            // "2026-08-04T12:34:56Z" is the shortest acceptable form.
            guard b.count >= 20,
                  b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
                  b[10] == UInt8(ascii: "T"),
                  b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
                  let year = digits(b, 0, 4),
                  let month = digits(b, 5, 2),
                  let day = digits(b, 8, 2),
                  let hour = digits(b, 11, 2),
                  let minute = digits(b, 14, 2),
                  let second = digits(b, 17, 2)
            else { return nil }

            // Validated rather than allowed to roll over, so this accepts exactly
            // what the formatters would. "2026-02-30" must stay a parse failure,
            // not silently become March 2nd.
            guard month >= 1, month <= 12,
                  day >= 1, day <= daysIn(month: month, year: year),
                  hour <= 23, minute <= 59, second <= 60
            else { return nil }

            var index = 19
            var fraction = 0.0
            if index < b.count, b[index] == UInt8(ascii: ".") {
                index += 1
                var scale = 0.1
                var seen = 0
                while index < b.count, b[index] >= 48, b[index] <= 57 {
                    fraction += Double(b[index] - 48) * scale
                    scale /= 10
                    index += 1
                    seen += 1
                }
                guard seen > 0 else { return nil }
            }
            // UTC only. An explicit offset is rare enough that handing it to the
            // formatter is better than reimplementing timezone maths here.
            guard index == b.count - 1, b[index] == UInt8(ascii: "Z") else { return nil }

            let days = daysFromCivil(year: year, month: month, day: day)
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
    }

    private static func digits(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) -> Int? {
        var value = 0
        for i in start..<(start + count) {
            let c = b[i]
            guard c >= 48, c <= 57 else { return nil }
            value = value * 10 + Int(c - 48)
        }
        return value
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeap(year) ? 29 : 28
        }
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days since 1970-01-01 — Howard Hinnant's `days_from_civil`. Pure integer
    /// arithmetic, no `Calendar`, which is the other thing that made this slow.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                   // 0…399
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // Shared rather than built per call: constructing a date formatter costs tens
    // of microseconds, which on a large shelf is thousands of them per save. Safe
    // to share because each is fully configured inside its initializer closure and
    // never mutated again — `ISO8601DateFormatter` needs `nonisolated(unsafe)` to
    // say so, `DateFormatter` is already Sendable.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Fixed locale and calendar: without them a device set to a non-Gregorian
        // calendar (Buddhist, Japanese) writes the year in that calendar's era and
        // the timestamp is wrong by centuries.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    nonisolated(unsafe) private static let parserWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let parserWithoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
