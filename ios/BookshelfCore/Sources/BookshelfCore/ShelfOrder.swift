import Foundation

/// The order you arranged your shelf in.
///
/// `state.shelfOrder` has synced to this app since the first release and was
/// never read: the bookcase sorted by whatever the Sort menu said, so an
/// arrangement made in the browser simply didn't exist on the phone. This is
/// the missing half, and it's a port rather than a reinvention because both
/// clients write the same field — two different notions of "your order" would
/// fight over it on every sync.
/// One thing standing on a shelf: a book, or something you put there.
///
/// The two travel together through the packer and the drag gesture because on
/// a real shelf they are the same kind of thing — an object occupying a stretch
/// of plank in an order you chose.
public enum ShelfItem: Identifiable, Sendable, ShelfPackable {
    case book(ShelfLayout.Spine)
    case object(ShelfObject)

    public var id: String {
        switch self {
        case .book(let spine): spine.id
        case .object(let object): object.id
        }
    }

    public var packWidth: Double {
        switch self {
        case .book(let spine): spine.width
        case .object(let object): object.kind.size.width
        }
    }
}

public enum ShelfOrder {

    /// Marks the end of a shelf inside `shelfOrder`.
    ///
    /// Without this the packer decides which shelf everything lands on: it
    /// fills the top plank, then the next, so an ornament could never be put
    /// on the third shelf while the first had room. A real bookcase is
    /// arranged by *level* — the cat on top, the dragon two down — and that
    /// needs somewhere to record which level.
    ///
    /// A sentinel rather than a new field because `shelfOrder` is already a
    /// list of strings that both clients round-trip verbatim. Nothing else can
    /// collide with it: every real id is a UUID.
    public static let shelfBreak = "--shelf--"

    /// Split a stored order into one list of ids per shelf.
    public static func rows(of order: [String]) -> [[String]] {
        var rows: [[String]] = [[]]
        for id in order {
            if id == shelfBreak {
                rows.append([])
            } else {
                rows[rows.count - 1].append(id)
            }
        }
        return rows
    }

    /// Flatten shelves back into a stored order.
    ///
    /// Trailing empty shelves are dropped: the case always draws at least
    /// three, so recording empties past the last occupied one just accumulates
    /// breaks every time anything is dragged.
    public static func flatten(_ rows: [[String]]) -> [String] {
        var rows = rows
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return Array(rows.map { $0 }.joined(separator: [shelfBreak]))
    }


    /// Books and objects interleaved, in the order they were left in.
    ///
    /// Objects with no place yet fall to the end alongside unplaced books, which
    /// is where a newly added one belongs anyway.
    public static func items(
        books: [ShelfLayout.Spine],
        objects: [ShelfObject],
        order: [String]
    ) -> [ShelfItem] {
        let all: [ShelfItem] = books.map { .book($0) } + objects.map { .object($0) }
        guard !order.isEmpty else { return all }

        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        return all.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }


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
        // forever, surviving every sync. Shelf breaks are never "known" ids but
        // must survive, or rearranging one shelf collapses the whole case back
        // onto one plank.
        let prev = previous.filter { exists.contains($0) || $0 == shelfBreak }

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
                // Objects count as known things, or the merge would treat every
                // decoration as a deleted book and strip it from the order the
                // first time any shelf was rearranged.
                known: state.books.map(\.id) + state.shelfObjects.map(\.id)
            )
        }
    }
}
