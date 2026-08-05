import Foundation
import Testing
@testable import BookshelfCore

/// Unit coverage for the pieces the golden test leans on. The golden test proves
/// the *whole* normalizer matches; these pin the individual rules so a failure
/// says which one broke, and guard against the comparison itself going quiet.
struct CoercionTests {

    // MARK: - Negative control

    @Test("the diff actually detects differences")
    func diffIsNotVacuous() throws {
        // A comparison that silently passes everything is worse than no test:
        // 27 green cases would mean nothing. Prove the machinery bites.
        let a = try JSONValue.parse(Data(#"{"books":[{"title":"A","rating":4}]}"#.utf8))
        let b = try JSONValue.parse(Data(#"{"books":[{"title":"A","rating":5}]}"#.utf8))
        let diffs = JSONDiff.compare(expected: a, actual: b)
        #expect(diffs.count == 1)
        #expect(diffs.first?.path == "books[0].rating")

        // Missing keys and length changes must register too.
        let short = try JSONValue.parse(Data(#"{"books":[]}"#.utf8))
        #expect(!JSONDiff.compare(expected: a, actual: short).isEmpty)
        let extra = try JSONValue.parse(Data(#"{"books":[{"title":"A","rating":4,"extra":1}]}"#.utf8))
        #expect(JSONDiff.compare(expected: a, actual: extra).contains { $0.path == "books[0].extra" })

        // null vs absent vs a value are three different things.
        let nulled = try JSONValue.parse(Data(#"{"books":[{"title":"A","rating":null}]}"#.utf8))
        #expect(!JSONDiff.compare(expected: a, actual: nulled).isEmpty)
    }

    // MARK: - ToNumber

    @Test("Number() follows JavaScript", arguments: [
        (JSONValue.null, 0.0),
        (.bool(true), 1.0),
        (.bool(false), 0.0),
        (.string(""), 0.0),
        (.string("   "), 0.0),
        (.string("42"), 42.0),
        (.string("  350  "), 350.0),
        (.string("-2"), -2.0),
        (.string("+45"), 45.0),
        (.string("1e3"), 1000.0),
        (.string("4.5"), 4.5),
        (.string("0x10"), 16.0),
        (.array([]), 0.0),
        (.array([.number(5)]), 5.0),
    ])
    func numberMatchesJS(_ input: JSONValue, _ expected: Double) {
        #expect(JS.number(input) == expected)
    }

    @Test("Number() is NaN where JavaScript says NaN", arguments: [
        JSONValue.string("not a number"),
        .string("12abc"),           // JS rejects trailing garbage; Double("12abc") would too
        .string("1_000"),           // Swift accepts underscores, JS does not
        .string("nan"),
        .string("inf"),
        .object(["a": .number(1)]),
        .array([.number(1), .number(2)]),
    ])
    func nanMatchesJS(_ input: JSONValue) {
        #expect(JS.number(input).isNaN, "\(input) should be NaN")
    }

    @Test("zero means different things in different fields")
    func zeroSemantics() {
        // `Number(x) || 0` — nonsense and zero both land on zero.
        #expect(JS.numberOrZero(.string("nope")) == 0)
        #expect(JS.numberOrZero(.number(0)) == 0)
        // `Number(x) || 1` — a readCount of 0 becomes 1.
        #expect(JS.numberOr(.number(0), 1) == 1)
        #expect(JS.numberOr(.number(3), 1) == 3)
        // `x ? Number(x) : null` — a rating of 0 is "unrated".
        #expect(JS.numberIfTruthy(.number(0)) == nil)
        #expect(JS.numberIfTruthy(.number(4.5)) == 4.5)
        // `x != null ? Number(x) : null` — quote pages keep a genuine 0, and an
        // empty string becomes 0 rather than absent.
        #expect(JS.numberIfNotNull(.number(0)) == 0)
        #expect(JS.numberIfNotNull(.string("")) == 0)
        #expect(JS.numberIfNotNull(.null) == nil)
        // `x != null && x !== "" ? Number(x) : null` — journal, vocab, seriesNumber.
        #expect(JS.numberIfNotNullOrEmpty(.number(0)) == 0)
        #expect(JS.numberIfNotNullOrEmpty(.string("")) == nil)
        #expect(JS.numberIfNotNullOrEmpty(.null) == nil)
    }

    // MARK: - ToString

    @Test("String() renders values the way tags get stringified")
    func stringMatchesJS() {
        #expect(JS.string(.number(5)) == "5")           // not "5.0"
        #expect(JS.string(.number(1.5)) == "1.5")
        #expect(JS.string(.null) == "null")
        #expect(JS.string(.bool(true)) == "true")
        #expect(JS.string(.array([.string("a")])) == "a")
        #expect(JS.string(.array([.string("a"), .string("b")])) == "a,b")
        #expect(JS.string(.array([.string("a"), .null])) == "a,")   // join renders null as ""
        #expect(JS.string(.object(["x": .number(1)])) == "[object Object]")
    }

    @Test("the fallback is not evaluated when the value is present")
    func fallbackShortCircuits() {
        // `b.id || uid()` does not mint an id when one exists. Evaluating the
        // fallback eagerly would desynchronise the id sequence from the JS.
        var calls = 0
        func generated() -> String { calls += 1; return "generated" }

        #expect(JS.stringOr(.string("kept"), generated()) == "kept")
        #expect(calls == 0)
        #expect(JS.stringOr(.string(""), generated()) == "generated")
        #expect(calls == 1)
    }

    // MARK: - Truthiness

    @Test("truthiness matches JavaScript")
    func truthiness() {
        #expect(!JS.truthy(.null))
        #expect(!JS.truthy(.bool(false)))
        #expect(!JS.truthy(.number(0)))
        #expect(!JS.truthy(.number(.nan)))
        #expect(!JS.truthy(.string("")))
        #expect(JS.truthy(.string("0")))        // a non-empty string is truthy
        #expect(JS.truthy(.array([])))          // …and so is an empty array
        #expect(JS.truthy(.object([:])))
    }

    // MARK: - Junk tags

    @Test("Goodreads shelf names are stripped, real genres are not", arguments: [
        ("to-read", true), ("TO-READ", true), ("currently-reading", true),
        ("read", true), ("did-not-finish", true), ("dnf", true), ("abandoned", true),
        ("why-did-i-read-this", true), ("why-did-i", true),
        ("series: Discworld", true), ("serie-Foo", true),
        ("Fantasy", false), ("Sci-Fi", false), ("re-read later", false),
        ("Serious Literature", false),
    ])
    func junkTags(_ tag: String, _ isJunk: Bool) {
        #expect(Normalizer.isJunkTag(tag) == isJunk, "\(tag)")
    }

    // MARK: - Dates

    @Test("timestamps are written exactly the way JavaScript writes them")
    func isoFormat() throws {
        let d = try #require(ISO8601.date(from: "2026-08-04T12:34:56.789Z"))
        // Always UTC, always three fractional digits, always Z — matching
        // new Date().toISOString(). A shorter form would make an identical
        // instant look like a different value across clients.
        #expect(ISO8601.string(from: d) == "2026-08-04T12:34:56.789Z")
        // Parsing tolerates the shorter form the app may encounter.
        #expect(ISO8601.date(from: "2026-08-04T12:34:56Z") != nil)
        #expect(ISO8601.date(from: "not a date") == nil)
    }

    // MARK: - Encoding

    @Test("optional fields encode as explicit null, not as a missing key")
    func optionalsEncodeAsNull() throws {
        let normalizer = Normalizer(now: { Date(timeIntervalSince1970: 0) }, makeID: { "id" })
        let state = normalizer.normalize(try JSONValue.parse(Data(#"{"books":[{"id":"b"}]}"#.utf8)))
        let json = try JSONValue.from(state)
        let book = json["books"].arrayValue?.first ?? .null
        // JavaScript writes "rating": null; Swift would omit the key entirely
        // without the explicit encoders on WireBook.
        for key in ["rating", "seriesNumber", "publishedYear", "expectation", "bookmark", "startedAt", "finishedAt", "lentAt", "coverTriedAt"] {
            #expect(book.objectValue?[key] != nil, "\(key) should be present as null, not absent")
            #expect(book[key].isNull, "\(key) should be null")
        }
    }

    @Test("whole numbers encode without a decimal point")
    func integralNumbersEncodeCleanly() throws {
        let normalizer = Normalizer(now: { Date(timeIntervalSince1970: 0) }, makeID: { "id" })
        let state = normalizer.normalize(try JSONValue.parse(Data(#"{"books":[{"id":"b","totalPages":662}]}"#.utf8)))
        let text = String(decoding: try state.encodedJSON(), as: UTF8.self)
        #expect(text.contains("\"totalPages\":662"), "totalPages should serialize as 662, not 662.0")
    }
}
