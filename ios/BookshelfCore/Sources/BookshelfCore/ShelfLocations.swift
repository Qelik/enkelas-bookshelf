import Foundation

/// Where your physical copies actually are, in the room.
///
/// `book.location` has existed in the data model since the web app's Library Map
/// and never had a way to set it or read it back. This is the missing half: your
/// shelves as named places, so "where is my copy?" has an answer when you're
/// standing in front of the bookcase.
///
/// It's the one question a tracker is uniquely able to answer and none of them
/// do — Goodreads and StoryGraph model a *library*, not a room.
public struct ShelfLocation: Sendable, Hashable, Identifiable {
    /// The name as the reader first spelled it — see `WireState.shelfLocations`.
    public let name: String
    public let bookIDs: [String]

    public var id: String { name }
    public var count: Int { bookIDs.count }

    public init(name: String, bookIDs: [String]) {
        self.name = name
        self.bookIDs = bookIDs
    }
}

public extension WireState {

    /// Every named place, with the books on it.
    ///
    /// Grouped case- and diacritic-insensitively so "Living room" and "living
    /// room" are one shelf rather than two, keeping the first spelling seen —
    /// the same rule `allTags` uses, and for the same reason: a picker offering
    /// both spellings of a place invites a third.
    var shelfLocations: [ShelfLocation] {
        var order: [String] = []
        var groups: [String: (name: String, ids: [String])] = [:]
        for book in books {
            let name = book.location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = ShelfLocation.key(name)
            if groups[key] == nil {
                groups[key] = (name, [])
                order.append(key)
            }
            groups[key]?.ids.append(book.id)
        }
        return order
            .compactMap { groups[$0] }
            .map { ShelfLocation(name: $0.name, bookIDs: $0.ids) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The books on one shelf, in shelf order.
    func books(atLocation name: String) -> [WireBook] {
        let key = ShelfLocation.key(name)
        guard !key.isEmpty else { return [] }
        return books.filter { ShelfLocation.key($0.location) == key }
    }

    /// Physical copies you own that aren't on any named shelf yet.
    ///
    /// Surfaced rather than hidden: an unplaced pile is the work left to do, and
    /// a feature that only shows what's already tidy is no use to anyone who
    /// hasn't started.
    var booksWithoutLocation: [WireBook] {
        books.filter { $0.owned && $0.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Where this book is, if you've said. Empty string means nowhere yet.
    func location(ofBookID id: String) -> String {
        book(id: id)?.location.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public extension ShelfLocation {
    /// The comparison form of a place name.
    static func key(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

@MainActor
public extension BookshelfStore {

    /// Put a book somewhere, or take it off the shelf with an empty name.
    ///
    /// Marks the book owned as a side effect, because a book that is on a shelf
    /// in your house is a book you have. Without that the Owned filter and the
    /// shop scanner would disagree with the shelf you just put it on.
    func setLocation(bookID: String, to name: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.books[i].location = trimmed
            if !trimmed.isEmpty { state.books[i].owned = true }
        }
    }

    /// Move several books at once — for tidying a shelf in one pass rather than
    /// opening thirty book pages.
    func setLocation(bookIDs: some Collection<String>, to name: String) {
        let wanted = Set(bookIDs)
        guard !wanted.isEmpty else { return }
        commit { state in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            for i in state.books.indices where wanted.contains(state.books[i].id) {
                state.books[i].location = trimmed
                if !trimmed.isEmpty { state.books[i].owned = true }
            }
        }
    }

    /// Rename a shelf, moving everything on it.
    ///
    /// Renaming by editing one book at a time would leave the other twenty on a
    /// place that no longer exists — which is how you end up with "Bedroom" and
    /// "Bedroom shelf" side by side.
    func renameLocation(from old: String, to new: String) {
        let oldKey = ShelfLocation.key(old)
        guard !oldKey.isEmpty else { return }
        commit { state in
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            for i in state.books.indices where ShelfLocation.key(state.books[i].location) == oldKey {
                state.books[i].location = trimmed
            }
        }
    }
}
