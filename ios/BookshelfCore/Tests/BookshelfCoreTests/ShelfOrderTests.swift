import Foundation
import Testing
@testable import BookshelfCore

/// The arrangement you made yourself. Both clients write this field, so the
/// rules have to match the web app's exactly — and the filtering case is the
/// one that quietly destroys work if it's wrong.
struct ShelfOrderTests {

    static func books(_ ids: [String]) -> [WireBook] {
        ids.map { Fixture.book(id: $0, title: "Book \($0)", status: .finished) }
    }

    // MARK: - Showing it

    @Test("books follow the arrangement")
    func sortsByOrder() {
        let sorted = ShelfOrder.sorted(Self.books(["a", "b", "c"]), by: ["c", "a", "b"])
        #expect(sorted.map(\.id) == ["c", "a", "b"])
    }

    @Test("books never placed keep their incoming order, at the end")
    func unplacedAreStable() {
        // Swift's sort isn't stable, so without an explicit tiebreak two
        // unplaced books swap between redraws — a shelf that reshuffles itself
        // while you're looking at it.
        let sorted = ShelfOrder.sorted(Self.books(["a", "b", "c", "d"]), by: ["c"])
        #expect(sorted.map(\.id) == ["c", "a", "b", "d"])

        // Same input, same answer, every time.
        for _ in 0..<20 {
            #expect(ShelfOrder.sorted(Self.books(["a", "b", "c", "d"]), by: ["c"]).map(\.id) == ["c", "a", "b", "d"])
        }
    }

    @Test("no arrangement leaves the incoming order alone")
    func emptyOrderIsANoOp() {
        let input = Self.books(["b", "a", "c"])
        #expect(ShelfOrder.sorted(input, by: []).map(\.id) == ["b", "a", "c"])
    }

    @Test("an arrangement naming books that are gone still works")
    func staleIdsInOrder() {
        let sorted = ShelfOrder.sorted(Self.books(["a", "b"]), by: ["deleted", "b", "a"])
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    // MARK: - Saving it

    @Test("rearranging a filtered shelf doesn't scramble the books you can't see")
    func mergeKeepsHiddenBooks() {
        // THE case this exists for. The shelf shows a filtered library; writing
        // the visible list straight to shelfOrder would throw away the position
        // of everything a search or genre filter had hidden.
        let merged = ShelfOrder.merge(
            previous: ["a", "b", "c", "d", "e"],
            visible: ["d", "b"],                       // filtered to two, reordered
            known: ["a", "b", "c", "d", "e"]
        )
        // The run goes back at the first slot it occupied — b's — and a, c and e
        // keep their places around it.
        #expect(merged == ["a", "d", "b", "c", "e"])
    }

    @Test("a first-ever arrangement just becomes the order")
    func mergeWithNothingStored() {
        let merged = ShelfOrder.merge(previous: [], visible: ["c", "a", "b"], known: ["a", "b", "c"])
        #expect(merged == ["c", "a", "b"])
    }

    @Test("arranging books that had no place puts them after the ones that did")
    func mergeWhenNoneWereOrdered() {
        let merged = ShelfOrder.merge(previous: ["x", "y"], visible: ["b", "a"], known: ["x", "y", "a", "b"])
        #expect(merged == ["x", "y", "b", "a"])
    }

    @Test("deleted books drop out of the arrangement instead of accumulating")
    func mergeForgetsDeletedBooks() {
        // A dangling id is harmless to display but survives every sync forever.
        let merged = ShelfOrder.merge(
            previous: ["gone", "a", "alsogone", "b"],
            visible: ["b", "a"],
            known: ["a", "b"]
        )
        #expect(merged == ["b", "a"])
    }

    @MainActor
    @Test("the store records a rearrangement of what was on screen")
    func storeWritesMergedOrder() {
        let store = BookshelfStore(storage: .inMemory())
        store.commit {
            $0.books = Self.books(["a", "b", "c"])
            $0.shelfOrder = ["a", "b", "c"]
        }
        store.setShelfOrder(visible: ["c", "a"])       // b was filtered out
        #expect(store.state.shelfOrder == ["c", "a", "b"])
    }
}
