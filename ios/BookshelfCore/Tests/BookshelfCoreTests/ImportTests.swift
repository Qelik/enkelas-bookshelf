import Foundation
import Testing
@testable import BookshelfCore

/// The import path, exercised against the real shared fixture rather than a copy.
///
/// `fixtures/sample-bookshelf.json` is the file both clients agree on: the web
/// app's own `tests.html` reads it, and so does the golden generator. Reading it
/// from the repo — not a duplicate vendored into the test bundle — is what stops
/// the two sides from quietly drifting apart.
struct ImportTests {

    /// Walks up from this source file to the repo root, so the fixture has
    /// exactly one copy and the test breaks loudly if it moves.
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)          // …/ios/BookshelfCore/Tests/BookshelfCoreTests/ImportTests.swift
            .deletingLastPathComponent()         // BookshelfCoreTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // BookshelfCore
            .deletingLastPathComponent()         // ios
            .deletingLastPathComponent()         // repo root
    }()

    static let fixtureURL = repoRoot.appending(path: "fixtures/sample-bookshelf.json")

    @Test("the shared fixture is where both clients expect it")
    func fixtureExists() {
        #expect(FileManager.default.fileExists(atPath: Self.fixtureURL.path),
                "expected the shared fixture at \(Self.fixtureURL.path) — did fixtures/ move?")
    }

    @Test("a real export imports with its books intact")
    func importsTheFixture() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let shelf = try BookshelfImport.read(data)

        #expect(!shelf.books.isEmpty)
        #expect(shelf.version == Normalizer.schemaVersion)
        // Every book comes out with the invariants the rest of the app relies on:
        // an id to key off, a title to show, and a status it can be filtered by.
        for book in shelf.books {
            #expect(!book.id.isEmpty)
            #expect(!book.title.isEmpty)
            #expect(BookStatus.allCases.contains(book.status))
        }
    }

    @Test("an imported shelf can be written back out and re-read unchanged")
    func exportRoundTrips() throws {
        // The phone has to be able to hand a file back to the web app. If this
        // loses a field, "export on the phone, import on the laptop" silently
        // drops data.
        let shelf = try BookshelfImport.read(Data(contentsOf: Self.fixtureURL))
        let written = try shelf.encodedJSON(prettyPrinted: true)
        let reread = try BookshelfImport.read(written)

        let diffs = JSONDiff.compare(
            expected: try JSONValue.from(shelf),
            actual: try JSONValue.from(reread)
        )
        #expect(diffs.isEmpty, "export/import lost \(diffs.count) field(s):\n\(diffs.prefix(10).map(\.description).joined(separator: "\n"))")
    }

    @Test("a strict decode of our own output succeeds")
    func strictDecodeOfOwnOutput() throws {
        // Anything we write must satisfy the typed model without going through
        // normalize() — that is what the sync client will hand the server.
        let shelf = try BookshelfImport.read(Data(contentsOf: Self.fixtureURL))
        let decoded = try WireState.decodeStrict(from: shelf.encodedJSON())
        #expect(decoded == shelf)
    }

    // MARK: - Failure modes

    @Test("a non-JSON file is refused with something a person can act on")
    func rejectsNonJSON() {
        #expect(throws: BookshelfImport.Failure.self) {
            try BookshelfImport.read(Data("this is not json".utf8))
        }
    }

    @Test("valid JSON that isn't a bookshelf is refused rather than imported as empty")
    func rejectsWrongJSON() {
        // The trap this guards: `{}` normalizes happily into an empty shelf, so
        // picking the wrong file would report "imported 0 books" and look like it
        // worked — right after the user tapped a button expecting their library.
        #expect(throws: BookshelfImport.Failure.self) {
            try BookshelfImport.read(Data(#"{"hello":"world"}"#.utf8))
        }
        #expect(throws: BookshelfImport.Failure.self) {
            try BookshelfImport.read(Data("[]".utf8))
        }
    }

    @Test("an empty but genuine bookshelf is accepted")
    func acceptsEmptyShelf() throws {
        let shelf = try BookshelfImport.read(Data(#"{"books":[]}"#.utf8))
        #expect(shelf.books.isEmpty)
    }

    @Test("a Goodreads-era export with missing fields still imports")
    func healsOldExport() throws {
        // No version, no settings, books missing most fields — the shape an early
        // export actually had. normalize() has to fill it in rather than throw.
        let old = #"{"books":[{"title":"Old Book","status":"read","tags":["to-read","Fantasy"]}]}"#
        let shelf = try BookshelfImport.read(Data(old.utf8))
        let book = try #require(shelf.books.first)
        #expect(book.title == "Old Book")
        #expect(book.status == .reading)      // "read" is not a valid status; falls back
        #expect(book.tags == ["Fantasy"])     // the Goodreads shelf name is stripped
        #expect(!book.id.isEmpty)             // an id was minted
        #expect(!book.addedAt.isEmpty)        // …and a timestamp
    }
}
