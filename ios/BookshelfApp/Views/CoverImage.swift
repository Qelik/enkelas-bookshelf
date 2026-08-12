import ImageIO
import SwiftUI
import UIKit

/// Book covers: fetched once ever, decoded once per launch.
///
/// `AsyncImage` was doing neither. It holds no decoded image, so scrolling a shelf
/// back up re-decoded every cover and flashed a placeholder while it did; and it
/// uses the shared `URLCache`, which on iOS is a few megabytes — so the covers
/// were also being re-downloaded across launches.
///
/// Open Library helps here: cover responses come back `cache-control: public` with
/// an expiry in the next century, so a disk cache big enough to hold them means a
/// cover is fetched exactly once and is then available offline.
/// Covers draw at 78pt at the largest (the Explore sheet), so 3× that is plenty.
/// Decoding a 1000px JPEG down to this is most of the win: less work per image
/// *and* a quarter of the memory, which is what stops a long shelf evicting its own
/// covers while you scroll it.
///
/// Outside the cache because the decode runs off the main actor.
private let coverMaxPixelSize = 512

@MainActor
final class CoverCache {
    static let shared = CoverCache()

    /// Decoded and ready to draw. `NSCache` evicts under memory pressure by
    /// itself, which matters on a shelf of several hundred books.
    private let decoded = NSCache<NSURL, UIImage>()
    /// One request per URL, however many rows ask for it. A shelf and its book
    /// page show the same cover, and a scroll can ask for the same row twice.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    /// URLs known to have nothing behind them, so a coverless book doesn't
    /// re-request on every redraw for the rest of the session.
    private var missing: Set<URL> = []

    private let session: URLSession

    private init() {
        decoded.countLimit = 400
        decoded.totalCostLimit = 64 << 20        // 64 MB of pixels

        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 256 << 20, directory: nil)
        // The bytes never change — the URL contains the cover's id — so prefer the
        // disk copy without so much as a revalidation round-trip.
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// A cover that's ready right now. Lets a view render without a frame of
    /// placeholder first, which is the difference between "cached" and "instant".
    func ready(_ url: URL) -> UIImage? { decoded.object(forKey: url as NSURL) }

    func image(for url: URL) async -> UIImage? {
        if let hit = ready(url) { return hit }
        if missing.contains(url) { return nil }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
            return await Self.decode(data)?.image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            decoded.setObject(image, forKey: url as NSURL, cost: image.pixelCost)
        } else {
            missing.insert(url)
        }
        return image
    }

    /// Decode and downsample off the main thread.
    ///
    /// `UIImage` isn't `Sendable`, and the box is the usual way to hand one back
    /// from a detached task: this image is created here, never mutated, and read
    /// only on the main actor from then on.
    private struct Decoded: @unchecked Sendable { let image: UIImage }

    private static func decode(_ data: Data) async -> Decoded? {
        await Task.detached(priority: .userInitiated) {
            let source = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithData(data as CFData, source) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: coverMaxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Decode now, on this thread, rather than lazily on the first draw
                // — otherwise the cost lands back on the main thread anyway.
                kCGImageSourceShouldCacheImmediately: true,
            ] as [CFString: Any] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
            return Decoded(image: UIImage(cgImage: cg))
        }.value
    }
}

private extension UIImage {
    /// Roughly the bytes this image occupies, for `NSCache`'s cost accounting.
    var pixelCost: Int {
        Int(size.width * scale * size.height * scale * 4)
    }
}

/// A cover from the network, drawn from cache when there is one.
///
/// Reads the cache in `init` rather than in `.task`, so a warm cover is in the
/// first frame. Going through `.task` alone would still show one frame of
/// placeholder per row, which is exactly the flicker this replaces.
struct CoverImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    @MainActor
    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { CoverCache.shared.ready($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = CoverCache.shared.ready(url) { image = hit; return }
            image = await CoverCache.shared.image(for: url)
        }
    }
}
