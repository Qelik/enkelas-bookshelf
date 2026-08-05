import AppIntents
import BookshelfCore
import Foundation

/// A book, as Siri and Shortcuts see it.
///
/// Intents run in a separate process from the app — there is no live
/// `BookshelfStore` to reach into, and no `@Environment`. Everything here loads
/// the shelf from disk, mutates it, and writes it back, which is why the store
/// was built around a `ShelfStorage` of closures rather than a singleton.
struct BookEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Book", numericFormat: "\(placeholder: .int) books"
    )
    static let defaultQuery = BookQuery()

    var id: String
    var title: String
    var author: String
    var currentPage: Int
    var pages: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.isEmpty ? nil : "\(author)"
        )
    }
}

struct BookQuery: EntityStringQuery {

    func entities(for identifiers: [BookEntity.ID]) async throws -> [BookEntity] {
        let books = await IntentShelf.load().state.books
        return identifiers.compactMap { id in
            books.first { $0.id == id }.map(BookEntity.init)
        }
    }

    /// What Siri matches spoken text against. Reuses the shelf's own `matches`,
    /// so "kingkiller" finds the book by its series exactly as typing it into
    /// the app's search field would.
    func entities(matching string: String) async throws -> [BookEntity] {
        await IntentShelf.load().state.books
            .filter { $0.matches(string) }
            .prefix(12)
            .map(BookEntity.init)
    }

    /// Offered when the user taps the parameter in Shortcuts. Currently-reading
    /// first: those are the ones anyone is about to log pages against.
    func suggestedEntities() async throws -> [BookEntity] {
        let books = await IntentShelf.load().state.books
        let reading = books.filter { $0.status == .reading }
        return (reading + books.filter { $0.status != .reading })
            .prefix(12)
            .map(BookEntity.init)
    }
}

extension BookEntity {
    init(_ book: WireBook) {
        self.init(
            id: book.id,
            title: book.title,
            author: book.author,
            currentPage: Int(book.pagesRead),
            pages: Int(book.totalPages)
        )
    }
}

/// The shelf, for an intent process.
///
/// Every intent reads fresh and writes immediately: an intent may run while the
/// app is not, or is suspended in the background, and holding state between
/// invocations would mean acting on a shelf another process has since changed.
@MainActor
enum IntentShelf {
    static func load() -> BookshelfStore {
        BookshelfStore()
    }

    /// Save without waiting for the debounce, then refresh the widgets — an
    /// intent's process can be torn down the moment it returns.
    static func commit(_ store: BookshelfStore) async {
        await store.saveNow()
        WidgetSnapshotRefresh.publish(from: store)
    }
}
