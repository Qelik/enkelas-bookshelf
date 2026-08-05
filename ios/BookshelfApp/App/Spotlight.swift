import BookshelfCore
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Books in system search.
///
/// Someone who remembers a book but not that they tracked it in this app will
/// type the title into Spotlight, not open the app and search. Indexing costs
/// almost nothing and is the difference between the shelf being findable and
/// being a place you have to remember to look.
@MainActor
enum SpotlightIndex {

    nonisolated static let domain = "com.enkela.bookshelf.books"

    /// What the index was last built from, so an unchanged shelf costs nothing.
    ///
    /// This runs on every foreground. Without the guard, every trip back into the
    /// app deleted the whole domain and re-indexed every book — building a
    /// `CSSearchableItemAttributeSet` per book on the main actor — for a result
    /// that was already correct.
    private static var indexedUpdatedAt: String?

    /// Rebuild the index from the shelf.
    ///
    /// Deletes the domain first rather than reconciling: the index is derived
    /// data, a full rebuild is cheap at shelf sizes anyone actually has, and
    /// reconciling is how deleted books linger in search forever.
    static func rebuild(from state: WireState, force: Bool = false) async {
        guard force || state.updatedAt != indexedUpdatedAt else { return }
        indexedUpdatedAt = state.updatedAt

        // Only the shelf crosses the boundary, and it's `Sendable`. The items are
        // built *and* handed to Spotlight on the far side, because
        // `CSSearchableItem` is not `Sendable` and returning one here would be a
        // real race, not a paperwork problem.
        let indexed = await Task.detached(priority: .utility) {
            await reindex(state)
        }.value

        // Forget what we claimed to index when it failed, so the next attempt
        // retries instead of assuming success.
        if !indexed { indexedUpdatedAt = nil }
    }

    /// Build and submit, entirely off the main actor.
    nonisolated private static func reindex(_ state: WireState) async -> Bool {
        let items = state.books.map(item(for:))
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            guard !items.isEmpty else { return true }
            try await index.indexSearchableItems(items)
            return true
        } catch {
            // Spotlight being unavailable is not worth surfacing — nothing in the
            // app depends on it.
            return false
        }
    }

    nonisolated private static func item(for book: WireBook) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = book.title
        attributes.contentDescription = description(for: book)
        if !book.author.isEmpty { attributes.authorNames = [book.author] }
        // What Spotlight matches beyond the title: the series is often the only
        // thing someone remembers, and tags are the user's own words for it.
        attributes.keywords = ([book.seriesName] + book.tags + [book.author])
            .filter { !$0.isEmpty }
        attributes.contentCreationDate = book.addedDate

        let item = CSSearchableItem(
            uniqueIdentifier: book.id,
            domainIdentifier: domain,
            attributeSet: attributes
        )
        // Books don't go stale, and an expiring item quietly vanishing from
        // search would look like a bug.
        item.expirationDate = .distantFuture
        return item
    }

    nonisolated private static func description(for book: WireBook) -> String {
        var parts: [String] = []
        if !book.author.isEmpty { parts.append(book.author) }
        switch book.status {
        case .reading:
            let percent = Int((book.progress ?? 0) * 100)
            parts.append("Reading — \(percent)%")
        case .finished:
            parts.append("Finished")
        case .want:
            parts.append("Want to read")
        case .dnf:
            parts.append("Did not finish")
        }
        return parts.joined(separator: " · ")
    }
}

/// The Handoff activity for "this book, on this screen".
///
/// Continuing on another device is the one thing a bookshelf genuinely wants:
/// look something up on the phone, carry on with it on the iPad.
enum BookActivity {
    static let type = "com.enkela.bookshelf.viewing-book"
    static let bookIDKey = "bookID"

    static func configure(_ activity: NSUserActivity, with book: WireBook) {
        activity.title = book.title
        activity.userInfo = [bookIDKey: book.id]
        // Eligible for Handoff and for Siri suggestions, but *not* for public
        // indexing: what someone reads is nobody else's business, and a public
        // index is a search result on the open web.
        activity.isEligibleForHandoff = true
        activity.isEligibleForPrediction = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.persistentIdentifier = book.id
    }
}
