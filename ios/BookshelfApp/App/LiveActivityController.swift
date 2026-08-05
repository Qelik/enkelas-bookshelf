import ActivityKit
import BookshelfCore
import Foundation

/// Starts and ends the reading-session Live Activity alongside `ReadingTimer`.
///
/// Kept out of `ReadingTimer` on purpose: the timer is in `BookshelfCore`, which
/// has no UIKit and no ActivityKit and is what lets `swift test` run on macOS
/// without a simulator. This is the iOS-only half.
///
/// Nothing here pushes updates on a schedule. The activity carries the session's
/// start instant and the system draws the clock from it, so a running session
/// stays correct on the Lock Screen with the app suspended or killed.
@MainActor
enum LiveActivityController {

    static func start(for book: WireBook, startedAt: Date) async {
        // Off in Settings, or unavailable on this device. Not an error — the
        // timer works regardless, this is only its Lock Screen face.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // One session at a time, and restarting the timer on a second book must
        // not leave the first book's card on the Lock Screen.
        await end()

        let attributes = ReadingActivityAttributes(
            bookID: book.id,
            title: book.title,
            author: book.author,
            startedAt: startedAt,
            hue: book.title.stableHue
        )
        let state = ReadingActivityAttributes.ContentState(
            page: Int(book.pagesRead),
            pages: book.totalPages > 0 ? Int(book.totalPages) : nil
        )
        _ = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: startedAt.addingTimeInterval(ReadingTimer.maximumSession)),
            pushType: nil
        )
    }

    /// Reflect a page change without restarting the session.
    ///
    /// `async` rather than fire-and-forget: an `Activity` is not `Sendable`, so
    /// handing one to a detached task is a data race the compiler rejects. Every
    /// call here stays on the main actor from start to finish.
    static func update(page: Int, of pages: Int?) async {
        guard let current = Activity<ReadingActivityAttributes>.activities.first else { return }
        await current.update(.init(state: .init(page: page, pages: pages), staleDate: nil))
    }

    static func end() async {
        for activity in Activity<ReadingActivityAttributes>.activities {
            // `.immediate`: the session is over, and a card that lingers on the
            // Lock Screen still counting is worse than none.
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
