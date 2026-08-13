import BookshelfCore
import CoreImage
import UIKit
import Vision

/// Pulling every book it can find out of one photograph of a shelf.
///
/// Three stages, each of which fails differently and so is kept separate:
/// find the spines, read each one, then ask the catalogue who they are. The
/// decisions worth knowing about:
///
/// - **Rectangles, not a model.** A spine seen head-on is a rectangle, and
///   `VNDetectRectanglesRequest` is on every device with no download and no
///   inference budget. Which rectangles are books is decided in
///   `ShelfieDetection`, where it's testable.
/// - **Each spine is OCR'd twice, rotated both ways.** Spine text runs
///   vertically, and which way up depends on the publisher's country — British
///   books read bottom-to-top, American ones often top-to-bottom. Reading only
///   one direction silently loses half a shelf.
/// - **Language correction is off.** Titles and names are proper nouns; the
///   corrector turns *Piranesi* into *Piranesi* about half the time and into
///   *Pirates* the rest.
enum ShelfieScanner {

    struct Found: Sendable {
        let quad: SpineQuad
        let text: SpineText
        /// The straightened spine, for the review row. This is the evidence — a
        /// row you can't check against the actual book is one you can only
        /// accept on faith.
        let crop: UIImage?
    }

    /// Vision hands back a lot of rectangles on a shelf; this is the ceiling
    /// before `ShelfieDetection` does the real filtering.
    static let maximumRectangles = 64

    // MARK: - Stage 1 + 2: find and read

    static func scan(_ image: UIImage) async -> [Found] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let quads = await detectSpines(in: cgImage, orientation: orientation)
        guard !quads.isEmpty else { return [] }

        let source = CIImage(cgImage: cgImage).oriented(orientation)
        let context = CIContext()

        var found: [Found] = []
        for quad in quads {
            let straightened = SpinePerspective.straighten(source, quad: quad)
            let lines = await read(straightened, context: context)
            found.append(Found(
                quad: quad,
                text: SpineTextParser.parse(lines),
                crop: straightened.flatMap { render($0, context: context) }
            ))
        }
        return found
    }

    private static func detectSpines(
        in image: CGImage,
        orientation: CGImagePropertyOrientation
    ) async -> [SpineQuad] {
        let request = VNDetectRectanglesRequest()
        // Permissive on purpose — the tested rules in `ShelfieDetection` do the
        // choosing. Vision's own aspect limits are stated against the image's
        // orientation, which is the assumption that has cost this feature most.
        request.minimumAspectRatio = 0.01
        request.maximumAspectRatio = 0.9
        // Low, because this is measured against the frame and a spine is thin by
        // definition. At 0.08 a test shelf lost its two narrowest books outright
        // — and on a real shelf of thirty, *every* spine is that thin relative to
        // the frame, so the floor would quietly drop most of the shelf.
        request.minimumSize = 0.03
        request.maximumObservations = maximumRectangles
        // Lower than the single-book scanner: a spine in a shelf photo is small
        // and often shadowed, and the review step catches what this lets through.
        request.minimumConfidence = 0.35
        request.quadratureTolerance = 32

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try? handler.perform([request])

        let candidates = (request.results ?? []).map { observation in
            SpineQuad(
                visionTopLeft: observation.topLeft,
                visionTopRight: observation.topRight,
                visionBottomRight: observation.bottomRight,
                visionBottomLeft: observation.bottomLeft
            )
        }
        return ShelfieDetection.spines(from: candidates)
    }

    /// Read one straightened spine, trying it both ways up.
    private static func read(_ spine: CIImage?, context: CIContext) async -> [String] {
        guard let spine else { return [] }
        // A spine is taller than it is wide; rotating a quarter turn puts its
        // text on the horizontal, which is what the recogniser is built for.
        let clockwise = spine.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let anticlockwise = spine.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))

        let a = recognise(clockwise, context: context)
        let b = recognise(anticlockwise, context: context)
        // More readable characters wins. Upside-down text doesn't come back
        // empty — it comes back as short nonsense, which a length comparison
        // separates far more reliably than confidence does.
        return a.joined().count >= b.joined().count ? a : b
    }

    private static func recognise(_ image: CIImage, context: CIContext) -> [String] {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Proper nouns: correction rewrites more titles than it rescues.
        request.usesLanguageCorrection = false
        // A spine title is large type; the default minimum drops it on a small
        // crop.
        request.minimumTextHeight = 0.05

        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])

        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private static func render(_ image: CIImage, context: CIContext) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Stage 3: who are they?

    /// Ask the catalogue about each spine, in order, reporting as it goes.
    ///
    /// Sequential with a gap rather than a fan-out: Open Library is
    /// unauthenticated and rate-limits, and forty parallel searches get a shelf's
    /// worth of 429s. Results are handed back one at a time so the review list
    /// fills in while it works — a spinner over a blank screen for forty books is
    /// how someone decides the feature is broken.
    static func match(
        _ candidates: [ShelfieCandidate],
        using library: OpenLibrary = OpenLibrary(),
        onResult: @MainActor (Int, OpenLibrary.Doc?) -> Void
    ) async {
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { return }
            guard candidate.isUsable else {
                await onResult(index, nil)
                continue
            }
            let docs = try? await library.search(freeText: candidate.text.query)
            await onResult(index, best(of: docs ?? [], for: candidate))
            // Polite spacing. Without it a big shelf trips the rate limiter about
            // two thirds of the way through, which looks like the far end of the
            // shelf failing to scan.
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Prefer a hit whose author the spine also mentions.
    ///
    /// Open Library's top result for a bare title is whichever edition it ranked,
    /// and for a common title that's frequently a different book altogether. The
    /// spine usually printed the author too, so it can be used as a check.
    private static func best(of docs: [OpenLibrary.Doc], for candidate: ShelfieCandidate) -> OpenLibrary.Doc? {
        guard !docs.isEmpty else { return nil }
        let printed = candidate.text.usefulLines.joined(separator: " ")
        let confirmed = docs.first { doc in
            (doc.author_name ?? []).contains { name in
                guard let surname = name.split(separator: " ").last, surname.count >= 3 else { return false }
                return printed.range(of: surname, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return confirmed ?? docs.first
    }
}

extension CGImagePropertyOrientation {
    /// UIKit's orientation enum says how to *display* the pixels; Vision wants
    /// the same fact in its own vocabulary. Getting this wrong rotates every
    /// detection by a quarter turn, which reads as the detector finding nothing.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
