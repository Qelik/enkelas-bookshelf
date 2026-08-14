import Foundation
import Testing
@testable import BookshelfCore

/// Decorations on the shelf. Both clients rebuild state from a whitelist, so
/// most of what matters here is what survives a round-trip and what doesn't.
struct ShelfObjectTests {

    static func state(objects: [ShelfObject] = [], order: [String] = [], books: [WireBook] = []) -> WireState {
        WireState(
            version: 1, updatedAt: "2026-08-14T00:00:00.000Z",
            settings: WireSettings(goal: [:]), shelfOrder: order,
            books: books, shelfObjects: objects
        )
    }

    // MARK: - Surviving the wire

    @Test("an object survives a round-trip through the normalizer")
    func roundTrip() throws {
        // The whole reason the web app had to change in the same commit: a field
        // neither normalizer knows is a field that silently disappears.
        let json = """
        {"books": [], "shelfObjects": [
          {"id": "o1", "kind": "cat", "tint": 28, "label": ""},
          {"id": "o2", "kind": "bust", "tint": 210, "label": "Plato"}
        ]}
        """
        let state = Normalizer().normalize(try JSONValue.parse(Data(json.utf8)))
        #expect(state.shelfObjects.count == 2)
        #expect(state.shelfObjects[0].kind == .cat)
        #expect(state.shelfObjects[1].label == "Plato")
    }

    @Test("a kind this version doesn't know is dropped, not carried through")
    func unknownKindsAreDropped() throws {
        // Keeping it would make the two clients emit different blobs from the
        // same input, which is the exact failure normalize() exists to prevent.
        let json = #"{"shelfObjects": [{"id":"o1","kind":"hologram"},{"id":"o2","kind":"plant"}]}"#
        let state = Normalizer().normalize(try JSONValue.parse(Data(json.utf8)))
        #expect(state.shelfObjects.map(\.id) == ["o2"])
    }

    @Test("a hue wraps rather than clamping, because it's a circle")
    func tintWraps() throws {
        let json = #"{"shelfObjects": [{"id":"a","kind":"plant","tint":380},{"id":"b","kind":"plant","tint":-20}]}"#
        let state = Normalizer().normalize(try JSONValue.parse(Data(json.utf8)))
        #expect(state.shelfObjects[0].tint == 20)
        #expect(state.shelfObjects[1].tint == 340)
    }

    @Test("an object with no id gets one rather than colliding on empty string")
    func missingIDs() throws {
        let json = #"{"shelfObjects": [{"kind":"cat"},{"kind":"plant"}]}"#
        let state = Normalizer().normalize(try JSONValue.parse(Data(json.utf8)))
        #expect(state.shelfObjects.count == 2)
        #expect(!state.shelfObjects[0].id.isEmpty)
    }

    // MARK: - On the shelf

    @Test("objects and books interleave in one order")
    func interleaved() {
        // Objects live in shelfOrder alongside books, which is what lets one
        // drag gesture move either.
        let plant = ShelfObject(id: "o1", kind: .plant)
        let spines = ["b1", "b2"].map {
            ShelfLayout.spine(for: Fixture.book(id: $0, title: $0, status: .finished))
        }
        let items = ShelfOrder.items(books: spines, objects: [plant], order: ["b2", "o1", "b1"])
        #expect(items.map(\.id) == ["b2", "o1", "b1"])
    }

    @Test("a shelf with no arrangement still shows everything")
    func noOrderShowsAll() {
        let plant = ShelfObject(id: "o1", kind: .plant)
        let spines = [ShelfLayout.spine(for: Fixture.book(id: "b1", title: "A", status: .finished))]
        let items = ShelfOrder.items(books: spines, objects: [plant], order: [])
        #expect(items.count == 2)
    }

    @Test("an object takes up room on the shelf the way a book does")
    func objectsPack() {
        // One packer for both, or the layout and the drawing disagree about how
        // wide a row is and it overflows.
        let cat = ShelfItem.object(ShelfObject(id: "o1", kind: .cat))
        #expect(cat.packWidth == ShelfObjectKind.cat.size.width)

        let rows = ShelfLayout.rows([cat, cat, cat], width: 100)
        #expect(rows.count == 3, "an 86pt cat can't share a 100pt shelf")
    }

    // MARK: - Adding and removing

    @MainActor
    @Test("adding an object puts it on the end of the shelf")
    func addPlacesIt() {
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.shelfOrder = ["b1"] }
        let object = store.addShelfObject(.plant)
        #expect(store.state.shelfObjects.map(\.id) == [object.id])
        #expect(store.state.shelfOrder == ["b1", object.id])
        #expect(object.tint == ShelfObjectKind.plant.defaultTint)
    }

    @MainActor
    @Test("removing an object takes it out of the arrangement too")
    func removePrunesOrder() {
        // Left behind it's a dangling id that survives every sync — the same
        // reason deleting a book prunes the order.
        let store = BookshelfStore(storage: .inMemory())
        let object = store.addShelfObject(.cat)
        store.removeShelfObject(id: object.id)
        #expect(store.state.shelfObjects.isEmpty)
        #expect(store.state.shelfOrder.isEmpty)
    }

    @MainActor
    @Test("rearranging a shelf doesn't strip its objects out of the order")
    func rearrangingKeepsObjects() {
        // The merge treats anything not in `known` as deleted. Without objects
        // in that list, the first drag would scatter every decoration.
        let store = BookshelfStore(storage: .inMemory())
        store.commit { $0.books = [Fixture.book(id: "b1", title: "A", status: .finished)] }
        let plant = store.addShelfObject(.plant)
        store.setShelfOrder(visible: [plant.id, "b1"])
        #expect(store.state.shelfOrder == [plant.id, "b1"])
    }

    @MainActor
    @Test("recolouring and renaming stick")
    func editing() {
        let store = BookshelfStore(storage: .inMemory())
        let bust = store.addShelfObject(.bust, label: "Socrates")
        store.updateShelfObject(id: bust.id, tint: 40, label: "Hypatia")
        #expect(store.state.shelfObject(id: bust.id)?.tint == 40)
        #expect(store.state.shelfObject(id: bust.id)?.displayName == "Hypatia")
    }

    @Test("every kind has a size and a name, so none can be added half-built")
    func everyKindIsComplete() {
        for kind in ShelfObjectKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(kind.size.width > 0 && kind.size.height > 0)
            #expect((0..<360).contains(Int(kind.defaultTint)))
        }
    }
}
