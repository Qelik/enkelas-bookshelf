import Foundation

/// An arbitrary JSON value.
///
/// The normalizer has to work on *untrusted, arbitrary* JSON — a blob written by
/// an older web build, hand-edited, or half-corrupted — and reproduce what
/// JavaScript does with it, including its coercions. Decoding straight into
/// typed structs would throw on the first `"totalPages": "not a number"` instead
/// of quietly turning it into 0 the way the web app does, so the input side
/// stays untyped and `Normalizer` does the narrowing.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true }; return false }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let d) = self { return d }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Property access that mirrors JS: reading a key off a non-object, or a key
    /// that isn't there, yields `undefined` rather than an error. We have no
    /// separate `undefined`, and `.null` behaves identically everywhere the
    /// normalizer looks at it — except `Number()`, where JS gives `null` 0 and
    /// `undefined` NaN. Nothing in normalize() depends on telling those apart:
    /// every numeric read is either `Number(x) || 0` (both land on 0) or guarded
    /// by a truthiness test first (both are falsy).
    subscript(key: String) -> JSONValue {
        guard case .object(let o) = self else { return .null }
        return o[key] ?? .null
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double: JSONDecoder will happily read `true` as 1.0.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrepresentable JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // JSON has no NaN or Infinity; JSON.stringify emits null for both,
            // and so must we or a golden comparison diverges on exactly the
            // fields the coercion rules are most likely to get wrong.
            if d.isFinite { try c.encode(d) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Conveniences

public extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded(prettyPrinted: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try enc.encode(self)
    }

    /// Round-trip any Encodable through JSON into a comparable value. Used by the
    /// tests to compare a normalized `WireState` against the JavaScript output
    /// structurally, which sidesteps key ordering and `1` vs `1.0` formatting.
    static func from(_ encodable: some Encodable) throws -> JSONValue {
        let enc = JSONEncoder()
        return try JSONDecoder().decode(JSONValue.self, from: enc.encode(encodable))
    }
}
