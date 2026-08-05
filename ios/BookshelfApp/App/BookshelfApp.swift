import BookshelfCore
import SwiftUI

@main
struct BookshelfApp: App {
    @State private var store: BookshelfStore
    @State private var sync: SyncEngine
    @State private var epubs = EPUBLibrary()
    @State private var timer = ReadingTimer()
    @State private var community: CommunityEngine
    @State private var router = Router()
    @State private var themes: ThemeStore
    @Environment(\.scenePhase) private var scenePhase

    private let widgets: WidgetPublisher

    init() {
        let store = BookshelfStore()
        let sync = SyncEngine(store: store)
        // Seeded with whoever was signed in last, so the app opens in the
        // right colour rather than flashing the default first.
        let themes = ThemeStore(accountID: sync.account?.id)
        let widgets = WidgetPublisher(store: store, sync: sync, themes: themes)
        themes.onThemeChanged {
            widgets.publishNow()
            // The Home Screen icon follows too. Fire-and-forget: the system
            // shows its own confirmation and nothing here depends on it.
            Task { await AppIconSwitcher.apply(themes.theme) }
        }
        // Every committed change schedules a (debounced) push, and refreshes what
        // the widgets read. The store stays ignorant of both; it just announces
        // that something changed.
        store.onCommit = { [weak sync] in
            sync?.schedulePush()
            widgets.schedule()
        }
        self.widgets = widgets
        _themes = State(initialValue: themes)
        _store = State(initialValue: store)
        _sync = State(initialValue: sync)
        _community = State(initialValue: CommunityEngine(
            client: SyncClient(
                baseURL: SyncClient.configuredBaseURL(),
                tokenProvider: TokenStore().read
            ),
            sync: sync
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                .environment(epubs)
                .environment(timer)
                .environment(community)
                .environment(router)
                .environment(themes)
                // One tint at the root drives every control below it. The
                // few places that named `.accentColor` explicitly had to be
                // changed to inherit — that static resolves to the asset
                // catalog and ignores `.tint` entirely.
                .tint(themes.theme.color)
                // The colour itself, for the few places that need it rather
                // than the ambient tint. A plain Color, not the store — see
                // ThemeColor.swift for why that distinction crashed the app.
                .environment(\.themeAccent, themes.theme.color)
                .task {
                    // An intent that opened the app said where to go; honour it
                    // before anything on the network has a chance to be slow.
                    router.followPending()
                    themes.accountChanged(to: sync.account?.id)
                    // Catch up with whatever happened on other devices while
                    // this one was closed.
                    await sync.pullIfStale()
                    // Then republish: a pull can change everything the widgets
                    // show and everything Spotlight has indexed without a single
                    // local commit having happened.
                    widgets.publishNow()
                    await SpotlightIndex.rebuild(from: store.state)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                router.followPending()
                // A sign-in or sign-out may have happened on another screen.
                themes.accountChanged(to: sync.account?.id)
                Task {
                    await sync.pullIfStale()
                    widgets.publishNow()
                    await SpotlightIndex.rebuild(from: store.state)
                    // Due dates change on other devices too, and a reminder for
                    // a book already returned is how notifications get muted.
                    if UserDefaults.standard.bool(forKey: "loan-reminders-on") {
                        await Reminders.refreshLoanReminders(from: store.state)
                    }
                }
            default:
                // All three are coalesced, so anything pending would die with
                // the process. Flush the disk write first — it is the copy that
                // must not be lost — then the network one, then the widgets,
                // which are the only one nothing breaks without.
                widgets.publishNow()
                Task {
                    await store.saveNow()
                    await sync.flush()
                }
            }
        }
    }
}
