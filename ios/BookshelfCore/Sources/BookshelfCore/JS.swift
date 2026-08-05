import Foundation

/// JavaScript coercion rules, reproduced only as far as `normalize()` needs them.
///
/// This exists because the normalizer's contract is not "what would a Swift
/// developer do with this field" but "what does the web app already do with it".
/// A shelf written by the web app and one written by the phone have to be the
/// same shelf, and most of the divergence risk lives in a handful of small
/// coercions: `Number(x) || 0` turning nonsense into 0, `x ? … : null` treating
/// a rating of 0 as absent, `!!x` on `owned`.
///
/// Not a general JS engine. `ToPrimitive` on objects and arrays is implemented
/// only far enough to match `Number([])`, `Number([n])` and `Number({})`, which
/// is what a malformed blob realistically produces.
public enum JS {

    // MARK: - ToBoolean

    /// JS truthiness: `undefined`, `null`, `false`, `±0`, `NaN` and `""` are
    /// falsy; everything else — including `[]` and `{}` — is truthy.
    public static func truthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    // MARK: - ToNumber

    /// `Number(v)`. Returns NaN where JS returns NaN — callers decide what that
    /// means, exactly as `|| 0` or a preceding truthiness test does in the source.
    public static func number(_ v: JSONValue) -> Double {
        switch v {
        case .null: return 0                    // Number(null) === 0
        case .bool(let b): return b ? 1 : 0
        case .number(let d): return d
        case .string(let s): return stringToNumber(s)
        case .array(let a):
            // ToPrimitive on an array is its join(","), then ToNumber on that.
            if a.isEmpty { return 0 }           // Number([]) === 0
            if a.count == 1 { return number(a[0]) }
            return .nan                         // Number([1,2]) === NaN
        case .object: return .nan               // "[object Object]" → NaN
        }
    }

    /// `Number(v) || 0` — the single most common shape in normalize(). Folds NaN
    /// and every falsy result onto 0.
    public static func numberOrZero(_ v: JSONValue) -> Double {
        let n = number(v)
        return (n.isNaN || n == 0) ? 0 : n
    }

    /// `Number(v) || fallback`, for `readCount`, where 0 must become 1.
    public static func numberOr(_ v: JSONValue, _ fallback: Double) -> Double {
        let n = number(v)
        return (n.isNaN || n == 0) ? fallback : n
    }

    /// String → number following JS: surrounding whitespace is ignored, an empty
    /// or all-whitespace string is 0, and anything unparseable is NaN. Note that
    /// unlike `Double("12abc")`, JS rejects trailing garbage outright.
    private static func stringToNumber(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }               // Number("") === 0, Number("  ") === 0
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }
        let lower = s.lowercased()
        if lower.hasPrefix("0x") || lower.hasPrefix("0b") || lower.hasPrefix("0o") {
            let radix = lower.hasPrefix("0x") ? 16 : (lower.hasPrefix("0b") ? 2 : 8)
            guard let i = UInt64(s.dropFirst(2), radix: radix) else { return .nan }
            return Double(i)
        }
        // Swift's Double(String) rejects trailing garbage too, but it accepts
        // forms JS does not ("1_000", "0x1p3", "nan", "inf"). Screen first.
        guard s.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else {
            return .nan
        }
        return Double(s) ?? .nan
    }

    // MARK: - ToString

    /// `String(v)`. Needed because tags and collections are run through
    /// `String(t).trim()`, so a stray number or null in the array becomes text
    /// rather than being dropped.
    public static func string(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return numberToString(d)
        case .string(let s): return s
        case .array(let a):
            // Array#join renders null and undefined as empty strings.
            return a.map { $0.isNull ? "" : string($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// JS number formatting: integers print without a decimal point, so a tag of
    /// `5` becomes `"5"` and not Swift's default `"5.0"`.
    public static func numberToString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e21 {
            return String(Int64(d))
        }
        return shortestRepresentation(d)
    }

    private static func shortestRepresentation(_ d: Double) -> String {
        // Shortest string that round-trips, matching what JS prints for the
        // non-integral values a bookshelf actually holds (ratings like 4.5).
        for precision in 1...17 {
            let s = String(format: "%.\(precision)g", d)
            if Double(s) == d { return s }
        }
        return String(d)
    }

    // MARK: - Field readers

    /// `obj.key || fallback` for string fields — the workhorse of normalize().
    /// Falsy means fallback, so `""`, `0`, `false` and `null` all take it.
    ///
    /// The fallback is an autoclosure because `||` short-circuits: `b.id || uid()`
    /// does not mint an id when one is already there. Evaluating it eagerly would
    /// burn a UUID per book — invisible in production, but it desynchronises the
    /// id sequence from the JavaScript and breaks the golden comparison.
    ///
    /// **Known deviation.** JavaScript assigns the *raw* value here, with no
    /// `String()` around it, so `{"title": 12}` normalizes to the number `12`
    /// over there and to `"12"` here. Only non-string input reaches it, the app
    /// itself never writes one, and both clients display the same text — so this
    /// is accepted rather than dragging every string field into `JSONValue`.
    /// `NormalizerGoldenTests` applies the same coercion to the expected side and
    /// names the fields, so the deviation is asserted rather than assumed.
    public static func stringOr(_ v: JSONValue, _ fallback: @autoclosure () -> String) -> String {
        truthy(v) ? string(v) : fallback()
    }

    /// `obj.key || null` for optional ISO-date strings (`startedAt`, `lentAt`, …).
    public static func stringOrNil(_ v: JSONValue) -> String? {
        truthy(v) ? string(v) : nil
    }

    /// `v ? Number(v) : null` — used for `rating`, `publishedYear`, `expectation`.
    /// A stored 0 becomes nil here, which is intentional in the source: a rating
    /// of zero stars is how the web app spells "unrated".
    public static func numberIfTruthy(_ v: JSONValue) -> Double? {
        guard truthy(v) else { return nil }
        let n = number(v)
        return n.isNaN ? nil : n            // NaN would serialize to null anyway
    }

    /// `v != null ? Number(v) : null` — keeps a genuine 0. Quote pages use this,
    /// so `"page": ""` becomes 0 rather than nil.
    public static func numberIfNotNull(_ v: JSONValue) -> Double? {
        guard !v.isNull else { return nil }
        let n = number(v)
        return n.isNaN ? nil : n
    }

    /// `v != null && v !== "" ? Number(v) : null` — journal, vocab and bookmark
    /// pages, and `seriesNumber`. Same as above but an empty string is absent
    /// rather than 0.
    public static func numberIfNotNullOrEmpty(_ v: JSONValue) -> Double? {
        if v.isNull { return nil }
        if case .string(let s) = v, s.isEmpty { return nil }
        let n = number(v)
        return n.isNaN ? nil : n
    }
}
