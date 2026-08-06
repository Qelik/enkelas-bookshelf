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

    /// Convert a normalised rect (0…1 in the image's own space, origin top-left)
    /// to pixels, clamped to the image.
    ///
    /// The normalised rect comes from
    /// `AVCaptureVideoPreviewLayer.metadataOutputRectConverted(fromLayerRect:)`,
    /// which is what accounts for the preview's gravity and orientation. Clamping
    /// matters: that conversion can return values slightly outside 0…1 when the
    /// guide touches the edge, and `cropping(to:)` returns nil for a rect that
    /// isn't fully inside — a silently failed capture.
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
