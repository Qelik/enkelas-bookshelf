import Foundation
import Testing
@testable import BookshelfCore

/// The hand-rolled parser must agree with the formatters it replaces, or every
/// date in the app shifts.
struct ISO8601FastPathTests {

    @Test("the fast path agrees with the formatter", arguments: [
        "2026-08-04T12:34:56.789Z",
        "2026-08-04T12:34:56Z",
        "1970-01-01T00:00:00.000Z",
        "2000-02-29T23:59:59.999Z",   // leap day
        "2024-12-31T23:59:59.001Z",
        "1999-03-01T00:00:00.000Z",
        "2026-01-01T00:00:00.000Z",
    ])
    func agreesWithFormatter(_ raw: String) throws {
        let fast = try #require(ISO8601.fastParse(raw), "fast path refused \(raw)")
        // Against the same two-formatter chain production uses: the
        // fractional formatter alone refuses a string without a fraction.
        let slow = try #require(ISO8601.slowParseForTesting(raw), "formatters refused \(raw)")
        #expect(abs(fast.timeIntervalSince1970 - slow.timeIntervalSince1970) < 0.0005, "\(raw)")
    }

    @Test("anything not in JavaScript's exact shape falls through", arguments: [
        "2026-08-04T12:34:56+02:00",  // explicit offset
        "2026-08-04T12:34:56",        // no zone
        "2026-08-04",                 // date only
        "2026-02-30T00:00:00.000Z",   // not a real day
        "2026-13-01T00:00:00.000Z",   // not a real month
        "2026-08-04T24:00:00.000Z",   // not a real hour
        "2026-08-04T12:34:56.Z",      // dot with no digits
        "garbage",
        "",
    ])
    func refusesEverythingElse(_ raw: String) {
        #expect(ISO8601.fastParse(raw) == nil, "\(raw)")
    }

    @Test("a round trip through our own writer survives the fast path")
    func roundTrip() throws {
        for offset in [0.0, 1.5, 1_700_000_000.123, -86_400.0] {
            let date = Date(timeIntervalSince1970: offset)
            let text = ISO8601.string(from: date)
            let back = try #require(ISO8601.fastParse(text), "\(text)")
            #expect(abs(back.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.0005, "\(text)")
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let forTesting: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
