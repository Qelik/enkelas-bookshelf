import Foundation
import Testing
@testable import BookshelfCore

/// The reading clock. Every rule here exists because the alternative produces a
/// number the reader can see is wrong — an hour of "reading" while the book sat
/// on a table, or a finish estimate built on a speed nobody reads at.
struct ReadingSessionTests {

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("time only counts while the reader is actually interacting")
    func idleTimeIsNotReadingTime() {
        var session = ReadingSession()
        session.markActivity(at: Self.t0)

        // A minute of steady reading.
        session.tick(at: Self.t0.addingTimeInterval(30))
        session.markActivity(at: Self.t0.addingTimeInterval(30))
        session.tick(at: Self.t0.addingTimeInterval(60))
        #expect(session.activeSeconds == 60)

        // Then the book goes down. Ticks keep arriving; none of them count once
        // the idle timeout has passed.
        session.tick(at: Self.t0.addingTimeInterval(150))   // 90s later, within timeout at first
        let afterIdle = session.activeSeconds
        session.tick(at: Self.t0.addingTimeInterval(3600))  // an hour on the table
        #expect(session.activeSeconds == afterIdle, "an hour untouched must not become an hour read")
        #expect(session.activeSeconds < 200)
    }

    @Test("a long gap starts a new session rather than extending the old one")
    func longGapStartsFresh() {
        var session = ReadingSession()
        session.markActivity(at: Self.t0)
        session.tick(at: Self.t0.addingTimeInterval(60))
        session.markActivity(at: Self.t0.addingTimeInterval(60))
        session.countPage(characters: 2000, at: Self.t0.addingTimeInterval(60))
        #expect(session.activeSeconds > 0)
        #expect(session.charactersRead == 2000)

        // Picked up again the next morning.
        let isNew = session.markActivity(at: Self.t0.addingTimeInterval(60 * 60 * 12))
        #expect(isNew)
        #expect(session.activeSeconds == 0, "yesterday's sitting is not part of today's")
        #expect(session.charactersRead == 0)
    }

    @Test("a short pause is the same session")
    func shortGapContinues() {
        var session = ReadingSession()
        session.markActivity(at: Self.t0)
        session.countPage(characters: 1000, at: Self.t0)
        // Put down for five minutes — a cup of tea, not a new sitting.
        let isNew = session.markActivity(at: Self.t0.addingTimeInterval(300))
        #expect(!isNew)
        #expect(session.charactersRead == 1000)
    }

    @Test("a speed is only learned once there's enough evidence")
    func speedNeedsEvidence() {
        var session = ReadingSession()
        session.markActivity(at: Self.t0)

        // Thirty seconds of flicking through. Extrapolating from this would
        // "learn" a speed of thousands a minute and poison every later estimate.
        session.countPage(characters: 3000, at: Self.t0.addingTimeInterval(10))
        session.tick(at: Self.t0.addingTimeInterval(30))
        #expect(session.measuredCharactersPerMinute == nil)

        // Ten minutes of real reading at a plausible pace.
        var real = ReadingSession()
        real.markActivity(at: Self.t0)
        for minute in 1...10 {
            let at = Self.t0.addingTimeInterval(Double(minute) * 60)
            real.countPage(characters: 1200, at: at)
            real.tick(at: at)
        }
        let rate = try? #require(real.measuredCharactersPerMinute)
        #expect(rate != nil)
        if let rate { #expect(rate > 900 && rate < 1500, "got \(rate)") }
    }

    @Test("an implausible speed is discarded rather than stored")
    func absurdSpeedsRejected() {
        var session = ReadingSession()
        session.markActivity(at: Self.t0)
        // Two minutes, a million characters — someone scrubbed the slider.
        session.countPage(characters: 1_000_000, at: Self.t0.addingTimeInterval(60))
        session.tick(at: Self.t0.addingTimeInterval(120))
        #expect(session.measuredCharactersPerMinute == nil)
    }

    @Test("a new measurement adjusts the stored pace without replacing it")
    func speedIsBlended() {
        // One unusually fast chapter shouldn't rewrite the estimate; a genuine
        // change should still show up over a few sittings.
        let blended = try? #require(ReadingSession.blend(stored: 1000, measured: 2000))
        #expect(blended == 1300)
        #expect(ReadingSession.blend(stored: nil, measured: 1500) == 1500)
        #expect(ReadingSession.blend(stored: 1200, measured: nil) == 1200)
        #expect(ReadingSession.blend(stored: nil, measured: nil) == nil)
    }

    @Test("time left reads like something a person would say")
    func timeLeftPhrasing() {
        // 12000 characters at the default 1000/min.
        #expect(ReadingSession.timeLeftDescription(characters: 12000, at: nil) == "about 12 min left")
        #expect(ReadingSession.timeLeftDescription(characters: 60000, at: nil) == "about 1 hr left")
        #expect(ReadingSession.timeLeftDescription(characters: 65000, at: nil) == "about 1 hr 5 min left")
        // A faster reader gets a shorter estimate for the same book.
        #expect(ReadingSession.timeLeftDescription(characters: 12000, at: 2000) == "about 6 min left")
        // Nothing useful to say about the last few seconds of a chapter.
        #expect(ReadingSession.timeLeftDescription(characters: 100, at: nil) == nil)
        #expect(ReadingSession.timeLeftDescription(characters: 0, at: nil) == nil)
    }
}

@MainActor
struct EPUBLibraryTests {

    static func makeLibrary() -> (EPUBLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "epub-tests-\(UUID().uuidString)")
        return (EPUBLibrary(directory: dir), dir)
    }

    @Test("importing stores the file and reads its metadata")
    func importsABook() throws {
        let (library, dir) = Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try library.import(data: try EPUBTests.fixture("sample-epub3"), suggestedName: "whatever.epub")

        #expect(record.title == "A Test Book")
        #expect(record.author == "Quill Marlow")
        #expect(library.books.count == 1)
        #expect(FileManager.default.fileExists(atPath: library.fileURL(for: record).path))

        // And it can be reopened from what was stored.
        let package = try library.open(record)
        #expect(package.spine.count == 3)
    }

    @Test("a file that isn't a book is refused at import, not at open")
    func rejectsBadFileEarly() throws {
        // The moment to say "that isn't an ePub" is while the user still
        // remembers which file they picked — not at some later tap.
        let (library, dir) = Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ZipArchive.Failure.self) {
            try library.import(data: Data("not a book".utf8), suggestedName: "notes.epub")
        }
        #expect(library.books.isEmpty)
        // Nothing was written for a file that was never valid.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!contents.contains { $0.hasSuffix(".epub") })
    }

    @Test("progress and highlights survive a restart")
    func persistsAcrossLaunches() throws {
        let (library, dir) = Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = try library.import(data: try EPUBTests.fixture("sample-epub3"), suggestedName: "book.epub")
        record.chapter = 2
        record.chapterProgress = 0.42
        record.progress = 0.71
        record.activeSeconds = 900
        record.charactersPerMinute = 1150
        record.highlights = [.init(id: "h1", chapter: 1, text: "the quick brown fox",
                                   addedAt: ISO8601.string(from: Date()))]
        library.update(record)

        let reopened = EPUBLibrary(directory: dir)
        let restored = try #require(reopened.books.first)
        #expect(restored.chapter == 2)
        #expect(restored.chapterProgress == 0.42)
        #expect(restored.activeSeconds == 900)
        #expect(restored.charactersPerMinute == 1150)
        #expect(restored.highlights.first?.text == "the quick brown fox")
    }

    @Test("a book whose file has vanished is dropped from the list")
    func forgetsMissingFiles() throws {
        // A restore or a failed write can leave the index describing books that
        // aren't there. A row that errors on every tap is worse than no row.
        let (library, dir) = Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try library.import(data: try EPUBTests.fixture("sample-epub3"), suggestedName: "book.epub")
        try FileManager.default.removeItem(at: library.fileURL(for: record))

        let reopened = EPUBLibrary(directory: dir)
        #expect(reopened.books.isEmpty)
    }

    @Test("deleting removes the file as well as the row")
    func deleteRemovesTheFile() throws {
        let (library, dir) = Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try library.import(data: try EPUBTests.fixture("sample-epub3"), suggestedName: "book.epub")
        let path = library.fileURL(for: record).path
        library.delete(id: record.id)

        #expect(library.books.isEmpty)
        // Otherwise a deleted library quietly keeps using the disk.
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
