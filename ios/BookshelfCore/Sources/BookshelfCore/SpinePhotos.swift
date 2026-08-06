import Foundation
import Observation

/// Photographs of real book spines, for the shelf.
///
/// **Stored as files on the device, not in the shelf blob.** The blob syncs and
/// the Worker rejects it over 8 MB; a couple of hundred spine photos as base64
/// would blow that ceiling and take the whole shelf offline with it. The blob is
/// a record of what you've read — an image of your copy is about this device.
///
/// The consequence is worth being straight about, in the UI as well as here: a
/// spine photo does not follow you to another phone.
@Observable
@MainActor
public final class SpinePhotos {

    /// Bumped when a photo is saved or removed, so views re-read.
    ///
    /// The images themselves live on disk and are cached as `UIImage`s by the
    /// app; this is only the signal that the cache is stale.
    public private(set) var revision = 0
    public private(set) var lastError: String?

    private let directory: URL
    /// What's on disk, so the shelf doesn't stat a file per spine on every
    /// redraw. Filenames rather than book ids, because that's what the directory
    /// can tell us without opening anything.
    private var filenames: Set<String> = []

    public init(directory: URL? = nil) {
        let base = directory ?? {
            let support = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL.temporaryDirectory
            return support.appending(path: "spines")
        }()
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Naming
    //
    // Book ids come from imported JSON, which is to say from anywhere. An id of
    // "../../Documents/x" would otherwise write outside the directory, so the
    // filename is derived rather than trusted.

    /// A filename that can only ever name a file inside `directory`.
    public static func filename(for bookID: String) -> String {
        let safe = bookID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" }
        var name = String(safe)
        // Two ids differing only in stripped characters would otherwise collide
        // and show each other's photograph.
        name += "-" + String(format: "%08x", bookID.stableFileHash)
        return name + ".jpg"
    }

    public func url(for bookID: String) -> URL {
        directory.appending(path: Self.filename(for: bookID))
    }

    // MARK: - Reading

    public func hasPhoto(for bookID: String) -> Bool {
        filenames.contains(Self.filename(for: bookID))
    }

    public func data(for bookID: String) -> Data? {
        guard hasPhoto(for: bookID) else { return nil }
        return try? Data(contentsOf: url(for: bookID))
    }

    // MARK: - Writing

    /// Replaces any existing photo for this book.
    public func save(_ data: Data, for bookID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: bookID), options: [.atomic])
            filenames.insert(Self.filename(for: bookID))
            revision &+= 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func delete(bookID: String) {
        try? FileManager.default.removeItem(at: url(for: bookID))
        filenames.remove(Self.filename(for: bookID))
        revision &+= 1
    }

    /// Drop photos for books that no longer exist.
    ///
    /// Deleting a book doesn't reach in here — the store knows nothing about
    /// photos — so without this a deleted book's picture stays on disk forever.
    public func prune(keeping bookIDs: some Collection<String>) {
        let keep = Set(bookIDs.map(Self.filename(for:)))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var removed = false
        for name in names where name.hasSuffix(".jpg") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
            removed = true
        }
        if removed { reload() }
    }

    private func reload() {
        filenames = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        revision &+= 1
    }
}

extension String {
    /// A stable hash for filenames. Deliberately not `hashValue`, which is seeded
    /// per process — a photo saved in one launch would be unfindable in the next.
    var stableFileHash: UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in utf8 {
            h = (h ^ UInt32(byte)) &* 16_777_619
        }
        return h
    }
}
