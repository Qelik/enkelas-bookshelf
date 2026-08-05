import Foundation
import Testing
@testable import BookshelfCore

/// Hits the real Open Library. Disabled by default — a test that needs the
/// network fails on a train and tells you nothing about your code. Run with
/// BOOKSHELF_LIVE=1 when changing the lookup waterfall.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BOOKSHELF_LIVE"] == "1"))
struct LiveLookupTests {

    @Test("a well-known title comes back with a cover")
    func findsAClassic() async throws {
        let docs = try await OpenLibrary().search(title: "Wuthering Heights")
        #expect(!docs.isEmpty, "Open Library returned nothing for a book it certainly has")
        let first = try #require(docs.first)
        print("first hit:", first.title ?? "?", "|", first.authorLine, "|", first.coverURL?.absoluteString ?? "no cover")
        #expect(first.coverURL != nil)
    }
}
