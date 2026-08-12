import Foundation

/// A cached value and when it was written.
public struct CachedPayload<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let savedAt: Date

    public init(value: Value, savedAt: Date = Date()) {
        self.value = value
        self.savedAt = savedAt
    }

    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(savedAt))
    }

    public func isStale(after ttl: TimeInterval, now: Date = Date()) -> Bool {
        age(now: now) >= ttl
    }
}

/// A JSON file in the Caches directory, for data that should be on screen
/// instantly and is safe to lose.
///
/// Deliberately *not* Application Support, which is where the shelf lives: this
/// is derived or re-fetchable data, and the system purging it under disk pressure
/// is the correct outcome. Nothing here is the only copy of anything.
///
/// Every read is "show this now, check later" — a cache hit is rendered
/// immediately and refreshed in the background rather than blocking on the
/// network. That's what makes a screen feel instant on the second visit and on a
/// cold launch, which is the whole point.
public struct DiskCache<Value: Codable & Sendable>: Sendable {

    private let filename: String

    public init(filename: String) {
        self.filename = filename
    }

    private var url: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = base.appendingPathComponent("bookshelf-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(filename)
    }

    /// Returns nil for "nothing cached" *and* for "cached in an older shape".
    ///
    /// A decode failure is not an error worth surfacing: the file is a cache, the
    /// value can be recomputed or re-fetched, and a stale shape after an app
    /// update is expected rather than exceptional.
    public func read() -> CachedPayload<Value>? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedPayload<Value>.self, from: data)
    }

    /// Fire-and-forget, off the main thread. A cache write must never make the
    /// screen that produced the value wait for the disk.
    public func write(_ value: Value, at date: Date = Date()) {
        let payload = CachedPayload(value: value, savedAt: date)
        guard let url else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Synchronous write, for a scene going into the background — a detached task
    /// scheduled at that moment may never run.
    public func writeNow(_ value: Value, at date: Date = Date()) {
        guard let url, let data = try? JSONEncoder().encode(CachedPayload(value: value, savedAt: date)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
