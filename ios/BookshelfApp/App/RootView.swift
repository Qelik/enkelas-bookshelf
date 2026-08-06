import BookshelfCore
import CoreSpotlight
import SwiftUI

/// The tab shell.
///
/// Five tabs, and no more: a sixth makes iOS collapse the tail into a "More"
/// list, which buries whatever lands there.
///
/// The web app's four bottom-nav groups are Reading / Shelf / Progress /
/// Community, with the reader and settings reached from the header. Here the
/// reader earns a tab (it's a place you go to *do* something) and settings sits
/// behind a gear on the home screen, which is where the web app keeps it too.
struct RootView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(Router.self) private var router
    @Environment(ThemeStore.self) private var themes
    @State private var editing: BookEditorTarget?

    var body: some View {
        @Bindable var router = router

        // `.tabItem` rather than the iOS 18 `Tab {}` builder: the deployment
        // target is 17.0, and this shell is not worth a version bump.
        TabView(selection: $router.tab) {
            ReadingView(onAdd: { editing = .new(.reading) })
                .tabItem { Label("Reading", systemImage: "book") }
                .tag(RootTab.reading)
            ShelfView(onAdd: { editing = .new(.want) })
                .tabItem { Label("Shelf", systemImage: "books.vertical") }
                .tag(RootTab.shelf)
            EPUBShelfView()
                .tabItem { Label("Reader", systemImage: "book.pages") }
                .tag(RootTab.reader)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(RootTab.progress)
            CommunityView()
                .tabItem { Label("Community", systemImage: "star") }
                .tag(RootTab.community)
        }
        // A widget, a Spotlight hit and a Handoff from another device all land
        // here — see DeepLink for why they share one route.
        // The floating tab bar is its own material and ignores everything set
        // on the content behind it.
        .toolbarBackground(themes.theme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onOpenURL { router.follow(url: $0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
            else { return }
            router.follow(.book(id))
        }
        .onContinueUserActivity(BookActivity.type) { activity in
            guard let id = activity.userInfo?[BookActivity.bookIDKey] as? String else { return }
            router.follow(.book(id))
        }
        .sheet(item: $editing) { target in
            BookEditorView(target: target)
        }
        // Presented over everything: a divergence blocks sync until it's
        // answered, so burying it behind a Settings screen would leave someone
        // silently unsynced for days.
        .sheet(item: Bindable(sync).pendingConflict) { conflict in
            ConflictResolutionView(conflict: conflict)
        }
        .overlay(alignment: .top) {
            if let message = store.loadError {
                LoadErrorBanner(message: message)
            }
        }
    }
}

/// Shown when the shelf on disk couldn't be read. Loud on purpose: the app has
/// started with an empty shelf, and the next change would save that emptiness
/// over whatever is still in the file. The user needs to know before they touch
/// anything.
private struct LoadErrorBanner: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Couldn't open your bookshelf", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
            Text(message)
                .font(.caption)
            Text("Import a backup before making changes — saving now would replace the file.")
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }
}
