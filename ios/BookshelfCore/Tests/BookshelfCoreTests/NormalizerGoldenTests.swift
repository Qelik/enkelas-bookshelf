import Foundation
import Testing
@testable import BookshelfCore

/// The most important test in the iOS app.
///
/// `normalize()` is the contract between the phone and the browser: both read and
/// write the same blob through the same sync endpoint. If the Swift port and the
/// JavaScript disagree on one field, a user loses data the moment they switch
/// devices — and they lose it quietly, which is worse.
///
/// So this does not test the port against anyone's *reading* of the JavaScript.
/// `ios/Tools/generate-golden.sh` runs the real `window.__test.normalize` from
/// `app.js` in headless Chrome over a shared corpus and records what it actually
/// produced; this diffs the Swift output against that, field by field.
///
/// **When this fails after a web-app change, the port is out of date, not the
/// test.** Regenerate the golden, read the diff, and follow the JavaScript.
struct NormalizerGoldenTests {

    // Matches the stubs installed by golden-harness.html.
    static let frozenNow = ISO8601.date(from: "2026-08-04T00:00:00.000Z")!

    /// Ids are handed out in the order `normalize()` asks for them, and the
    /// harness resets its counter per case, so this does too.
    final class IDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            n += 1
            return "generated-id-\(n)"
        }
    }

    struct GoldenCase: Decodable {
        let name: String
        let input: JSONValue
        let expected: JSONValue
    }

    struct GoldenFile: Decodable {
        let cases: [GoldenCase]
    }

    static let golden: GoldenFile = {
        guard let url = Bundle.module.url(forResource: "normalizer-golden", withExtension: "json", subdirectory: "Golden")
                ?? Bundle.module.url(forResource: "normalizer-golden", withExtension: "json") else {
            fatalError("normalizer-golden.json missing — run ios/Tools/generate-golden.sh")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
    }()

    static var allCases: [GoldenCase] { golden.cases }

    @Test("the golden file is present and covers the corpus")
    func goldenFileLoaded() {
        #expect(Self.allCases.count >= 25, "golden file looks truncated — regenerate it")
        #expect(Self.allCases.contains { $0.name == "fixtures/sample-bookshelf.json" })
    }

    @Test("Swift normalize matches the JavaScript, case by case", arguments: Self.allCases)
    func matchesJavaScript(_ c: GoldenCase) throws {
        let ids = IDSequence()
        let normalizer = Normalizer(now: { Self.frozenNow }, makeID: { ids.next() })

        let actual = try JSONValue.from(normalizer.normalize(c.input))
        let (coercedExpected, coercedPaths) = Self.applyKnownStringCoercion(expected: c.expected, actual: actual)

        let diffs = JSONDiff.compare(expected: coercedExpected, actual: actual)
        #expect(diffs.isEmpty, """
            \(c.name): \(diffs.count) field(s) differ from the JavaScript
            \(diffs.prefix(20).map { "  · \($0)" }.joined(separator: "\n"))
            """)

        // The deviation is asserted, not assumed: it may only appear where the
        // corpus deliberately feeds a non-string into a string field.
        let allowed = Self.casesAllowedToCoerce[c.name] ?? []
        #expect(Set(coercedPaths) == Set(allowed), """
            \(c.name): string-coercion deviation appeared somewhere unexpected.
            got:      \(coercedPaths.sorted())
            expected: \(allowed.sorted())
            """)
    }

    @Test("normalizing an already-normalized shelf changes nothing")
    func idempotent() throws {
        // If this ever fails, two devices ping-pong forever: each pull rewrites
        // the blob, which bumps updatedAt, which the other device then pulls.
        let c = try #require(Self.allCases.first { $0.name == "fixtures/sample-bookshelf.json" })
        let ids = IDSequence()
        let normalizer = Normalizer(now: { Self.frozenNow }, makeID: { ids.next() })

        let once = try JSONValue.from(normalizer.normalize(c.input))
        let twice = try JSONValue.from(normalizer.normalize(once))
        let diffs = JSONDiff.compare(expected: once, actual: twice)
        #expect(diffs.isEmpty, "second pass changed \(diffs.count) field(s):\n\(diffs.prefix(10).map(\.description).joined(separator: "\n"))")
    }

    // MARK: - The one known deviation

    /// JavaScript's `b.title || "Untitled"` assigns the raw value with no
    /// `String()` around it, so a numeric title survives as a number over there
    /// and becomes a string here. See `JS.stringOr` for why that is accepted
    /// rather than fixed.
    ///
    /// This coerces the expected side wherever — and only where — Swift produced
    /// a string and the JavaScript produced a scalar, and reports every path it
    /// touched so the test can assert the deviation stayed put.
    static func applyKnownStringCoercion(expected: JSONValue, actual: JSONValue, path: String = "") -> (JSONValue, [String]) {
        switch (expected, actual) {
        case (.number, .string), (.bool, .string):
            return (.string(JS.string(expected)), [path])

        case (.array(let e), .array(let a)) where e.count == a.count:
            var out: [JSONValue] = []
            var paths: [String] = []
            for (i, pair) in zip(e, a).enumerated() {
                let (v, p) = applyKnownStringCoercion(expected: pair.0, actual: pair.1, path: "\(path)[\(i)]")
                out.append(v)
                paths += p
            }
            return (.array(out), paths)

        case (.object(let e), .object(let a)):
            var out = e
            var paths: [String] = []
            for (k, ev) in e {
                guard let av = a[k] else { continue }
                let (v, p) = applyKnownStringCoercion(expected: ev, actual: av, path: path.isEmpty ? k : "\(path).\(k)")
                out[k] = v
                paths += p
            }
            return (.object(out), paths)

        default:
            return (expected, [])
        }
    }

    /// Corpus cases that are *supposed* to hit the deviation, and exactly where.
    /// Anything else coercing is a bug in the port, not a known quirk.
    static let casesAllowedToCoerce: [String: [String]] = [
        "title falls back only when falsy": ["books[4].title"],
    ]
}

extension NormalizerGoldenTests.GoldenCase: CustomTestStringConvertible {
    var testDescription: String { name }
}
