import CoreGraphics
import Foundation

/// A detected book spine: four corners, in order.
///
/// **One convention, everywhere: normalised 0…1, origin top-left.** Vision hands
/// back bottom-left origin and AVFoundation's metadata rects are top-left, and
/// mixing the two is what produced a crop rotated by 90° the first time round.
/// The flip happens once, at the boundary, in `init(visionCorners:)` — and after
/// that nothing downstream has to think about it.
public struct SpineQuad: Sendable, Hashable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// From Vision, which reports normalised points with the origin at the
    /// *bottom* left. Its "top" is therefore our bottom.
    public init(
        visionTopLeft: CGPoint, visionTopRight: CGPoint,
        visionBottomRight: CGPoint, visionBottomLeft: CGPoint
    ) {
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        self.init(
            topLeft: flip(visionTopLeft),
            topRight: flip(visionTopRight),
            bottomRight: flip(visionBottomRight),
            bottomLeft: flip(visionBottomLeft)
        )
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Axis-aligned bounds, for the cases that don't need the corners.
    public var boundingBox: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Average of the two vertical edges — the spine's height, ignoring tilt.
    public var longSide: Double {
        (distance(topLeft, bottomLeft) + distance(topRight, bottomRight)) / 2
    }

    /// Average of the two horizontal edges — the spine's width.
    public var shortSide: Double {
        (distance(topLeft, topRight) + distance(bottomLeft, bottomRight)) / 2
    }

    /// Width over height. A spine is a small number; a paperback face is near 0.7.
    public var aspect: Double {
        longSide > 0 ? shortSide / longSide : .infinity
    }

    /// Degrees off vertical, signed. A book held straight is near zero.
    public var tilt: Double {
        let dx = ((bottomLeft.x + bottomRight.x) - (topLeft.x + topRight.x)) / 2
        let dy = ((bottomLeft.y + bottomRight.y) - (topLeft.y + topRight.y)) / 2
        return atan2(dx, dy) * 180 / .pi
    }

    /// Into the preview's coordinates, accounting for the aspect-fill window.
    ///
    /// Not `scaled(to:)`: the preview shows a centred *crop* of the camera frame,
    /// so a detection reported against the whole frame has to be mapped through
    /// that window or it lands somewhere else on screen.
    public func inPreview(imageAspect: Double, previewSize: CGSize) -> SpineQuad {
        func to(_ p: CGPoint) -> CGPoint {
            SpineCrop.previewPoint(p, imageAspect: imageAspect, previewSize: previewSize)
        }
        return SpineQuad(
            topLeft: to(topLeft), topRight: to(topRight),
            bottomRight: to(bottomRight), bottomLeft: to(bottomLeft)
        )
    }

    /// Scale from normalised space into a rect of `size`.
    public func scaled(to size: CGSize) -> SpineQuad {
        func to(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        return SpineQuad(
            topLeft: to(topLeft), topRight: to(topRight),
            bottomRight: to(bottomRight), bottomLeft: to(bottomLeft)
        )
    }

    /// Blend toward `other`. Used to settle the on-screen guide: raw detections
    /// jitter frame to frame, and a box that twitches reads as broken even when
    /// it's finding the right thing.
    public func blended(towards other: SpineQuad, amount: Double) -> SpineQuad {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
        }
        return SpineQuad(
            topLeft: mix(topLeft, other.topLeft),
            topRight: mix(topRight, other.topRight),
            bottomRight: mix(bottomRight, other.bottomRight),
            bottomLeft: mix(bottomLeft, other.bottomLeft)
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// Deciding which of Vision's rectangles is a book spine.
///
/// Rectangle detection finds every rectangle in frame — the table edge, a phone,
/// the book's front cover, the shelf itself. Choosing badly is worse than not
/// detecting at all, because the guide then confidently frames the wrong thing.
public enum SpineDetection {

    /// Spines are long and thin. Wider than this and it's a cover or a box;
    /// narrower and it's usually an edge or a shadow line.
    public static let maxAspect = 0.42
    public static let minAspect = 0.03
    /// It has to be a real part of the frame, not a distant sliver.
    public static let minLongSide = 0.35
    /// More than this off vertical and the user is holding it sideways; the
    /// centred guide is a better answer than a wild quad.
    public static let maxTilt = 25.0

    public static func isPlausible(_ quad: SpineQuad) -> Bool {
        let aspect = quad.aspect
        guard aspect.isFinite else { return false }
        return aspect <= maxAspect
            && aspect >= minAspect
            && quad.longSide >= minLongSide
            && abs(quad.tilt) <= maxTilt
    }

    /// Higher is better. Prefers a tall, upright spine near the middle — where
    /// someone pointing a phone at a book will have put it.
    public static func score(_ quad: SpineQuad) -> Double {
        let centre = quad.boundingBox
        let dx = centre.midX - 0.5
        let dy = centre.midY - 0.5
        let offCentre = (dx * dx + dy * dy).squareRoot()

        return quad.longSide * 2.0                      // prefer a big target
            - offCentre * 1.5                           // near the middle
            - abs(quad.tilt) / 90.0                     // and upright
    }

    /// The best spine among the candidates, or nil when none convinces.
    public static func best(of candidates: [SpineQuad]) -> SpineQuad? {
        candidates
            .filter(isPlausible)
            .max { score($0) < score($1) }
    }
}
