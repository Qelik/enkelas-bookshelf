import Foundation
import Testing
@testable import BookshelfCore

/// The cache everything instant is built on. Its contract is small but two parts
/// of it matter: a stale *shape* must read as "nothing cached" rather than
/// throwing, and the age has to be right or stale-while-revalidate revalidates
/// either never or always.
struct DiskCacheTests {

    /// A fresh filename per test — the cache is a real file in Caches, and tests
    /// sharing one would depend on each other's order.
    private func cache<T: Codable & Sendable>(_ type: T.Type = T.self, _ label: String) -> DiskCache<T> {
        DiskCache<T>(filename: "test-\(label)-\(UUID().uuidString).json")
    }

    @Test("a written value reads back")
    func roundTrips() throws {
        let cache = cache([String].self, "roundtrip")
        defer { cache.clear() }
        cache.writeNow(["Dune", "The Hobbit"])
        let payload = try #require(cache.read())
        #expect(payload.value == ["Dune", "The Hobbit"])
    }

    @Test("nothing cached is nil, not a crash")
    func missingIsNil() {
        #expect(cache([String].self, "missing").read() == nil)
    }

    @Test("a value written in an older shape reads as nothing cached")
    func staleShapeIsAMiss() {
        // Exactly what an app update does: yesterday's build cached `[String]`,
        // today's asks for `[Int]`. A throw here would surface as an error on a
        // screen that could simply have re-fetched.
        let name = "shape-\(UUID().uuidString).json"
        DiskCache<[String]>(filename: name).writeNow(["not a number"])
        defer { DiskCache<[Int]>(filename: name).clear() }
        #expect(DiskCache<[Int]>(filename: name).read() == nil)
    }

    @Test("age is measured from when it was written")
    func agesFromWriteTime() throws {
        let cache = cache(Int.self, "age")
        defer { cache.clear() }
        let hourAgo = Date().addingTimeInterval(-3600)
        cache.writeNow(7, at: hourAgo)

        let payload = try #require(cache.read())
        #expect(abs(payload.age() - 3600) < 5)
        #expect(payload.isStale(after: 30 * 60))
        #expect(!payload.isStale(after: 2 * 3600))
    }

    @Test("a clock that went backwards doesn't report a negative age")
    func neverNegative() throws {
        // Nothing sensible happens downstream if `age` can be negative — a TTL
        // check would call a future write permanently fresh.
        let cache = cache(Int.self, "future")
        defer { cache.clear() }
        cache.writeNow(1, at: Date().addingTimeInterval(600))
        #expect(try #require(cache.read()).age() == 0)
    }

    @Test("clearing removes it")
    func clears() {
        let cache = cache(String.self, "clear")
        cache.writeNow("gone")
        cache.clear()
        #expect(cache.read() == nil)
    }
}
