import BookshelfCore
import Foundation

/// The last Progress digest, kept for as long as the shelf it was built from.
///
/// `ProgressDigest.make` walks every book and every session log — the reason it
/// already runs off the main actor. What it didn't do was survive: every first
/// visit to Progress, and every trip away and back if SwiftUI had discarded the
/// view's state, paid for it again and showed zeros in the meantime.
///
/// Keyed on `updatedAt`, which moves on every commit — so a hit is by definition
/// still correct, and a miss is a shelf that genuinely changed.
@MainActor
final class DigestCache {
    static let shared = DigestCache()

    private var digest: ProgressDigest?

    private init() {}

    /// The digest for this exact shelf, or nil if the shelf has moved on.
    func digest(for updatedAt: String) -> ProgressDigest? {
        guard let digest, digest.sourceUpdatedAt == updatedAt else { return nil }
        return digest
    }

    /// Whatever was computed last, however old.
    ///
    /// For the frame before a fresh one arrives: last night's streak is a better
    /// first impression than a screen of zeros, and it's replaced within the same
    /// interaction.
    var latest: ProgressDigest? { digest }

    /// Derive off the main actor and remember the result.
    ///
    /// `WireState` is `Sendable` and the derivation is a pure function of it, so
    /// only the finished digest comes back.
    func make(from state: WireState) async -> ProgressDigest {
        if let hit = digest(for: state.updatedAt) { return hit }
        let fresh = await Task.detached(priority: .userInitiated) {
            ProgressDigest.make(from: state)
        }.value
        digest = fresh
        return fresh
    }

    /// Compute it before anyone asks. Called at launch, so the first tap on
    /// Progress draws a full screen rather than a placeholder.
    func warm(from state: WireState) async {
        _ = await make(from: state)
    }
}
