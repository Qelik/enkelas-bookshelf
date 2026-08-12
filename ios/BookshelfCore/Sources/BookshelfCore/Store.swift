import Foundation
import Observation

/// The shelf, in memory and on disk.
///
/// Mirrors `commit()` in the web app: every mutation stamps `updatedAt` and
/// persists. `updatedAt` is not decoration — it is what the sync endpoint's
/// optimistic concurrency compares, so a change that doesn't bump it is a change
/// the server will later refuse or silently overwrite.
@Observable
@MainActor
public final class BookshelfStore {

    public private(set) var state: WireState
    /// Surfaced so the UI can say *why* nothing loaded instead of showing an
    /// empty shelf, which looks identical to "you have no books".
    public private(set) var loadError: String?

    private let storage: ShelfStorage
    private let normalizer: Normalizer
    private var saveTask: Task<Void, Never>?

    public init(storage: ShelfStorage = .applicationSupport(), normalizer: Normalizer = Normalizer()) {
        self.storage = storage
        self.normalizer = normalizer
        do {
            if let data = try storage.read() {
                self.state = normalizer.normalize(try JSONValue.parse(data))
            } else {
                self.state = normalizer.defaultState()
            }
        } catch {
            // Start empty rather than refusing to launch — but keep the reason,
            // because silently starting fresh on top of an unreadable shelf is
            // how a user overwrites the only copy of their library.
            self.state = normalizer.defaultState()
            self.loadError = error.localizedDescription
        }
    }

    // MARK: - Mutation

    /// Called after every committed change. `SyncEngine` sets this to schedule a
    /// push, which is how "every edit eventually reaches the account" is true
    /// without the store knowing what sync is.
    public var onCommit: (() -> Void)?

    /// The single write path. Everything that changes the shelf goes through it,
    /// so there is exactly one place that stamps the clock and schedules a save.
    public func commit(_ mutate: (inout WireState) -> Void) {
        mutate(&state)
        state.updatedAt = ISO8601.string(from: Date())
        scheduleSave()
        onCommit?()
    }

    public func update(book: WireBook) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == book.id }) else { return }
            state.books[i] = book
        }
    }

    public func add(book: WireBook) {
        commit { $0.books.insert(book, at: 0) }
    }

    public func delete(bookID: String) {
        commit { state in
            state.books.removeAll { $0.id == bookID }
            state.shelfOrder.removeAll { $0 == bookID }
        }
    }

    public func setStatus(_ status: BookStatus, for bookID: String, now: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].status = status
            let stamp = ISO8601.string(from: now)
            switch status {
            case .reading:
                // Moving a book to "reading" starts its clock, but only once —
                // re-shelving a book you already started must not erase when you
                // actually began it.
                if state.books[i].startedAt == nil { state.books[i].startedAt = stamp }
                state.books[i].finishedAt = nil
            case .finished:
                if state.books[i].startedAt == nil { state.books[i].startedAt = stamp }
                state.books[i].finishedAt = stamp
            case .want, .dnf:
                break
            }
        }
    }

    public func toggleOwned(bookID: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].owned.toggle()
        }
    }

    /// Log a reading session. `currentPage` is what the form asks for; the stored
    /// value is the delta, matching the web app — storing absolutes would make
    /// every chart wrong the first time someone re-read a chapter.
    public func logSession(
        bookID: String,
        currentPage: Double,
        minutes: Double = 0,
        note: String = "",
        mood: String = "",
        at date: Date = Date()
    ) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let already = state.books[i].pagesRead
            state.books[i].appendSession(
                pages: max(0, currentPage - already),
                minutes: minutes, mood: mood, note: note, at: date
            )
        }
    }

    /// Log a session whose page count is *already* a delta.
    ///
    /// The eReader knows how many pages it turned, not what page of a paper
    /// edition the reader is on — an ePub repaginates with the font size. Routing
    /// it through `logSession` meant passing 0 as "the current page", which the
    /// delta arithmetic dutifully turned into a session of no pages at all.
    public func logReaderSession(
        bookID: String,
        pages: Double,
        minutes: Double,
        note: String = "",
        at date: Date = Date()
    ) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].appendSession(pages: max(0, pages), minutes: minutes, note: note, at: date)
        }
    }

    public func deleteLog(bookID: String, logID: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].logs.removeAll { $0.id == logID }
        }
    }

    /// Replace the whole shelf with something *this device* decided — an import,
    /// or signing out. Stamps a fresh `updatedAt`, because from the server's
    /// point of view this is a new local change it needs to receive.
    public func replace(with incoming: WireState) {
        state = incoming
        state.updatedAt = ISO8601.string(from: Date())
        scheduleSave()
    }

    /// Take the server's copy verbatim, keeping its `updatedAt`.
    ///
    /// Deliberately not `replace(with:)`: `updatedAt` is the optimistic-
    /// concurrency token, and stamping a newer one here would leave this device
    /// looking ahead of the server it just copied from — so the next push would
    /// try to overwrite the very version it had just accepted.
    public func adopt(_ incoming: WireState) {
        state = incoming
        scheduleSave()
    }

    // MARK: - Persistence

    /// Saves are coalesced: typing in a note field would otherwise rewrite the
    /// whole shelf on every keystroke. Short enough that backgrounding the app a
    /// moment later still catches it, via `saveNow()`.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = state
        saveTask = Task { [storage] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: storage)
        }
    }

    /// Flush immediately. Call on `scenePhase == .background` — a coalesced save
    /// that hasn't fired yet dies with the process.
    public func saveNow() async {
        saveTask?.cancel()
        await Self.write(state, to: storage)
    }

    private static func write(_ state: WireState, to storage: ShelfStorage) async {
        await Task.detached(priority: .utility) {
            do {
                try storage.write(try state.encodedJSON(prettyPrinted: true))
            } catch {
                // Nothing useful to do here beyond leaving a trace: the shelf is
                // still intact in memory, and the next mutation will try again.
                print("bookshelf: save failed — \(error)")
            }
        }.value
    }
}

/// Where the shelf lives on disk. A protocol-free struct of closures so tests can
/// hand in an in-memory version without a filesystem.
public struct ShelfStorage: Sendable {
    public var read: @Sendable () throws -> Data?
    public var write: @Sendable (Data) throws -> Void

    public init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    /// `Application Support/bookshelf.json`.
    ///
    /// Not Documents: with `UIFileSharingEnabled` on, Documents is visible in the
    /// Files app, and the live database is not something a user should be able to
    /// rename or delete by accident. Exports go to Documents; the shelf does not.
    public static func applicationSupport(filename: String = "bookshelf.json") -> ShelfStorage {
        let url: URL = {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? URL.temporaryDirectory
            return base.appending(path: filename)
        }()
        return ShelfStorage(
            read: {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            write: { data in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                // Atomic: a crash mid-write must not leave a half-written shelf
                // where a whole one used to be.
                try data.write(to: url, options: [.atomic])
            }
        )
    }

    /// In-memory, for tests and previews.
    public static func inMemory(_ initial: Data? = nil) -> ShelfStorage {
        let box = Box(initial)
        return ShelfStorage(read: { box.value }, write: { box.value = $0 })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        init(_ v: Data?) { stored = v }
        var value: Data? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
}

private extension WireBook {

    /// Append a session and, if it's the first, take the book off the to-read pile.
    ///
    /// Shared by both logging paths. Only the page number differs between them, and
    /// letting the rest drift is how one entry point ends up not starting a book
    /// that the other one does.
    mutating func appendSession(
        pages: Double,
        minutes: Double,
        mood: String = "",
        note: String,
        at date: Date
    ) {
        logs.append(WireReadingLog(
            id: UUID().uuidString.lowercased(),
            date: ISO8601.string(from: date),
            pages: pages,
            minutes: minutes,
            mood: mood,
            note: note
        ))
        if status == .want {
            status = .reading
            if startedAt == nil { startedAt = ISO8601.string(from: date) }
        }
    }
}
