// `os(iOS)`, not `canImport(ActivityKit)`: the module *does* import on macOS, so
// the canImport guard passes and then `ActivityAttributes` fails as unavailable —
// which breaks `swift test`, the one thing this package exists to keep fast.
#if os(iOS)
import ActivityKit
import Foundation

/// The reading session, on the Lock Screen and in the Dynamic Island.
///
/// This is the payoff for `ReadingTimer` keeping an absolute start instant
/// rather than a tick count: the system draws the clock itself from
/// `Text(timerInterval:)`, so the running total stays right with the app
/// suspended, killed, or never woken again — nothing has to push an update once
/// a second, and the extension's budget is untouched.
///
/// Lives in `BookshelfCore` because the app and the widget extension must agree
/// on this type exactly; two copies that drift by one field stop matching and
/// the activity silently never appears.
public struct ReadingActivityAttributes: ActivityAttributes {

    /// Everything that changes while the session runs. Deliberately tiny — the
    /// elapsed time is *not* in here, because the system derives it.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Where the reader is now, when there's a page count to be somewhere in.
        public var page: Int?
        public var pages: Int?

        public init(page: Int? = nil, pages: Int? = nil) {
            self.page = page
            self.pages = pages
        }

        public var progress: Double? {
            guard let page, let pages, pages > 0 else { return nil }
            return min(1, max(0, Double(page) / Double(pages)))
        }
    }

    public var bookID: String
    public var title: String
    public var author: String
    /// The instant the session began — the same one `ReadingTimer` persisted.
    public var startedAt: Date
    public var hue: Int

    public init(bookID: String, title: String, author: String, startedAt: Date, hue: Int) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.startedAt = startedAt
        self.hue = hue
    }
}
#endif
