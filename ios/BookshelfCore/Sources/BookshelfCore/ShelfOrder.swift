import Foundation

/// The order you arranged your shelf in.
///
/// `state.shelfOrder` has synced to this app since the first release and was
/// never read: the bookcase sorted by whatever the Sort menu said, so an
/// arrangement made in the browser simply didn't exist on the phone. This is
/// the missing half, and it's a port rather than a reinvention because both
/// clients write the same field — two different notions of "your order" would
/// fight over it on every sync.
public enum ShelfOrder {

    /// Books in the arrangement, with anything unplaced keeping its incoming
    /// position at the end.
    ///
    /// Stable by construction. Swift's `sorted` is not a stable sort, so two
    /// books that are both unplaced would otherwise swap around between
    /// redraws — a shelf that reshuffles itself when nothing changed.
    public static func sorted(_ books: [WireBook], by order: [String]) -> [WireBook] {
        guard !order.isEmpty else { return books }
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }

        return books.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// Splice a rearranged *visible* run back into the stored order.
    ///
    /// Ported from `mergeShelfOrder` in `src/app.ts`, and the reason it exists
    /// is worth restating: the shelf shows a **filtered** library, so the books
    /// on screen are only some of them. Writing that list straight to
    /// `shelfOrder` would throw away the position of everything a search or a
    /// genre filter had hidden — you'd tidy one shelf and silently scramble the
    /// rest of the library.
    ///
    /// The visible run goes back in at the first slot it used to occupy, and
    /// hidden books keep their positions around it.
    public static func merge(previous: [String], visible: [String], known: [String]) -> [String] {
        let onShelf = Set(visible)
        let exists = Set(known)
        // Ids of books that have since been deleted would otherwise accumulate
        // forever, surviving every sync.
        let prev = previous.filter { exists.contains($0) }

        var out: [String] = []
        var placed = false
        for id in prev {
            if onShelf.contains(id) {
                if !placed {
                    out.append(contentsOf: visible)
                    placed = true
                }
                continue
            }
            out.append(id)
        }
        // Nothing was ordered yet, or none of these books had a place.
        if !placed { out.append(contentsOf: visible) }
        return out
    }
}

@MainActor
public extension BookshelfStore {
    /// Record a rearrangement of the books currently on screen.
    ///
    /// Takes the *visible* ids, not the whole library — see `ShelfOrder.merge`.
    func setShelfOrder(visible ids: [String]) {
        commit { state in
            state.shelfOrder = ShelfOrder.merge(
                previous: state.shelfOrder,
                visible: ids,
                known: state.books.map(\.id)
            )
        }
    }
}
