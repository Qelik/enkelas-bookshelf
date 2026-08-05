import Foundation

/// Arranging books on a shelf as physical objects.
///
/// Pure geometry, no SwiftUI — which keeps `BookshelfCore`'s boundary intact and,
/// more usefully, means the packing can be tested. Getting a row to fill without
/// overflowing is the kind of arithmetic that looks obviously right and is off by
/// one gap.
public enum ShelfLayout {

    /// A single book, sized as an object rather than a row in a list.
    public struct Spine: Sendable, Hashable, Identifiable {
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

    /// Thickness bounds, in points. A 1,200-page hardback should look like one
    /// next to a novella, but a spine under ~20pt can't hold a title and one over
    /// ~52 crowds the shelf.
    public static let minWidth = 22.0
    public static let maxWidth = 52.0
    /// Height bounds. Real books on one shelf vary by a couple of centimetres, not
    /// by half; too much variation reads as a broken layout rather than as books.
    public static let minHeight = 118.0
    public static let maxHeight = 168.0

    public static func spine(for book: WireBook) -> Spine {
        // Deterministic per book, from the same stable hash the placeholder covers
        // use. Random values would reshuffle the whole shelf on every redraw,
        // which is the difference between a bookshelf and a lava lamp.
        let jitter = book.id.isEmpty ? book.title.stableHue : book.id.stableHue

        // Page count drives thickness, on a square-root curve: linear mapping put
        // every normal novel in the same narrow band and let one doorstop use the
        // entire range.
        let pages = max(0, book.totalPages)
        let thickness = pages > 0 ? (pages / 1_200).squareRoot() : 0.28
        let width = minWidth + (maxWidth - minWidth) * min(1, thickness)

        // Height is decoration, so it comes from the hash rather than from data
        // that means something — implying a tall book is a long one would be a lie.
        let height = minHeight + (maxHeight - minHeight) * (Double(jitter % 100) / 100)

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

    /// Pack spines into rows that fit `width`.
    ///
    /// Greedy, in the shelf's own order: books stay in the order the user put them
    /// in, because a shelf that reorders itself to pack tighter is a shelf you
    /// can't find anything on.
    public static func rows(_ spines: [Spine], width: Double, gap: Double = 2) -> [[Spine]] {
        guard width > 0 else { return spines.isEmpty ? [] : [spines] }
        var rows: [[Spine]] = []
        var row: [Spine] = []
        var used = 0.0

        for spine in spines {
            let needed = spine.width + (row.isEmpty ? 0 : gap)
            // A spine wider than the whole shelf still gets a row of its own
            // rather than being dropped.
            if !row.isEmpty, used + needed > width {
                rows.append(row)
                row = [spine]
                used = spine.width
            } else {
                row.append(spine)
                used += needed
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}
