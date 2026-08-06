import AVFoundation
import BookshelfCore
import CoreImage
import Foundation
import Vision

/// Finds the book spine in the live camera feed.
///
/// `VNDetectRectanglesRequest` rather than anything cleverer: a spine seen
/// head-on *is* a rectangle, and Vision's detector is fast enough to run on video
/// frames. What it can't do is tell a spine from a front cover or a table edge —
/// it returns every rectangle it sees — so the choosing happens in
/// `SpineDetection`, where it can be tested.
final class SpineDetector: @unchecked Sendable {

    /// Called on the video queue with the chosen spine, or nil when none
    /// convinces. Normalised, top-left origin.
    var onResult: (@Sendable (SpineQuad?) -> Void)?

    private let request: VNDetectRectanglesRequest
    /// Frames are 30/sec; running Vision on all of them heats the phone for a
    /// guide that only needs to keep up with a hand.
    private let interval: TimeInterval = 1.0 / 6
    private var lastRun = Date.distantPast
    private var busy = false
    private let lock = NSLock()

    init() {
        request = VNDetectRectanglesRequest()
        // Deliberately permissive: the real filtering is `SpineDetection`, which
        // is tested. Vision's own aspect limits are defined against the image's
        // orientation, which is exactly the sort of assumption that has already
        // cost this feature a day.
        request.minimumAspectRatio = 0.02
        request.maximumAspectRatio = 0.9
        request.minimumSize = 0.15
        request.maximumObservations = 12
        // Books are printed objects with hard edges; a low confidence floor here
        // fills the list with shadows.
        request.minimumConfidence = 0.6
        request.quadratureTolerance = 25
    }

    func process(_ buffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        let now = Date()
        lock.lock()
        let skip = busy || now.timeIntervalSince(lastRun) < interval
        if !skip {
            busy = true
            lastRun = now
        }
        lock.unlock()
        guard !skip, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }

        defer {
            lock.lock()
            busy = false
            lock.unlock()
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation)
        try? handler.perform([request])

        let candidates = (request.results ?? []).map { observation in
            SpineQuad(
                visionTopLeft: observation.topLeft,
                visionTopRight: observation.topRight,
                visionBottomRight: observation.bottomRight,
                visionBottomLeft: observation.bottomLeft
            )
        }
        onResult?(SpineDetection.best(of: candidates))
    }
}

// MARK: - Straightening

enum SpinePerspective {
    /// Pull the quad out of the image and square it up.
    ///
    /// A book is rarely held perfectly parallel to the phone, so the spine
    /// arrives as a slight trapezium. Cropping its bounding box would keep the
    /// background in the corners; correcting the perspective gives a rectangle
    /// that looks like a book on a shelf.
    ///
    /// `quad` is normalised with a top-left origin — this app's convention —
    /// while Core Image works bottom-left, so the flip happens here, once.
    static func straighten(_ image: CIImage, quad: SpineQuad) -> CIImage? {
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }

        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * size.width, y: (1 - p.y) * size.height)
        }

        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter?.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter?.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        filter?.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")
        return filter?.outputImage
    }
}
