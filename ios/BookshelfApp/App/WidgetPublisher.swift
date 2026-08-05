import BookshelfCore
import Foundation
import WidgetKit

/// Keeps the widgets' snapshot in step with the shelf.
///
/// Derivation runs here rather than in the extension on purpose — see
/// `WidgetSnapshot`. Reloads are coalesced: a single edit in the app can commit
/// several times (mutate the book, then the log, then the settings), and asking
/// WidgetKit to reload on each one burns a budget that is measured in reloads
/// per day, not per second.
@MainActor
final class WidgetPublisher {

    private let store: BookshelfStore
    private let sync: SyncEngine
    private let themes: ThemeStore
    private var pending: Task<Void, Never>?
    private var lastPublished: WidgetSnapshot?

    init(store: BookshelfStore, sync: SyncEngine, themes: ThemeStore) {
        self.store = store
        self.sync = sync
        self.themes = themes
    }

    /// Publish soon. Safe to call on every commit.
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    /// Derive off the main actor. Building a snapshot walks every book and
    /// every session log — ~100 ms on a 12,000-session shelf — and this runs
    /// after every edit, so doing it on the main thread stuttered typing.
    private func publish() async {
        let state = store.state
        let title = sync.displayTitle
        let theme = themes.theme
        let snapshot = await Task.detached(priority: .utility) {
            WidgetSnapshot.make(from: state, title: title, theme: theme)
        }.value
        guard !Task.isCancelled else { return }
        write(snapshot)
    }

    /// Publish immediately, on this thread.
    ///
    /// For backgrounding only, where a detached task would die with the process
    /// before it finished. Everywhere else should use `schedule()`.
    func publishNow() {
        pending?.cancel()
        pending = nil
        write(WidgetSnapshot.make(
            from: store.state, title: sync.displayTitle, theme: themes.theme
        ))
    }

    private func write(_ snapshot: WidgetSnapshot) {
        // `updatedAt` moves every single time, so comparing whole snapshots
        // would never match. Everything a widget actually draws is compared
        // instead, which is what decides whether a reload would change a pixel.
        if let last = lastPublished, last.sameContent(as: snapshot) { return }
        lastPublished = snapshot
        WidgetSnapshotRefresh.write(snapshot)
    }
}

/// Publishing, without the app's live objects.
///
/// An App Intent runs in its own process with no `SyncEngine` and no view
/// hierarchy, but the widgets still have to catch up with what it changed.
@MainActor
enum WidgetSnapshotRefresh {

    /// `title` defaults to whatever was last published, so an intent doesn't
    /// reset a signed-in "Çelik's Bookshelf" to the generic name just because
    /// its process has no account loaded.
    static func publish(from store: BookshelfStore, title: String? = nil) {
        let name = title ?? WidgetSnapshot.published()?.title ?? "Bookshelf"
        write(WidgetSnapshot.make(from: store.state, title: name))
    }

    static func write(_ snapshot: WidgetSnapshot) {
        do {
            try snapshot.publish()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // A widget that can't be updated is not a reason to interrupt
            // someone logging a session.
        }
    }
}

private extension WidgetSnapshot {
    /// Everything except `updatedAt`.
    func sameContent(as other: WidgetSnapshot) -> Bool {
        reading == other.reading
            && streakCurrent == other.streakCurrent
            && streakLongest == other.streakLongest
            && readToday == other.readToday
            && pagesToday == other.pagesToday
            && pagesTargetToday == other.pagesTargetToday
            && goalTarget == other.goalTarget
            && goalDone == other.goalDone
            && goalYear == other.goalYear
            && goalExpected == other.goalExpected
            && title == other.title
            && theme == other.theme
    }
}
