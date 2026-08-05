import AppIntents
import BookshelfCore
import Foundation

/// "Log 30 pages in The Name of the Wind."
struct LogPagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Pages"
    static let description = IntentDescription(
        "Record pages read in a book.",
        categoryName: "Reading"
    )
    /// No need to bring the app forward: the whole point of the intent is not
    /// having to open it.
    static let openAppWhenRun = false

    @Parameter(title: "Book")
    var book: BookEntity

    @Parameter(title: "Pages", inclusiveRange: (1, 5000))
    var pages: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$pages) pages in \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = IntentShelf.load()
        guard let current = store.state.books.first(where: { $0.id == book.id }) else {
            throw IntentError.bookGone
        }

        // `logSession` takes the page you're *on*, not a delta — it derives the
        // delta itself so a re-run can't double-count.
        let target = current.pagesRead + Double(pages)
        store.logSession(bookID: book.id, currentPage: target)
        await IntentShelf.commit(store)

        let updated = store.state.books.first { $0.id == book.id }
        return .result(dialog: IntentDialog(summary(for: updated, added: pages)))
    }

    private func summary(for book: WireBook?, added: Int) -> LocalizedStringResource {
        guard let book else { return "Logged \(added) pages." }
        guard book.totalPages > 0 else {
            return "Logged \(added) pages in \(book.title)."
        }
        let percent = Int((book.progress ?? 0) * 100)
        let left = Int(book.pagesRemaining)
        if left == 0 {
            return "Logged \(added) pages. That's \(book.title) finished."
        }
        return "Logged \(added) pages in \(book.title) — \(percent)%, \(left) to go."
    }
}

/// "What am I reading?"
struct CurrentlyReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "What Am I Reading"
    static let description = IntentDescription(
        "Ask what's on the go right now.",
        categoryName: "Reading"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[BookEntity]> {
        let reading = IntentShelf.load().state.books.filter { $0.status == .reading }
        let entities = reading.map(BookEntity.init)

        guard let first = reading.first else {
            return .result(value: [], dialog: "Nothing on the go right now.")
        }
        let percent = Int((first.progress ?? 0) * 100)
        let dialog: LocalizedStringResource = reading.count == 1
            ? "You're reading \(first.title) — \(percent)% through."
            : "You're reading \(first.title) and \(reading.count - 1) more."
        return .result(value: entities, dialog: IntentDialog(dialog))
    }
}

/// "Start a reading session." Opens the book, because a session that isn't
/// visible is a session someone forgets is running.
struct StartReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Reading Session"
    static let description = IntentDescription(
        "Start the reading timer for a book and open it.",
        categoryName: "Reading"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Book")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start reading \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The timer's start instant is what everything else derives from, so
        // writing it here means the app resumes the same session on launch
        // rather than starting a second one.
        ReadingTimer().start(bookID: book.id)
        PendingDeepLink.set(.book(book.id))
        return .result(dialog: "Started reading \(book.title).")
    }
}

/// "Stop the reading session", logging the minutes against the book.
struct StopReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Reading Session"
    static let description = IntentDescription(
        "Stop the reading timer and log the time.",
        categoryName: "Reading"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let timer = ReadingTimer()
        guard let session = timer.pendingSession() else {
            return .result(dialog: "No reading session is running.")
        }
        let minutes = timer.stop()

        let store = IntentShelf.load()
        guard let book = store.state.books.first(where: { $0.id == session.bookID }) else {
            return .result(dialog: "Stopped the timer, but that book is no longer on the shelf.")
        }
        // Minutes only, no page change: the intent knows how long you read, not
        // where you got to, and inventing a page would corrupt the progress bar.
        store.logSession(bookID: book.id, currentPage: book.pagesRead, minutes: Double(minutes))
        await IntentShelf.commit(store)

        return .result(dialog: "Logged \(minutes) minutes on \(book.title).")
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case bookGone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .bookGone: "That book isn't on the shelf any more."
        }
    }
}

/// The phrases Siri accepts without the user building a shortcut first.
struct BookshelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CurrentlyReadingIntent(),
            phrases: [
                "What am I reading in \(.applicationName)",
                "What's on my \(.applicationName)",
            ],
            shortTitle: "What Am I Reading",
            systemImageName: "book"
        )
        AppShortcut(
            intent: StartReadingIntent(),
            phrases: [
                "Start a reading session in \(.applicationName)",
                "Start reading in \(.applicationName)",
            ],
            shortTitle: "Start Reading",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopReadingIntent(),
            phrases: [
                "Stop my reading session in \(.applicationName)",
                "Stop reading in \(.applicationName)",
            ],
            shortTitle: "Stop Reading",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: LogPagesIntent(),
            phrases: [
                "Log pages in \(.applicationName)",
                "Record pages in \(.applicationName)",
            ],
            shortTitle: "Log Pages",
            systemImageName: "text.book.closed"
        )
    }
}
