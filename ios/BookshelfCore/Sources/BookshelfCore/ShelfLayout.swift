import Foundation

/// Arranging books on a shelf as physical objects.
///
/// Pure geometry, no SwiftUI — which keeps `BookshelfCore`'s boundary intact and,
/// more usefully, means the packing can be tested. Getting a row to fill without
/// overflowing is the kind of arithmetic that looks obviously right and is off by
/// one gap.
/// Anything that stands on a shelf and takes up room along it.
public protocol ShelfPackable {
    var packWidth: Double { get }
}

public enum ShelfLayout {

    /// A single book, sized as an object rather than a row in a list.
    public struct Spine: Sendable, Hashable, Identifiable, ShelfPackable {
        public var id: String
        public var title: String
        public var author: String
        public var hue: Int
        /// Thickness, from the page count.
        public var width: Double
        /// How tall the book stands.
        public var height: Double
        /// Fraction read, for the ribbon down the spine.
        public var progress: Double
        public var finished: Bool
        /// A hair of rotation so a shelf doesn't look like a bar chart.
        public var lean: Double

        public var packWidth: Double { width }

        public init(
            id: String, title: String, author: String, hue: Int,
            width: Double, height: Double, progress: Double, finished: Bool, lean: Double
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.hue = hue
            self.width = width
            self.height = height
            self.progress = progress
            self.finished = finished
            self.lean = lean
        }
    }

    /// Thickness bounds, in points. A 1,200-page hardback should look like one next
    /// to a novella, but a spine much under this can't hold a title and reads as a
    /// hairline, and one over ~52 is a brick that crowds the shelf.
    public static let minWidth = 24.0
    public static let maxWidth = 52.0

    /// The page counts that map onto the *ends* of that range.
    ///
    /// Not 0…1,200. Mapping the whole conceivable range onto the band left every
    /// normal novel inside a 5pt sliver — 200 pages came out 34pt and 400 came out
    /// 39pt, so a shelf of ordinary books looked machine-milled, which is the one
    /// thing a bookcase shouldn't. These are the counts a real shelf actually
    /// spans; a novella and a doorstop clamp to the ends and keep their bounds.
    public static let thinPages = 120.0
    public static let thickPages = 900.0

    /// Where a book with no page count sits: an average novel. Plenty of shelves
    /// have them (Goodreads exports especially), and both extremes would be a
    /// claim the data doesn't support.
    static let unknownThickness = 0.35

    /// How thick a book of this many pages is, as a fraction of the width range.
    ///
    /// Square root rather than linear, because the eye reads it that way: the gap
    /// between 150 pages and 300 is worth more than the gap between 900 and 1,050.
    static func thickness(pages: Double) -> Double {
        let lo = thinPages.squareRoot(), hi = thickPages.squareRoot()
        guard hi > lo, pages > 0, pages.isFinite else { return unknownThickness }
        return min(1, max(0, (pages.squareRoot() - lo) / (hi - lo)))
    }
    /// Height bounds. Real books on one shelf vary by a couple of centimetres, not
    /// by half; too much variation reads as a broken layout rather than as books.
    public static let minHeight = 118.0
    public static let maxHeight = 168.0

    /// `photoAspect` is width over height of a spine photograph, when there is
    /// one. It overrides the page-count guess — the photograph knows how thick
    /// the book is and the page count only estimates it — and it must be passed
    /// here rather than applied at draw time, or the packer and the renderer
    /// disagree about how wide a book is and rows overflow.
    public static func spine(for book: WireBook, photoAspect: Double? = nil) -> Spine {
        // Deterministic per book, from the same stable hash the placeholder covers
        // use. Random values would reshuffle the whole shelf on every redraw,
        // which is the difference between a bookshelf and a lava lamp.
        let jitter = book.id.isEmpty ? book.title.stableHue : book.id.stableHue

        let thickness = Self.thickness(pages: max(0, book.totalPages))
        // Height is decoration, so it comes from the hash rather than from data
        // that means something — implying a tall book is a long one would be a lie.
        var height = minHeight + (maxHeight - minHeight) * (Double(jitter % 100) / 100)

        let width: Double
        if let photoAspect, photoAspect > 0, photoAspect.isFinite {
            var fromPhoto = height * photoAspect
            if fromPhoto > maxWidth {
                // Too wide for the shelf: shorten the book rather than squash it.
                // Clamping width alone would change the aspect, which is the one
                // thing a photograph is supposed to preserve.
                fromPhoto = maxWidth
                height = fromPhoto / photoAspect
            }
            width = max(fromPhoto, minWidth)
        } else {
            width = minWidth + (maxWidth - minWidth) * thickness
        }

        return Spine(
            id: book.id,
            title: book.title,
            author: book.author,
            hue: book.title.stableHue,
            width: width.rounded(),
            height: height.rounded(),
            progress: book.progress ?? 0,
            finished: book.status == .finished,
            // Only some books lean, and never more than a couple of degrees.
            lean: jitter % 7 == 0 ? Double(jitter % 5) - 2 : 0
        )
    }

    /// Pack items into rows that fit `width`.
    ///
    /// Greedy, in the shelf's own order: things stay where the user put them,
    /// because a shelf that reorders itself to pack tighter is a shelf you can't
    /// find anything on.
    ///
    /// Generic over what's being packed because a shelf holds objects as well as
    /// books, and a plant takes up space exactly the way a paperback does. The
    /// alternative — a second packer for objects — is two implementations that
    /// have to agree about a row's width forever.
    public static func rows<Item: ShelfPackable>(_ items: [Item], width: Double, gap: Double = 2) -> [[Item]] {
        guard width > 0 else { return items.isEmpty ? [] : [items] }
        var rows: [[Item]] = []
        var row: [Item] = []
        var used = 0.0

        for item in items {
            let needed = item.packWidth + (row.isEmpty ? 0 : gap)
            // Something wider than the whole shelf still gets a row of its own
            // rather than being dropped.
            if !row.isEmpty, used + needed > width {
                rows.append(row)
                row = [item]
                used = item.packWidth
            } else {
                row.append(item)
                used += needed
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// Whether everything on a shelf still fits on it.
    ///
    /// Asked of the packer rather than worked out again beside the drag: two
    /// pieces of arithmetic that have to agree about a row's width forever is
    /// exactly how a row comes to overflow the shelf it was measured for.
    public static func overflows<Item: ShelfPackable>(
        _ row: [Item], width: Double, gap: Double = 2
    ) -> Bool {
        rows(row, width: width, gap: gap).count > 1
    }
}
