import Compression
import Foundation

/// A read-only ZIP reader, scoped to what EPUB actually uses.
///
/// EPUB is a ZIP with an XML manifest, so something has to open one. The options
/// were a third-party archive library or this; this won because `BookshelfCore`
/// has no dependencies and the subset needed is small and rigidly specified —
/// stored and deflate entries, no encryption, no spanning. Inflating is
/// Apple's `Compression`, so the only real work here is walking the central
/// directory.
///
/// Entries are read individually and on demand. A 40MB illustrated book should
/// not have to be decompressed in full to turn one page.
public struct ZipArchive: Sendable {

    public struct Entry: Sendable, Hashable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let method: UInt16
        let localHeaderOffset: Int

        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public enum Failure: LocalizedError, Equatable {
        case notAZip
        case unsupportedCompression(UInt16)
        case entryNotFound(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip:
                "That file isn't an ePub — it doesn't look like a ZIP archive."
            case .unsupportedCompression(let m):
                "This ePub uses a compression method we can't read (method \(m))."
            case .entryNotFound(let p):
                "The ePub is missing a file it says it has (\(p))."
            case .corrupt(let why):
                "This ePub looks damaged: \(why)"
            }
        }
    }

    private let data: Data
    public let entries: [String: Entry]

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public init(url: URL) throws {
        // Mapped rather than loaded: books are big and most of a book is never
        // read in a given session.
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func contains(_ path: String) -> Bool { entries[path] != nil }

    /// Decompress one entry.
    public func read(_ path: String) throws -> Data {
        guard let entry = entries[path] else { throw Failure.entryNotFound(path) }
        return try read(entry)
    }

    public func read(_ entry: Entry) throws -> Data {
        // The local header repeats the name and extra fields, and their lengths
        // can differ from the central directory's — so the payload offset has to
        // be computed from the local header, not assumed.
        let head = entry.localHeaderOffset
        guard head >= 0, head + 30 <= data.count else { throw Failure.corrupt("local header out of range") }
        guard read32(at: head) == 0x0403_4b50 else { throw Failure.corrupt("bad local header signature") }
        let nameLength = Int(read16(at: head + 26))
        let extraLength = Int(read16(at: head + 28))
        let start = head + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw Failure.corrupt("entry runs past end of file") }

        let payload = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expecting: entry.uncompressedSize)
        default:
            throw Failure.unsupportedCompression(entry.method)
        }
    }

    /// Raw DEFLATE. `COMPRESSION_ZLIB` in Apple's framework is the raw stream, not
    /// the zlib-wrapped one, which is exactly what ZIP method 8 stores.
    private func inflate(_ input: Data, expecting size: Int) throws -> Data {
        // A zero-length file is legal and `compression_decode_buffer` reports it
        // the same way it reports failure.
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(outBase, size, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else {
            throw Failure.corrupt("a compressed file didn't unpack to its stated size")
        }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard data.count > 22 else { throw Failure.notAZip }
        guard let eocd = findEOCD(data) else { throw Failure.notAZip }

        var count = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))

        // Zip64. The 32-bit fields saturate at 0xFFFF/0xFFFFFFFF and the real
        // values live in a separate record — rare for a novel, ordinary for a
        // big illustrated book.
        if count == 0xFFFF || offset == 0xFFFF_FFFF {
            guard let locator = findZip64Locator(data, before: eocd) else {
                throw Failure.corrupt("zip64 archive with no locator")
            }
            let zip64 = Int(read64(data, locator + 8))
            guard zip64 >= 0, zip64 + 56 <= data.count, read32(data, zip64) == 0x0606_4b50 else {
                throw Failure.corrupt("bad zip64 end-of-directory record")
            }
            count = Int(read64(data, zip64 + 32))
            offset = Int(read64(data, zip64 + 48))
        }

        var entries: [String: Entry] = [:]
        var cursor = offset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, read32(data, cursor) == 0x0201_4b50 else {
                throw Failure.corrupt("bad central directory entry")
            }
            let method = read16(data, cursor + 10)
            var compressed = Int(read32(data, cursor + 20))
            var uncompressed = Int(read32(data, cursor + 24))
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            var localOffset = Int(read32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw Failure.corrupt("truncated entry name") }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLength
                readZip64Extra(
                    data, from: extraStart, length: extraLength,
                    uncompressed: &uncompressed, compressed: &compressed, localOffset: &localOffset
                )
            }

            if !name.hasSuffix("/") {
                entries[name] = Entry(
                    path: name,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    method: method,
                    localHeaderOffset: localOffset
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The end-of-directory record sits last, but a trailing comment can push it
    /// up to 64KB from the end, so it has to be searched for backwards.
    private static func findEOCD(_ data: Data) -> Int? {
        let maxComment = 0xFFFF
        let lowest = max(0, data.count - maxComment - 22)
        var i = data.count - 22
        while i >= lowest {
            if read32(data, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func findZip64Locator(_ data: Data, before eocd: Int) -> Int? {
        let candidate = eocd - 20
        guard candidate >= 0, read32(data, candidate) == 0x0706_4b50 else { return nil }
        return candidate
    }

    /// Extra fields are a sequence of (id, size, payload). The zip64 one (0x0001)
    /// carries only the fields that actually overflowed, in a fixed order.
    private static func readZip64Extra(
        _ data: Data, from start: Int, length: Int,
        uncompressed: inout Int, compressed: inout Int, localOffset: inout Int
    ) {
        var cursor = start
        let end = min(start + length, data.count)
        while cursor + 4 <= end {
            let id = read16(data, cursor)
            let size = Int(read16(data, cursor + 2))
            let payload = cursor + 4
            guard payload + size <= end else { return }
            if id == 0x0001 {
                var p = payload
                if uncompressed == 0xFFFF_FFFF, p + 8 <= payload + size { uncompressed = Int(read64(data, p)); p += 8 }
                if compressed == 0xFFFF_FFFF, p + 8 <= payload + size { compressed = Int(read64(data, p)); p += 8 }
                if localOffset == 0xFFFF_FFFF, p + 8 <= payload + size { localOffset = Int(read64(data, p)) }
                return
            }
            cursor = payload + size
        }
    }

    // MARK: - Little-endian reads

    private func read16(at i: Int) -> UInt16 { Self.read16(data, i) }
    private func read32(at i: Int) -> UInt32 { Self.read32(data, i) }

    private static func read16(_ d: Data, _ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + i]) | UInt16(d[d.startIndex + i + 1]) << 8
    }

    private static func read32(_ d: Data, _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= d.count else { return 0 }
        var v: UInt32 = 0
        for b in (0..<4).reversed() { v = v << 8 | UInt32(d[d.startIndex + i + b]) }
        return v
    }

    private static func read64(_ d: Data, _ i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= d.count else { return 0 }
        var v: UInt64 = 0
        for b in (0..<8).reversed() { v = v << 8 | UInt64(d[d.startIndex + i + b]) }
        return v
    }
}
