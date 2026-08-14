import BookshelfCore
import SwiftUI

/// A shelf object as a photograph of the real thing.
///
/// Drawn shapes and generated 3D both topped out looking like illustration.
/// These are photographs of actual objects — museum pieces mostly, since the
/// Met, LACMA and the Rijksmuseum publish their collections as CC0 images shot
/// on a plain ground, which is both what a shelf ornament *is* and the ideal
/// input for a subject lift. `ios/Tools/fetch-object-images.py` fetches them
/// and `cutout.swift` lifts them onto transparency; `Models/CREDITS.json`
/// records what came from where and under what licence.
///
/// **Not tinted.** The hue slider recolours a drawing because a drawing is a
/// flat fill with a number behind it. Multiplying a colour over a photograph of
/// carved wood makes it look like a bad filter, not like a different object.
struct ShelfObjectImage: View {
    let kind: ShelfObjectKind
    let height: Double

    var body: some View {
        VStack(spacing: 0) {
            // `Image(name)` resolves against the asset catalogue and finds
            // nothing for a loose PNG in the bundle, while `UIImage(named:)`
            // searches the bundle's files too — so the existence check passed,
            // the render drew nothing, and every photographed object vanished
            // off the shelf. Loading it explicitly keeps the check and the
            // drawing on one path.
            Image(uiImage: ShelfObjectImageCache.shared.image(kind) ?? UIImage())
                .resizable()
                .scaledToFit()
                // Height, not width: the objects were cut to their own bounds
                // and are wildly different shapes, so matching heights is what
                // makes a row of them look like things standing on one shelf.
                .frame(height: kind.needsBase ? height * 0.84 : height)
                // The photographs come off white museum walls and the shelf is
                // a dark case; without this they read as cut-outs pasted on
                // rather than objects in the same room.
                .shadow(color: .black.opacity(0.55), radius: 3, x: 1.5, y: 2)
            if kind.needsBase {
                base
            }
        }
    }

    /// A turned wooden display stand.
    ///
    /// Two discs and a waist, lit from the upper left like everything else. It
    /// is what the museum pieces that *were* photographed on stands already
    /// have, so this makes the set consistent rather than adding a flourish —
    /// and it gives a cut-out object something to stand on instead of hovering.
    private var base: some View {
        let wood = { (b: Double) in Color(hue: 0.07, saturation: 0.52, brightness: b) }
        return VStack(spacing: 0) {
            // Top disc, the piece the object actually rests on.
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: wood(0.24), location: 0),
                            .init(color: wood(0.46), location: 0.28),
                            .init(color: wood(0.30), location: 0.72),
                            .init(color: wood(0.18), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: height * 0.34, height: max(3, height * 0.035))
            // Waist, narrower — the turn that makes it a stand and not a coaster.
            Rectangle()
                .fill(wood(0.22))
                .frame(width: height * 0.22, height: max(2, height * 0.022))
            // Foot, widest, catching a rim of light on its top edge.
            ZStack(alignment: .top) {
                Capsule().fill(wood(0.26))
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: 1)
                    .padding(.horizontal, height * 0.03)
            }
            .frame(width: height * 0.40, height: max(3, height * 0.04))
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    /// Whether a photograph was bundled for this kind. Kinds without one keep
    /// their drawing, which is why the shelf works with ten of eleven.
    static func exists(for kind: ShelfObjectKind) -> Bool {
        ShelfObjectImageCache.shared.image(kind) != nil
    }
}

/// The object photographs, decoded once.
///
/// Each is a few hundred kilobytes of PNG with an alpha channel; decoding one
/// per redraw would cost more than the whole rest of the shelf. Loaded lazily,
/// because a shelf usually shows two or three kinds and paying for all eleven
/// at launch would be worse than not caching at all.
@MainActor
final class ShelfObjectImageCache {
    static let shared = ShelfObjectImageCache()

    private var loaded: [ShelfObjectKind: UIImage?] = [:]

    private init() {}

    func image(_ kind: ShelfObjectKind) -> UIImage? {
        if let hit = loaded[kind] { return hit }
        // `UIImage(named:)` searches the bundle's loose files as well as the
        // asset catalogue, which is where `fetch-object-images.py` puts these.
        let image = UIImage(named: kind.imageName)
        loaded[kind] = image
        return image
    }
}

extension ShelfObjectKind {
    /// Matches what `fetch-object-images.py` writes into `Models/`.
    var imageName: String { "shelf-\(rawValue)" }
}
