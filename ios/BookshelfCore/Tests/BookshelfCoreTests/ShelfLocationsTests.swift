import Foundation
import Testing
@testable import BookshelfCore

/// Named places on real shelves. The failure this guards against is a picker
/// that offers three spellings of the same room, which is how the feature stops
/// being usable after a fortnight.
struct ShelfLocationsTests {

    static func book(_ id: String, _ title: String, location: String = "", owned: Bool = false) -> WireBook {
        var b = Fixture.book(id: id, title: title, status: .finished)
        b.location = location
        b.owned = owned
        return b
    }

    static func shelf(_ books: [WireBook]) -> WireState {
        WireState(
            version: 1, updatedAt: "2026-08-13T00:00:00.000Z",
            settings: WireSettings(goal: [:]), shelfOrder: [], books: books
        )
    }

    @Test("shelves group case- and accent-insensitively, keeping the first spelling")
    func groupingIsForgiving() throws {
        // Typed by hand across months, so the same shelf arrives spelled three
        // ways. Three entries in the list would make the feature useless.
        let state = Self.shelf([
            Self.book("1", "A", location: "Living room", owned: true),
            Self.book("2", "B", location: "living room", owned: true),
            Self.book("3", "C", location: "  LIVING ROOM  ", owned: true),
            Self.book("4", "D", location: "Bedroom", owned: true),
        ])
        let places = state.shelfLocations
        #expect(places.count == 2)
        let living = try #require(places.first { $0.name == "Living room" })
        #expect(living.count == 3, "all three spellings are one shelf")
        #expect(places.map(\.name) == ["Bedroom", "Living room"], "sorted by name")
    }

    @Test("looking up a shelf finds every spelling of it")
    func lookupMatchesTheGroup() {
        let state = Self.shelf([
            Self.book("1", "A", location: "Étagère", owned: true),
            Self.book("2", "B", location: "etagere", owned: true),
        ])
        #expect(state.books(atLocation: "ETAGERE").count == 2)
        #expect(state.books(atLocation: "").isEmpty, "an empty name is not a shelf")
    }

    @Test("books you own but haven't placed are surfaced, not hidden")
    func unplacedPile() {
        // The work left to do. A feature that only shows the tidy part is no use
        // to somebody who hasn't started.
        let state = Self.shelf([
            Self.book("1", "Placed", location: "Bedroom", owned: true),
            Self.book("2", "Unplaced", owned: true),
            Self.book("3", "Not owned at all"),
        ])
        #expect(state.booksWithoutLocation.map(\.id) == ["2"])
    }

    @MainActor
    @Test("putting a book on a shelf marks it owned")
    func placingImpliesOwning() {
        // A book on a shelf in your house is a book you have. Without this the
        // Owned filter and the shop scanner disagree with the shelf you just
        // put it on.
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.books = [Self.book("1", "A")] }
        store.setLocation(bookID: "1", to: "Hallway")
        #expect(store.state.books[0].location == "Hallway")
        #expect(store.state.books[0].owned)
    }

    @MainActor
    @Test("clearing a location leaves the book owned")
    func takingItOffAShelfIsNotGivingItAway() {
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.books = [Self.book("1", "A", location: "Hallway", owned: true)] }
        store.setLocation(bookID: "1", to: "   ")
        #expect(store.state.books[0].location.isEmpty)
        #expect(store.state.books[0].owned, "you still own it, you just haven't said where")
    }

    @MainActor
    @Test("renaming a shelf moves everything on it")
    func renameMovesTheWholeShelf() {
        // Editing one book at a time would leave the other twenty on a place
        // that no longer exists — which is how "Bedroom" and "Bedroom shelf"
        // end up side by side.
        let store = BookshelfStore(storage: .inMemory())
        store.commit {
            $0.books = [
                Self.book("1", "A", location: "Bedroom", owned: true),
                Self.book("2", "B", location: "bedroom", owned: true),
                Self.book("3", "C", location: "Kitchen", owned: true),
            ]
        }
        store.renameLocation(from: "BEDROOM", to: "Bedroom, top shelf")
        #expect(store.state.books(atLocation: "Bedroom, top shelf").count == 2)
        #expect(store.state.books(atLocation: "Kitchen").count == 1)
        #expect(store.state.shelfLocations.count == 2)
    }

    @MainActor
    @Test("a batch move puts every named book on the shelf and leaves the rest")
    func batchMove() {
        let store = BookshelfStore(storage: .inMemory())
        store.commit {
            $0.books = [Self.book("1", "A"), Self.book("2", "B"), Self.book("3", "C")]
        }
        store.setLocation(bookIDs: ["1", "3"], to: "Study")
        #expect(store.state.books(atLocation: "Study").map(\.id) == ["1", "3"])
        #expect(store.state.books[1].location.isEmpty)
    }
}
