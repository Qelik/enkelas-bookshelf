import CoreGraphics
import Foundation
import Testing
@testable import BookshelfCore

/// The crop maths, and where photos are kept. Both are places a mistake is
/// silent: a wrong crop looks like a bad photo, and a wrong filename looks like
/// the app forgetting.
struct SpineCropTests {

    @Test("the guide is spine-shaped and centred")
    func guideIsCentred() {
        let bounds = CGSize(width: 400, height: 800)
        let rect = SpineCrop.guideRect(in: bounds)

        #expect(abs(rect.midX - bounds.width / 2) < 0.5)
        #expect(abs(rect.midY - bounds.height / 2) < 0.5)
        #expect(abs(rect.width / rect.height - SpineCrop.aspect) < 0.001)
        #expect(rect.height < bounds.height)
    }

    @Test("a short wide window still gets a guide that fits")
    func guideFitsWideBounds() {
        // Landscape, or an iPad split view: the height limit isn't the binding
        // one and an unconstrained guide would run off both sides.
        let bounds = CGSize(width: 200, height: 900)
        let rect = SpineCrop.guideRect(in: bounds)
        #expect(rect.width <= bounds.width)
        #expect(rect.height <= bounds.height)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
    }

    @Test("a zero-sized preview doesn't produce a nonsense guide")
    func guideHandlesZero() {
        // The first layout pass, before geometry resolves.
        #expect(SpineCrop.guideRect(in: .zero) == .zero)
    }

    // MARK: - Normalised → pixels

    @Test("a normalised rect maps onto the image")
    func mapsToPixels() {
        let rect = SpineCrop.pixelRect(
            from: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8),
            imageSize: CGSize(width: 4000, height: 3000)
        )
        #expect(rect == CGRect(x: 1000, y: 300, width: 2000, height: 2400))
    }

    @Test("a rect straying outside the image is clamped, not refused")
    func clampsToImage() {
        // `metadataOutputRectConverted` can return slightly-out-of-range values
        // when the guide touches an edge, and `CGImage.cropping(to:)` returns nil
        // for a rect that isn't fully inside — a capture that silently does
        // nothing.
        let rect = SpineCrop.pixelRect(
            from: CGRect(x: -0.05, y: -0.02, width: 0.5, height: 0.4),
            imageSize: CGSize(width: 1000, height: 1000)
        )
        let r = try! #require(rect)
        #expect(r.minX >= 0)
        #expect(r.minY >= 0)
        #expect(r.maxX <= 1000)
        #expect(r.maxY <= 1000)
    }

    @Test("a rect entirely off the image is refused rather than cropped to nothing")
    func rejectsDisjoint() {
        #expect(SpineCrop.pixelRect(from: CGRect(x: 2, y: 2, width: 0.5, height: 0.5),
                                    imageSize: CGSize(width: 100, height: 100)) == nil)
        #expect(SpineCrop.pixelRect(from: CGRect(x: 0, y: 0, width: 0.001, height: 0.001),
                                    imageSize: CGSize(width: 100, height: 100)) == nil)
        #expect(SpineCrop.pixelRect(from: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    imageSize: .zero) == nil)
    }

    // MARK: - Stored size

    @Test("a big crop is scaled down, a small one is left alone")
    func storedSizing() {
        let big = SpineCrop.storedSize(for: CGSize(width: 600, height: 2800))
        // Tolerance, not equality: the scale is a division and 2800 * (640/2800)
        // is not bit-identical to 640.
        #expect(abs(big.height - SpineCrop.storedHeight) < 0.5)
        #expect(abs(big.width / big.height - 600.0 / 2800.0) < 0.01)

        // Never enlarged: interpolating a small crop up spends bytes on nothing.
        let small = CGSize(width: 60, height: 240)
        #expect(SpineCrop.storedSize(for: small) == small)
    }
}

@MainActor
struct SpinePhotoStoreTests {

    static func store() -> (SpinePhotos, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spines-\(UUID().uuidString)")
        return (SpinePhotos(directory: dir), dir)
    }

    @Test("a photo saves, reads back and deletes")
    func roundTrip() {
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!photos.hasPhoto(for: "b1"))
        photos.save(Data([0xFF, 0xD8, 0xFF]), for: "b1")
        #expect(photos.hasPhoto(for: "b1"))
        #expect(photos.data(for: "b1") == Data([0xFF, 0xD8, 0xFF]))

        photos.delete(bookID: "b1")
        #expect(!photos.hasPhoto(for: "b1"))
        #expect(photos.data(for: "b1") == nil)
    }

    @Test("photos survive a relaunch")
    func survivesRelaunch() {
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        photos.save(Data([1, 2, 3]), for: "b1")

        // A filename derived from a per-process hash would be unfindable here,
        // which is why it isn't one.
        let reopened = SpinePhotos(directory: dir)
        #expect(reopened.hasPhoto(for: "b1"))
        #expect(reopened.data(for: "b1") == Data([1, 2, 3]))
    }

    @Test("a book id can't write outside the directory")
    func idsCannotEscape() {
        // Book ids come from imported JSON, which is to say from anywhere.
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }

        for hostile in ["../../../etc/passwd", "../escape", "/absolute/path", "a/b/c"] {
            let url = photos.url(for: hostile)
            // Compare paths, not URLs: `deletingLastPathComponent()` leaves a
            // trailing slash that `standardized` keeps, so the URLs differ
            // while naming the same directory.
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            #expect(parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == dir.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    "\(hostile) escaped to \(url.path)")
            #expect(!url.lastPathComponent.contains("/"))
        }
    }

    @Test("ids that sanitise to the same characters don't share a photo")
    func noCollisionAfterSanitising() {
        // "a/b" and "a-b" both strip to "a-b"; without the hash they'd be one
        // file and two books would show each other's picture.
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }

        photos.save(Data([1]), for: "a/b")
        photos.save(Data([2]), for: "a-b")
        #expect(photos.data(for: "a/b") == Data([1]))
        #expect(photos.data(for: "a-b") == Data([2]))
    }

    @Test("saving twice replaces rather than accumulating")
    func saveReplaces() {
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        photos.save(Data([1]), for: "b1")
        photos.save(Data([9, 9]), for: "b1")
        #expect(photos.data(for: "b1") == Data([9, 9]))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count == 1)
    }

    @Test("pruning drops photos for books that are gone, and keeps the rest")
    func pruning() {
        // Deleting a book doesn't reach into this store, so without pruning a
        // deleted book's photo stays on disk forever.
        let (photos, dir) = Self.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        photos.save(Data([1]), for: "keep")
        photos.save(Data([2]), for: "gone")

        photos.prune(keeping: ["keep"])
        #expect(photos.hasPhoto(for: "keep"))
        #expect(!photos.hasPhoto(for: "gone"))
    }
}
