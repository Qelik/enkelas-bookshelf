import Foundation

/// The things on a shelf that aren't books.
///
/// A real bookcase is never only books — there's a plant, a photograph, a stack
/// lying flat, something somebody brought back from somewhere. The bookcase is
/// the one screen in this app that's a drawn object rather than a list, and it
/// reads as furniture rather than a chart precisely because of that clutter.
///
/// Objects live in `shelfOrder` alongside books, which is why they can be
/// dragged around with exactly the same gesture and need no second notion of
/// position. `shelfOrder` stops being "the order of your books" and becomes
/// "the order of things on the shelf", which is what it always meant.
public struct ShelfObject: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ShelfObjectKind
    /// 0…359. One drawing, many looks — a jade plant and a red-leafed one, a
    /// marble bust and a bronze one. Far cheaper than drawing each twice.
    public var tint: Double
    /// Whose bust it is. Empty for everything else.
    public var label: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: ShelfObjectKind,
        tint: Double = 0,
        label: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.tint = tint
        self.label = label
    }

    /// What to call it in a list.
    public var displayName: String {
        label.isEmpty ? kind.displayName : label
    }
}

/// Deliberately a closed list. Both clients rebuild state from a whitelist, so
/// a kind one of them doesn't know is a kind that gets dropped — see
/// `Normalizer`. Adding one means adding it to the web app in the same change.
public enum ShelfObjectKind: String, Codable, Sendable, CaseIterable {
    case plant
    case stackedBooks
    case candle
    case bookend
    case photo
    case clock
    case cat
    case crystal
    /// A classical bust. Which philosopher is in `label`.
    case bust
    /// Two dragons rather than one with a variant: they sit completely
    /// differently on a shelf, and the silhouette is the whole point at this size.
    case dragonPerched
    case dragonCoiled

    public var displayName: String {
        switch self {
        case .plant: "Trailing plant"
        case .stackedBooks: "Stack of books"
        case .candle: "Candle"
        case .bookend: "Bookend"
        case .photo: "Framed photo"
        case .clock: "Little clock"
        case .cat: "Sleeping cat"
        case .crystal: "Ornament"
        case .bust: "Philosopher"
        case .dragonPerched: "Perched dragon"
        case .dragonCoiled: "Coiled dragon"
        }
    }

    /// How much shelf it takes, and how tall it stands.
    ///
    /// Sizes are the layout's, not the drawing's: the packer measures this and
    /// the view draws to it, and a mismatch between the two is what makes rows
    /// overflow — the same rule spine photos already follow.
    public var size: (width: Double, height: Double) {
        switch self {
        case .plant: (46, 148)
        case .stackedBooks: (64, 58)
        case .candle: (40, 76)
        case .bookend: (30, 72)
        case .photo: (54, 76)
        case .clock: (56, 64)
        case .cat: (86, 48)
        case .crystal: (36, 60)
        case .bust: (48, 100)
        case .dragonPerched: (60, 86)
        case .dragonCoiled: (68, 56)
        }
    }

    /// A sensible starting colour, so the first one you place already looks
    /// right without opening a colour picker.
    public var defaultTint: Double {
        switch self {
        case .plant: 130          // green
        case .stackedBooks: 280   // whatever, they're multicoloured
        case .candle: 40          // warm wax
        case .bookend: 220        // cold metal
        case .photo: 35           // wood frame
        case .clock: 35
        case .cat: 28             // ginger
        case .crystal: 195
        case .bust: 210           // pale marble
        case .dragonPerched: 145  // green
        case .dragonCoiled: 355   // red
        }
    }

    /// Busts are the one kind that names itself. Historical figures, so no
    /// licence question — unlike naming a dragon after somebody's novel.
    public static let philosophers = ["Socrates", "Plato", "Aristotle", "Diogenes", "Hypatia", "Homer"]

    /// Whether this kind is drawn from a photograph rather than from shapes.
    ///
    /// Core has no business knowing about bundles, so the app decides what it
    /// actually has; this is the *editorial* half — a photographed object must
    /// not offer a colour slider, because multiplying a hue over a picture of
    /// carved wood looks like a bad filter rather than a different object.
    public var isPhotographic: Bool {
        // Everything except the book stack, which had no usable public-domain
        // photograph — every candidate was an engraving.
        self != .stackedBooks
    }
}

// MARK: - On the shelf

public extension WireState {
    func shelfObject(id: String) -> ShelfObject? {
        shelfObjects.first { $0.id == id }
    }
}

@MainActor
public extension BookshelfStore {

    /// Put something on the shelf. It lands at the end, where a new book does.
    @discardableResult
    func addShelfObject(_ kind: ShelfObjectKind, tint: Double? = nil, label: String = "") -> ShelfObject {
        let object = ShelfObject(
            kind: kind,
            tint: tint ?? kind.defaultTint,
            label: label
        )
        commit { state in
            state.shelfObjects.append(object)
            state.shelfOrder.append(object.id)
        }
        return object
    }

    func removeShelfObject(id: String) {
        commit { state in
            state.shelfObjects.removeAll { $0.id == id }
            // Left behind it would be a dangling id that survives every sync —
            // the same reason deleting a book prunes the order.
            state.shelfOrder.removeAll { $0 == id }
        }
    }

    func updateShelfObject(id: String, tint: Double? = nil, label: String? = nil) {
        commit { state in
            guard let i = state.shelfObjects.firstIndex(where: { $0.id == id }) else { return }
            if let tint { state.shelfObjects[i].tint = tint }
            if let label { state.shelfObjects[i].label = label }
        }
    }
}
