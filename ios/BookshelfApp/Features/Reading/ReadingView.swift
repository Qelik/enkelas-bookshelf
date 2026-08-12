import BookshelfCore
import SwiftUI

/// What you're reading right now — the screen the app opens on, and for most
/// sessions the only one anybody visits.
struct ReadingView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(SyncEngine.self) private var sync
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.themeAccent) private var accent
    var onAdd: () -> Void

    @State private var logging: WireBook?
    @State private var showingSettings = false
    @State private var scanning = false
    /// Book ids pushed on top of this tab. Owned here rather than by the router
    /// so ordinary taps stay plain `NavigationLink`s.
    @State private var path: [String] = []
    /// The iPad's detail pane. Separate from `path` because a split view keeps a
    /// selection where a stack keeps a history — the same book has to be
    /// expressible in both, and the two must not fight over which is showing.
    @State private var selected: String?

    var body: some View {
        // On an iPad the list and the book sit side by side; on a phone the book
        // is pushed. Same screens, and the same deep links land in both.
        if sizeClass == .regular {
            NavigationSplitView {
                bookList(selection: $selected)
                    .navigationTitle(sync.displayTitle)
                    .toolbarBackground(background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar { shellToolbar }
                    .attachShellSheets(
                        showingSettings: $showingSettings,
                        logging: $logging,
                        scanning: $scanning
                    )
            } detail: {
                NavigationStack {
                    if let selected {
                        BookDetailView(bookID: selected)
                    } else {
                        ContentUnavailableView(
                            "Pick a book", systemImage: "book",
                            description: Text("Choose something from the list to see its progress.")
                        )
                            .themedState()
                    }
                }
            }
            .onChange(of: router.openBook, initial: true) { _, id in
                guard let id, store.state.book(id: id) != nil else { return }
                selected = id
                router.openBook = nil
            }
        } else {
            stack
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            bookList(selection: nil)
            // "Çelik's Bookshelf" for whoever is signed in, the app's own name
            // otherwise — the same rule as renderTitle() in the web app. The
            // home-screen icon can't change; iOS gives an app no way to rename
            // itself at runtime.
            .navigationTitle(sync.displayTitle)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Settings lives here rather than in a sixth tab — see RootView.
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add a book", systemImage: "plus") {
                        Button("Scan a barcode", systemImage: "barcode.viewfinder") { scanning = true }
                        Button("Enter by hand", systemImage: "square.and.pencil", action: onAdd)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $scanning) { ScanBookView(status: .reading) }
            .sheet(item: $logging) { book in
                LogSessionView(book: book)
            }
            // A widget tap, a Spotlight hit or a Handoff asked for a book. Set
            // rather than appended: arriving from outside should land on that
            // book, not bury it under wherever the tab happened to be.
            .onChange(of: router.openBook, initial: true) { _, id in
                guard let id, store.state.book(id: id) != nil else { return }
                path = [id]
                router.openBook = nil
            }
        }
    }

    /// One list, two shells.
    ///
    /// With a `selection` binding it drives the split view's detail pane; with
    /// `nil` the rows are plain `NavigationLink`s that push. Written once so the
    /// two layouts can't drift into having different swipe actions.
    @ViewBuilder
    private func bookList(selection: Binding<String?>?) -> some View {
        if store.state.reading.isEmpty {
            ContentUnavailableView {
                Label("Nothing on the go", systemImage: "book")
            } description: {
                Text("Start a book and log your sessions as you read.")
            } actions: {
                Button("Add a book", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
                .themedState()
        } else if let selection {
            List(store.state.reading, id: \.id, selection: selection) { book in
                BookRow(book: book)
                    .tag(book.id)
                    .swipeActions(edge: .leading) {
                        Button("Log", systemImage: "plus.circle") { logging = book }
                            .tint(accent)
                    }
                    .themedPlainRows()
            }
        } else {
            List {
                ForEach(store.state.reading, id: \.id) { book in
                    NavigationLink(value: book.id) {
                        BookRow(book: book)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Log", systemImage: "plus.circle") { logging = book }
                            .tint(accent)
                    }
                    .themedPlainRows()
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Settings lives here rather than in a sixth tab — see RootView.
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Add a book", systemImage: "plus") {
                Button("Scan a barcode", systemImage: "barcode.viewfinder") { scanning = true }
                Button("Enter by hand", systemImage: "square.and.pencil", action: onAdd)
            }
        }
    }
}

private extension View {
    /// The sheets both shells present, attached in one place so adding one to
    /// the phone and forgetting the iPad isn't possible.
    func attachShellSheets(
        showingSettings: Binding<Bool>,
        logging: Binding<WireBook?>,
        scanning: Binding<Bool>
    ) -> some View {
        sheet(isPresented: showingSettings) { SettingsView() }
            .sheet(item: logging) { LogSessionView(book: $0) }
            .sheet(isPresented: scanning) { ScanBookView(status: .reading) }
    }
}

/// Log a reading session.
///
/// The field asks for the page you're *on*, not how many you read — that's what
/// a reader knows without doing arithmetic. The store turns it into the stored
/// per-session delta.
struct LogSessionView: View {
    @Environment(\.themeBackground) private var background
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Environment(ReadingTimer.self) private var timer

    let book: WireBook
    // Held as text, not a Double. `TextField(value:format:)` only writes back on
    // end-editing, so the "This session" readout below — the one thing that tells
    // you the number you typed means what you think — stayed at 0 until the field
    // lost focus, which is exactly when it stops being useful.
    @State private var pageText: String
    @State private var minutes: String = ""
    @State private var note: String = ""
    @State private var date: Date = .now

    init(book: WireBook) {
        self.book = book
        // Pre-filled with where they already were, so the common case is "nudge
        // it up and save" rather than typing a number from scratch.
        _pageText = State(initialValue: String(Int(book.pagesRead)))
    }

    private var currentPage: Double { Double(pageText) ?? book.pagesRead }
    private var delta: Double { max(0, currentPage - book.pagesRead) }
    /// What's typed plus whatever the running timer has counted.
    private var totalMinutes: Int { (Int(minutes) ?? 0) + (timer.isRunning(for: book.id) ? timer.elapsedMinutes : 0) }

    @ViewBuilder
    private var timerRow: some View {
        if timer.isRunning(for: book.id) {
            HStack {
                Label(timer.display, systemImage: "stopwatch")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.tint)
                Spacer()
                Button("Stop", systemImage: "stop.circle.fill") {
                    // Fold the counted time into the field rather than saving
                    // straight away — the reader may still want to fix the page.
                    minutes = String((Int(minutes) ?? 0) + timer.stop())
                    Task { await LiveActivityController.end() }
                }
                .labelStyle(.titleAndIcon)
            }
            // Redrawn each second by the timer's tick.
            .id(timer.tick)
        } else {
            Button("Start a timer", systemImage: "stopwatch") {
                let now = Date()
                timer.start(bookID: book.id, at: now)
                // The Lock Screen face of the same session — it reads the start
                // instant, so it stays right while the app is suspended.
                Task { await LiveActivityController.start(for: book, startedAt: now) }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Currently on") {
                        TextField("Page", text: $pageText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if book.totalPages > 0 {
                        LabeledContent("Of", value: "\(Int(book.totalPages)) \(book.unitLabelShort)")
                    }
                    // Shown because the stored value is the delta: if it says 0
                    // when they expected 40, the number above is wrong and this
                    // is where they find out — not three charts later.
                    LabeledContent("This session", value: "\(Int(delta)) \(book.unitLabelShort)")
                        .foregroundStyle(delta > 0 ? .primary : .secondary)
                } header: {
                    Text(book.title)
                }

                Section {
                    timerRow
                    LabeledContent("Minutes") {
                        TextField("Optional", text: $minutes)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("When", selection: $date)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .onAppear { timer.resume(for: book.id) }
            // pauseDisplay, not stop: closing the sheet must not discard a
            // running session — only Stop or saving does.
            .onDisappear { timer.pauseDisplay() }
            .themedPage()
            .themedRows()
            .navigationTitle("Log a session")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Saving ends the session — otherwise the same minutes
                        // get logged again on the next save.
                        if timer.isRunning(for: book.id) {
                            minutes = String(totalMinutes)
                            timer.stop()
                        }
                        Task { await LiveActivityController.end() }
                        store.logSession(
                            bookID: book.id,
                            currentPage: currentPage,
                            minutes: Double(minutes) ?? 0,
                            note: note,
                            at: date
                        )
                        Haptics.saved()
                        dismiss()
                    }
                }
            }
        }
    }
}

// Sheets keyed by the book being acted on. Identifiable via the book's own id,
// which is already unique across the shelf.
extension WireBook: @retroactive Identifiable {}
