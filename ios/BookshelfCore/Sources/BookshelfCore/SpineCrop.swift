import CoreGraphics
import Foundation

/// Turning "what was inside the guide rectangle" into pixels.
///
/// The camera preview is `resizeAspectFill`, so what's on screen is already a
/// crop of the sensor image — usually the middle of a 4:3 frame shown in a taller
/// window. Cropping the captured photo to the guide's *screen* rectangle would
/// therefore take the wrong region, and the result wouldn't be what the user
/// framed. This is where that goes wrong quietly, so the arithmetic lives here
/// where it can be tested rather than inline in a view.
public enum SpineCrop {

    /// A book spine seen edge-on: tall and narrow. Used for the guide's shape and
    /// for the stored image, so what's framed is what's kept.
    public static let aspect = 0.22

    /// The largest spine-shaped rectangle that fits inside `bounds`, centred.
    ///
    /// Driving the guide from the same constant the crop uses means the two can't
    /// drift into disagreeing about what's being captured.
    public static func guideRect(in bounds: CGSize, heightFraction: Double = 0.72) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        var height = bounds.height * heightFraction
        var width = height * aspect
        // In a wide window the height limit isn't the binding one.
        if width > bounds.width * 0.9 {
            width = bounds.width * 0.9
            height = width / aspect
        }
        return CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Which part of the photo an aspect-fill preview is actually showing.
    ///
    /// `resizeAspectFill` scales the image until it covers the preview and clips
    /// the overflow, so the preview is a centred window onto the image. Cropping
    /// has to start from that window — the guide's coordinates mean nothing
    /// against the full frame.
    public static func visibleRect(imageSize: CGSize, previewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              previewSize.width > 0, previewSize.height > 0
        else { return CGRect(origin: .zero, size: imageSize) }

        // Image pixels per preview point. `min` because aspect-*fill* is limited
        // by whichever axis needs the least of the image to cover the preview.
        let pixelsPerPoint = min(
            imageSize.width / previewSize.width,
            imageSize.height / previewSize.height
        )
        let width = previewSize.width * pixelsPerPoint
        let height = previewSize.height * pixelsPerPoint
        return CGRect(
            x: (imageSize.width - width) / 2,
            y: (imageSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// The guide, in the photo's pixels.
    ///
    /// **The photo must already be in display orientation** — that is, with any
    /// EXIF rotation baked in, so its pixel space and the preview's point space
    /// agree about which way is up. Doing this against a raw sensor buffer means
    /// reasoning about which coordinate space `metadataOutputRectConverted`
    /// returns, and getting that wrong produces a crop rotated by 90° — a
    /// landscape sliver where a spine should be. Normalising first makes the
    /// whole question disappear.
    public static func cropRect(
        guide: CGRect,
        previewSize: CGSize,
        imageSize: CGSize
    ) -> CGRect? {
        guard previewSize.width > 0, previewSize.height > 0 else { return nil }
        let visible = visibleRect(imageSize: imageSize, previewSize: previewSize)
        let scale = visible.width / previewSize.width

        return pixelRect(
            from: CGRect(
                x: (visible.minX + guide.minX * scale) / imageSize.width,
                y: (visible.minY + guide.minY * scale) / imageSize.height,
                width: guide.width * scale / imageSize.width,
                height: guide.height * scale / imageSize.height
            ),
            imageSize: imageSize
        )
    }

    /// Convert a normalised rect (0…1 in the image's own space, origin top-left)
    /// to pixels, clamped to the image.
    ///
    /// Clamping matters: a guide touching the edge can round to fractionally
    /// outside 0…1, and `cropping(to:)` returns nil for a rect that isn't fully
    /// inside — a capture that silently does nothing.
    public static func pixelRect(from normalised: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let raw = CGRect(
            x: normalised.origin.x * imageSize.width,
            y: normalised.origin.y * imageSize.height,
            width: normalised.width * imageSize.width,
            height: normalised.height * imageSize.height
        )
        let clamped = raw.intersection(CGRect(origin: .zero, size: imageSize))
        // An empty or inverted rect means the guide didn't overlap the image at
        // all; better to refuse than to hand back a 0×0 crop.
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }

        return CGRect(
            x: clamped.origin.x.rounded(.down),
            y: clamped.origin.y.rounded(.down),
            width: clamped.width.rounded(.down),
            height: clamped.height.rounded(.down)
        )
    }

    /// How large a stored spine should be, in pixels.
    ///
    /// Small on purpose. A shelf shows a spine about 40pt wide, so even at 3×
    /// there is nothing to gain past ~150px, and a few hundred full-resolution
    /// photographs would be hundreds of megabytes for no visible difference.
    public static let storedHeight = 640.0
    public static var storedSize: CGSize {
        CGSize(width: (storedHeight * aspect).rounded(), height: storedHeight)
    }

    /// Scale a crop down to `storedSize`, keeping its aspect. Never scales *up* —
    /// enlarging a small crop wastes bytes on interpolation.
    public static func storedSize(for cropped: CGSize) -> CGSize {
        guard cropped.width > 0, cropped.height > 0 else { return storedSize }
        let scale = min(1, storedHeight / cropped.height)
        return CGSize(
            width: max(1, (cropped.width * scale).rounded()),
            height: max(1, (cropped.height * scale).rounded())
        )
    }
}
