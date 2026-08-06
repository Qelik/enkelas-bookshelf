import BookshelfCore
import SwiftUI
import UIKit

/// Decoded spine photos, kept in memory.
///
/// A shelf draws every visible spine on each pass, and decoding a JPEG per spine
/// per redraw would make scrolling crawl. `NSCache` because it evicts under
/// memory pressure on its own — a shelf of several hundred photographs is exactly
/// the case where holding them all would get the app killed.
@MainActor
final class SpineImageCache {
    static let shared = SpineImageCache()

    private let cache = NSCache<NSString, UIImage>()
    /// The revision the cache was filled at; a save or delete invalidates it.
    private var revision = -1

    private init() {
        cache.countLimit = 300
    }

    func image(for bookID: String, from photos: SpinePhotos) -> UIImage? {
        if photos.revision != revision {
            // Cheaper than tracking which id changed, and it happens only when a
            // photo is added or removed.
            cache.removeAllObjects()
            revision = photos.revision
        }
        let key = bookID as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = photos.data(for: bookID), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
