import Foundation

/// Reading and writing the blob, in exactly the form the sync endpoint and the
/// `⬇ Export` file use.
public extension WireState {

    /// Decode without normalizing. Almost always the wrong call on untrusted
    /// input — an export written by an older build can be missing fields this
    /// type requires, and decoding will throw where `normalize()` would heal.
    /// Prefer `Normalizer.normalize(data:)`.
    static func decodeStrict(from data: Data) throws -> WireState {
        try JSONDecoder().decode(WireState.self, from: data)
    }

    /// The bytes to PUT or export.
    ///
    /// Keys are sorted, which the web app does not do — but JSON object order
    /// carries no meaning, both sides parse either form, and a stable order makes
    /// two exports diffable. `withoutEscapingSlashes` keeps cover URLs readable
    /// rather than littered with `\/`.
    func encodedJSON(prettyPrinted: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// The wrapper the app's own export file uses (`⬇ Export` writes the state
/// object directly, so this is currently just the state — kept as a named entry
/// point so the import path has one obvious place to grow if that changes).
public enum BookshelfImport {

    public enum Failure: LocalizedError {
        case notJSON(underlying: Error)
        case notABookshelf

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                return "That file isn't valid JSON. Pick the file you got from ⬇ Export."
            case .notABookshelf:
                return "That JSON doesn't look like a bookshelf — no books in it."
            }
        }
    }

    /// Read an exported bookshelf. Runs the file through `normalize()`, so a file
    /// written by any version of the web app is accepted and healed the same way
    /// the web app would heal it.
    public static func read(_ data: Data, using normalizer: Normalizer = Normalizer()) throws -> WireState {
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw Failure.notJSON(underlying: error)
        }
        // A bare `{}` normalizes happily into an empty shelf, which would import
        // as "0 books" and look like success. Require the key to exist, so
        // picking the wrong file says so.
        guard case .object(let o) = raw, o["books"] != nil else {
            throw Failure.notABookshelf
        }
        return normalizer.normalize(raw)
    }
}
