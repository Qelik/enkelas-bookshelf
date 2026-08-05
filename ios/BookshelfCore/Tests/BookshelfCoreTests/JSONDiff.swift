import Foundation
@testable import BookshelfCore

/// A structural JSON diff that reports *where* two values disagree.
///
/// Comparing two 90KB blobs with `#expect(a == b)` tells you they differ and
/// nothing else, which is useless when the question is "which of forty fields
/// did the port get wrong". This walks both sides and names the path.
enum JSONDiff {

    struct Difference: CustomStringConvertible {
        let path: String
        let expected: String
        let actual: String

        var description: String { "\(path): expected \(expected), got \(actual)" }
    }

    static func compare(expected: JSONValue, actual: JSONValue, path: String = "") -> [Difference] {
        switch (expected, actual) {
        case (.null, .null), (.null, _), (_, .null):
            if case .null = expected, case .null = actual { return [] }
            return [Difference(path: label(path), expected: describe(expected), actual: describe(actual))]

        case (.bool(let a), .bool(let b)):
            return a == b ? [] : [Difference(path: label(path), expected: "\(a)", actual: "\(b)")]

        case (.number(let a), .number(let b)):
            // Both sides came through a JSON round trip, so this is comparing
            // decoded doubles rather than text — no epsilon needed, and an
            // epsilon would hide a genuine coercion bug.
            return a == b ? [] : [Difference(path: label(path), expected: JS.numberToString(a), actual: JS.numberToString(b))]

        case (.string(let a), .string(let b)):
            return a == b ? [] : [Difference(path: label(path), expected: "\"\(a)\"", actual: "\"\(b)\"")]

        case (.array(let a), .array(let b)):
            if a.count != b.count {
                return [Difference(path: label(path), expected: "\(a.count) items", actual: "\(b.count) items")]
            }
            return zip(a, b).enumerated().flatMap { i, pair in
                compare(expected: pair.0, actual: pair.1, path: "\(path)[\(i)]")
            }

        case (.object(let a), .object(let b)):
            var out: [Difference] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                let sub = path.isEmpty ? key : "\(path).\(key)"
                switch (a[key], b[key]) {
                case (nil, .some(let v)):
                    out.append(Difference(path: sub, expected: "<key absent>", actual: describe(v)))
                case (.some(let v), nil):
                    out.append(Difference(path: sub, expected: describe(v), actual: "<key absent>"))
                case (.some(let e), .some(let c)):
                    out += compare(expected: e, actual: c, path: sub)
                case (nil, nil):
                    break
                }
            }
            return out

        default:
            return [Difference(path: label(path), expected: describe(expected), actual: describe(actual))]
        }
    }

    private static func label(_ path: String) -> String { path.isEmpty ? "<root>" : path }

    private static func describe(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .number(let d): return JS.numberToString(d)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "array(\(a.count))"
        case .object(let o): return "object(\(o.count) keys)"
        }
    }
}
