import Foundation
import Observation

/// One imported book: where the file is, how far through you are, and what you
/// marked in it.
///
/// The ePub file itself is stored as-is on disk; this is the sidecar. Keeping
/// progress and highlights *out* of the archive matters — a book file stays
/// byte-identical to what the user imported, so it can be replaced, re-shared or
/// opened by anything else without carrying our annotations around inside it.
public struct EPUBRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// Filename inside the library directory, not a full path — the container
    /// path changes on every install and an absolute URL would go stale.
    public var filename: String
    public var title: String
    public var author: String
    public var addedAt: String
    public var lastOpenedAt: String?

    public var chapter: Int
    /// 0…1 within the current chapter.
    public var chapterProgress: Double
    /// 0…1 through the whole book, for the shelf.
    public var progress: Double

    /// The shelf book this ePub is attached to, so reading it logs sessions.
    public var linkedBookID: String?

    /// Seconds of *active* reading, and the characters-per-minute learned from
    /// them. Together they give the "time left" estimate.
    public var activeSeconds: Double
    public var charactersPerMinute: Double?
    /// Character count per chapter, cached — computing it means decompressing
    /// and stripping every chapter, which is far too slow to redo on each open.
    public var chapterCharacters: [Int]?

    public var bookmarks: [Bookmark]
    public var highlights: [Highlight]

    public struct Bookmark: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var chapter: Int
        public var progress: Double
        public var label: String
        public var snippet: String
        public var addedAt: String
    }

    /// Character offsets into the chapter's *stripped text*, not pixels or DOM
    /// paths — that is what lets a highlight survive a font-size change, a theme
    /// switch or a different screen, where every pixel moves but the text
    /// doesn't.
    public struct Highlight: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var chapter: Int
        public var start: Int
        public var end: Int
        public var text: String
        public var addedAt: String

        public init(id: String, chapter: Int, start: Int = 0, end: Int = 0, text: String, addedAt: String) {
            self.id = id
            self.chapter = chapter
            self.start = start
            self.end = end
            self.text = text
            self.addedAt = addedAt
        }

        // Older records predate the offsets; decode them as a zero range so an
        // upgrade doesn't throw away the highlight's text.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            chapter = (try? c.decode(Int.self, forKey: .chapter)) ?? 0
            start = (try? c.decode(Int.self, forKey: .start)) ?? 0
            end = (try? c.decode(Int.self, forKey: .end)) ?? 0
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            addedAt = (try? c.decode(String.self, forKey: .addedAt)) ?? ""
        }
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        filename: String,
        title: String,
        author: String,
        addedAt: String = ISO8601.string(from: Date()),
        lastOpenedAt: String? = nil,
        chapter: Int = 0,
        chapterProgress: Double = 0,
        progress: Double = 0,
        linkedBookID: String? = nil,
        activeSeconds: Double = 0,
        charactersPerMinute: Double? = nil,
        chapterCharacters: [Int]? = nil,
        bookmarks: [Bookmark] = [],
        highlights: [Highlight] = []
    ) {
        self.id = id
        self.filename = filename
        self.title = title
        self.author = author
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.chapter = chapter
        self.chapterProgress = chapterProgress
        self.progress = progress
        self.linkedBookID = linkedBookID
        self.activeSeconds = activeSeconds
        self.charactersPerMinute = charactersPerMinute
        self.chapterCharacters = chapterCharacters
        self.bookmarks = bookmarks
        self.highlights = highlights
    }

    public var totalCharacters: Int { (chapterCharacters ?? []).reduce(0, +) }
}

/// The imported ePubs and their sidecar index.
///
/// Files live in `Application Support/epubs/`, not `Documents`: with file sharing
/// on, Documents is browsable in the Files app, and a user deleting what looks
/// like a stray file would silently destroy a book they are halfway through.
@Observable
@MainActor
public final class EPUBLibrary {

    public private(set) var books: [EPUBRecord] = []
    public private(set) var lastError: String?

    private let directory: URL
    private let indexURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? {
            let support = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL.temporaryDirectory
            return support.appending(path: "epubs")
        }()
        self.directory = base
        self.indexURL = base.appending(path: "index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    public func fileURL(for record: EPUBRecord) -> URL {
        directory.appending(path: record.filename)
    }

    public func record(id: String) -> EPUBRecord? { books.first { $0.id == id } }

    // MARK: - Import

    @discardableResult
    public func `import`(from source: URL) throws -> EPUBRecord {
        // A file picked from Files or iCloud lives outside the sandbox until
        // it's copied in.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return try `import`(data: try Data(contentsOf: source), suggestedName: source.lastPathComponent)
    }

    @discardableResult
    public func `import`(data: Data, suggestedName: String) throws -> EPUBRecord {
        // Parsed before it's stored: an unreadable file should be refused at the
        // moment of import, while the user still knows which file they picked —
        // not silently at some later open.
        let package = try EPUBPackage(data: data)

        let id = UUID().uuidString.lowercased()
        let filename = "\(id).epub"
        try data.write(to: directory.appending(path: filename), options: [.atomic])

        var record = EPUBRecord(
            id: id,
            filename: filename,
            title: package.title.isEmpty ? Self.titleFromFilename(suggestedName) : package.title,
            author: package.author
        )
        record.chapterCharacters = nil     // computed lazily on first open
        books.insert(record, at: 0)
        save()
        return record
    }

    public func update(_ record: EPUBRecord) {
        guard let i = books.firstIndex(where: { $0.id == record.id }) else { return }
        books[i] = record
        save()
    }

    public func delete(id: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        let record = books[i]
        try? FileManager.default.removeItem(at: fileURL(for: record))
        books.remove(at: i)
        save()
    }

    /// Open the archive behind a record.
    public func open(_ record: EPUBRecord) throws -> EPUBPackage {
        try EPUBPackage(archive: ZipArchive(url: fileURL(for: record)))
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            books = try JSONDecoder().decode([EPUBRecord].self, from: Data(contentsOf: indexURL))
            // Drop entries whose file has gone — a restore or a failed write can
            // leave the index describing books that aren't there, and a row that
            // errors on every tap is worse than no row.
            let missing = books.filter { !FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            if !missing.isEmpty {
                books.removeAll { record in missing.contains { $0.id == record.id } }
                save()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(books).write(to: indexURL, options: [.atomic])
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func titleFromFilename(_ name: String) -> String {
        let stem = name.replacingOccurrences(of: ".epub", with: "", options: [.caseInsensitive, .anchored, .backwards])
        return stem.isEmpty ? "Untitled book" : stem
    }
}
