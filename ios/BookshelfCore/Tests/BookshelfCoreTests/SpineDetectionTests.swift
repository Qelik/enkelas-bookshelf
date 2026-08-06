import CoreGraphics
import Foundation
import Testing
@testable import BookshelfCore

/// Choosing which rectangle is a book spine.
///
/// Vision finds every rectangle in frame — the table edge, a phone, the book's
/// front cover, the shelf itself. Choosing badly is worse than not detecting,
/// because the guide then confidently frames the wrong thing.
struct SpineDetectionTests {

    /// An upright quad, normalised, top-left origin.
    static func upright(x: Double, y: Double, w: Double, h: Double) -> SpineQuad {
        SpineQuad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + w, y: y),
            bottomRight: CGPoint(x: x + w, y: y + h),
            bottomLeft: CGPoint(x: x, y: y + h)
        )
    }

    // MARK: - Coordinate flip

    @Test("Vision's bottom-left origin is flipped exactly once")
    func flipsVisionOrigin() {
        // Vision reports a quad in the *upper* half as having high y values.
        // Getting this wrong is what put the crop 90° out last time, so it is
        // pinned rather than assumed.
        let quad = SpineQuad(
            visionTopLeft: CGPoint(x: 0.4, y: 0.9),
            visionTopRight: CGPoint(x: 0.6, y: 0.9),
            visionBottomRight: CGPoint(x: 0.6, y: 0.2),
            visionBottomLeft: CGPoint(x: 0.4, y: 0.2)
        )
        // Top-left origin: the top edge is now the small y.
        #expect(abs(quad.topLeft.y - 0.1) < 0.0001)
        #expect(abs(quad.bottomLeft.y - 0.8) < 0.0001)
        #expect(quad.topLeft.x == 0.4)
        #expect(quad.topLeft.y < quad.bottomLeft.y, "top must be above bottom")
    }

    // MARK: - Shape

    @Test("a spine is long and thin")
    func measuresShape() {
        let quad = Self.upright(x: 0.45, y: 0.15, w: 0.09, h: 0.7)
        #expect(abs(quad.shortSide - 0.09) < 0.001)
        #expect(abs(quad.longSide - 0.7) < 0.001)
        #expect(abs(quad.aspect - 0.09 / 0.7) < 0.001)
        #expect(abs(quad.tilt) < 0.5)
    }

    @Test("tilt is signed, so a lean can be told from its mirror")
    func tiltIsSigned() {
        let leaning = SpineQuad(
            topLeft: CGPoint(x: 0.40, y: 0.10),
            topRight: CGPoint(x: 0.50, y: 0.10),
            bottomRight: CGPoint(x: 0.56, y: 0.80),
            bottomLeft: CGPoint(x: 0.46, y: 0.80)
        )
        #expect(leaning.tilt > 0)
        let other = SpineQuad(
            topLeft: CGPoint(x: 0.50, y: 0.10),
            topRight: CGPoint(x: 0.60, y: 0.10),
            bottomRight: CGPoint(x: 0.54, y: 0.80),
            bottomLeft: CGPoint(x: 0.44, y: 0.80)
        )
        #expect(other.tilt < 0)
    }

    // MARK: - Plausibility

    @Test("a real spine is accepted")
    func acceptsSpine() {
        #expect(SpineDetection.isPlausible(Self.upright(x: 0.45, y: 0.15, w: 0.08, h: 0.7)))
        // A chunky hardback is still a spine.
        #expect(SpineDetection.isPlausible(Self.upright(x: 0.40, y: 0.20, w: 0.22, h: 0.6)))
    }

    @Test("a book's front cover is not a spine")
    func rejectsCover() {
        // A paperback face is roughly 0.65 wide for its height — the single most
        // likely wrong answer, since it's the biggest rectangle in frame.
        #expect(!SpineDetection.isPlausible(Self.upright(x: 0.2, y: 0.2, w: 0.45, h: 0.65)))
    }

    @Test("a table edge or shadow line is not a spine")
    func rejectsSlivers() {
        // Far too thin to be a book.
        #expect(!SpineDetection.isPlausible(Self.upright(x: 0.5, y: 0.1, w: 0.004, h: 0.8)))
    }

    @Test("something small and far away is not the book being photographed")
    func rejectsTiny() {
        #expect(!SpineDetection.isPlausible(Self.upright(x: 0.1, y: 0.1, w: 0.02, h: 0.15)))
    }

    @Test("a book held sideways is refused rather than framed at an angle")
    func rejectsExtremeTilt() {
        let sideways = SpineQuad(
            topLeft: CGPoint(x: 0.1, y: 0.45),
            topRight: CGPoint(x: 0.9, y: 0.40),
            bottomRight: CGPoint(x: 0.9, y: 0.52),
            bottomLeft: CGPoint(x: 0.1, y: 0.57)
        )
        #expect(!SpineDetection.isPlausible(sideways))
    }

    // MARK: - Picking

    @Test("the spine wins over the cover beside it")
    func picksSpineNotCover() {
        let cover = Self.upright(x: 0.15, y: 0.2, w: 0.45, h: 0.62)
        let spine = Self.upright(x: 0.44, y: 0.16, w: 0.09, h: 0.68)
        let edge = Self.upright(x: 0.02, y: 0.05, w: 0.003, h: 0.9)

        let best = SpineDetection.best(of: [cover, edge, spine])
        #expect(best == spine)
    }

    @Test("with two spines in frame, the one being pointed at wins")
    func prefersCentredAndLarge() {
        // Two books on a shelf; the phone is aimed at one of them.
        let offToTheSide = Self.upright(x: 0.05, y: 0.30, w: 0.07, h: 0.42)
        let aimedAt = Self.upright(x: 0.46, y: 0.14, w: 0.09, h: 0.72)
        #expect(SpineDetection.best(of: [offToTheSide, aimedAt]) == aimedAt)
    }

    @Test("nothing plausible means nothing, not the least bad option")
    func refusesWhenNothingFits() {
        // The guide falls back to the centred rectangle, which is honest. Framing
        // a table edge because it scored highest would not be.
        let cover = Self.upright(x: 0.2, y: 0.2, w: 0.5, h: 0.6)
        #expect(SpineDetection.best(of: [cover]) == nil)
        #expect(SpineDetection.best(of: []) == nil)
    }

    // MARK: - Steadiness

    @Test("blending settles the guide instead of letting it twitch")
    func blends() {
        // Raw detections jitter frame to frame; a box that twitches reads as
        // broken even when it is finding the right thing.
        let a = Self.upright(x: 0.40, y: 0.20, w: 0.10, h: 0.60)
        let b = Self.upright(x: 0.50, y: 0.20, w: 0.10, h: 0.60)

        let half = a.blended(towards: b, amount: 0.5)
        #expect(abs(half.topLeft.x - 0.45) < 0.0001)

        // The ends are exact, so a settled box lands on the target rather than
        // creeping toward it forever.
        #expect(a.blended(towards: b, amount: 0) == a)
        #expect(a.blended(towards: b, amount: 1) == b)
    }

    @Test("scaling to a view keeps the shape")
    func scales() {
        let quad = Self.upright(x: 0.25, y: 0.10, w: 0.10, h: 0.70)
        let scaled = quad.scaled(to: CGSize(width: 400, height: 800))
        #expect(scaled.topLeft == CGPoint(x: 100, y: 80))
        #expect(abs(scaled.shortSide - 40) < 0.001)
        #expect(abs(scaled.longSide - 560) < 0.001)
    }
}

/// Putting a detection on screen.
///
/// Vision reports against the whole camera frame; the preview shows a centred
/// crop of it. Drawing one in the other's coordinates misplaces the box — subtly
/// when the aspects are close, badly when they aren't.
struct SpinePreviewMappingTests {

    @Test("the centre of the frame is the centre of the preview")
    func centreMapsToCentre() {
        let point = SpineCrop.previewPoint(
            CGPoint(x: 0.5, y: 0.5),
            imageAspect: 3.0 / 4.0,
            previewSize: CGSize(width: 393, height: 380)
        )
        #expect(abs(point.x - 196.5) < 0.5)
        #expect(abs(point.y - 190) < 0.5)
    }

    @Test("a wide preview crops the frame's top and bottom away")
    func cropsVertically() {
        // A 3:4 frame in a nearly square preview: the full width shows, and the
        // top of the frame is above the visible area — a negative y, which is
        // correct and must not be clamped away.
        let preview = CGSize(width: 400, height: 400)
        let top = SpineCrop.previewPoint(CGPoint(x: 0.5, y: 0), imageAspect: 0.75, previewSize: preview)
        let bottom = SpineCrop.previewPoint(CGPoint(x: 0.5, y: 1), imageAspect: 0.75, previewSize: preview)

        #expect(top.y < 0, "the top of the frame is off the top of the preview")
        #expect(bottom.y > preview.height)
        #expect(abs(top.x - 200) < 0.5)
    }

    @Test("a tall preview crops the sides instead")
    func cropsHorizontally() {
        let preview = CGSize(width: 300, height: 800)
        let left = SpineCrop.previewPoint(CGPoint(x: 0, y: 0.5), imageAspect: 0.75, previewSize: preview)
        let right = SpineCrop.previewPoint(CGPoint(x: 1, y: 0.5), imageAspect: 0.75, previewSize: preview)
        #expect(left.x < 0)
        #expect(right.x > preview.width)
        #expect(abs(left.y - 400) < 0.5)
    }

    @Test("a matching aspect maps straight through")
    func identityWhenAspectsMatch() {
        // 3:4 frame in a 3:4 preview — nothing is cropped, so this is a plain
        // scale. A wrong result here would mean the window maths is off even in
        // the simplest case.
        let preview = CGSize(width: 300, height: 400)
        let p = SpineCrop.previewPoint(CGPoint(x: 0.25, y: 0.75), imageAspect: 0.75, previewSize: preview)
        #expect(abs(p.x - 75) < 0.5)
        #expect(abs(p.y - 300) < 0.5)
    }

    @Test("a detected spine keeps its shape on screen")
    func quadMapsWholesale() {
        let quad = SpineDetectionTests.upright(x: 0.45, y: 0.15, w: 0.08, h: 0.7)
        let mapped = quad.inPreview(imageAspect: 0.75, previewSize: CGSize(width: 393, height: 380))
        // Still upright, still taller than wide.
        #expect(mapped.longSide > mapped.shortSide)
        #expect(abs(mapped.tilt) < 1)
    }
}
