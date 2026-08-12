import BookshelfCore
import SwiftUI

/// The reading screen.
///
/// Chrome hides itself: a reader wants the page, not a toolbar. Tapping the
/// middle brings it back, the outer thirds turn pages.
struct ReaderView: View {
    @Environment(EPUBLibrary.self) private var library
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let recordID: String

    @State private var package: EPUBPackage?
    @State private var record: EPUBRecord?
    @State private var openError: String?

    @State private var chapter = 0
    @State private var page = 0
    @State private var pageCount = 1
    @State private var settings = ReaderSettings()

    @State private var chrome = true
    @State private var showingContents = false
    @State private var session = ReadingSession()
    /// How much of `session.activeSeconds` the ePub record has already been given.
    @State private var persistedSeconds: Double = 0
    @State private var summary: SessionSummary?
    @State private var seekOffset: Int?
    @State private var searching = false
    @State private var chapterText: [String] = []
    @State private var quoteSaved = false

    /// Emitted when the reader closes, so the sitting is worth reporting.
    struct SessionSummary: Identifiable {
        let id = UUID()
        let minutes: Int
        let pages: Int
        let progress: Double
        let linkedTitle: String?
    }

    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            settings.background.ignoresSafeArea()

            if let package {
                ReaderWebView(
                    package: package,
                    chapter: chapter,
                    settings: settings,
                    highlights: library.highlights(recordID: recordID, chapter: chapter),
                    seekOffset: $seekOffset,
                    page: $page,
                    pageCount: $pageCount,
                    canSaveQuote: record?.linkedBookID != nil,
                    onReady: {},
                    onTapEdge: handleTap,
                    onHighlight: highlight,
                    onSaveQuote: { saveQuote($0.text) }
                )
                .ignoresSafeArea()
            } else if let openError {
                ContentUnavailableView {
                    Label("Couldn't open this book", systemImage: "book.closed")
                } description: {
                    Text(openError)
                } actions: {
                    Button("Back") { dismiss() }
                }
                    .themedState()
            } else {
                ProgressView()
            }

            if chrome { chromeOverlay }
        }
        .statusBarHidden(!chrome)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        // The tab bar too: a reading screen is the page and nothing else, and
        // leaving it up also puts the app's chrome on top of the reader's own.
        .toolbar(.hidden, for: .tabBar)
        .task { await open() }
        .onReceive(clock) { _ in session.tick() }
        .onChange(of: pageCount) { _, count in
            // Turning back a chapter asks for "the last page", which isn't known
            // until that chapter has laid out. Left unclamped, the sentinel
            // leaks into pageFraction and the saved progress goes to nonsense.
            page = min(page, max(0, count - 1))
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is not reading, and the progress so far must survive
            // being killed while the app is away.
            if phase != .active {
                session.pause()
                persist()
            }
        }
        .onDisappear { finish() }
        .sheet(isPresented: $showingContents) {
            if let package, let record {
                ReaderDrawer(
                    package: package,
                    record: record,
                    current: chapter,
                    onChapter: { index in chapter = index; page = 0; showingContents = false },
                    onJump: { ch, offset in
                        chapter = ch
                        seekOffset = offset
                        showingContents = false
                    },
                    onRemoveBookmark: { library.removeBookmark(recordID: recordID, bookmarkID: $0); reloadRecord() },
                    onRemoveHighlight: { library.removeHighlight(recordID: recordID, highlightID: $0); reloadRecord() }
                )
            }
        }
        .sheet(isPresented: $searching) {
            if let package {
                ReaderSearchView(package: package, cachedText: chapterText) { result in
                    chapter = result.chapter
                    seekOffset = result.offset
                    searching = false
                }
            }
        }
        .overlay(alignment: .bottom) {
            if quoteSaved {
                Label("Saved to your book", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .sheet(item: $summary) { SessionSummaryView(summary: $0) }
    }

    // MARK: - Chrome

    private var chromeOverlay: some View {
        VStack {
            HStack(spacing: 18) {
                Button("Close", systemImage: "chevron.left") { dismiss() }
                    .labelStyle(.iconOnly)
                Spacer()
                Text(package?.spine[safe: chapter]?.title ?? record?.title ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Search", systemImage: "magnifyingglass") { searching = true }
                    .labelStyle(.iconOnly)
                Button(isBookmarked ? "Remove bookmark" : "Bookmark",
                       systemImage: isBookmarked ? "bookmark.fill" : "bookmark") {
                    toggleBookmark()
                }
                .labelStyle(.iconOnly)
                Button("Contents", systemImage: "list.bullet") { showingContents = true }
                    .labelStyle(.iconOnly)
                Menu {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ReaderSettings.Theme.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Larger text", systemImage: "textformat.size.larger") {
                        settings.fontSize = min(30, settings.fontSize + 1)
                    }
                    Button("Smaller text", systemImage: "textformat.size.smaller") {
                        settings.fontSize = max(13, settings.fontSize - 1)
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Spacer()

            VStack(spacing: 6) {
                ProgressView(value: bookProgress)
                    .tint(settings.ink.opacity(0.6))
                HStack {
                    Text("\(page + 1) / \(pageCount)")
                    Spacer()
                    if let left = timeLeft { Text(left) }
                    Spacer()
                    Text("\(Int(bookProgress * 100))%")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .transition(.opacity)
    }

    // MARK: - Selection
    //
    // Highlight and Save quote live in the system edit menu that appears with
    // the selection — see ReaderContentWebView. Copy, Look Up, Translate and
    // Share come from iOS and cost us nothing.

    private func highlight(_ selection: ReaderWebView.TextSelection) {
        library.addHighlight(
            recordID: recordID, chapter: chapter,
            start: selection.start, end: selection.end, text: selection.text
        )
        reloadRecord()
    }

    private var isBookmarked: Bool {
        library.isBookmarked(recordID: recordID, chapter: chapter, progress: pageFraction)
    }

    private func toggleBookmark() {
        library.toggleBookmark(
            recordID: recordID, chapter: chapter, progress: pageFraction,
            label: package?.spine[safe: chapter]?.title ?? "Chapter \(chapter + 1)",
            snippet: chapterText[safe: chapter].map { text in
                // A few words from where the bookmark sits, so the list is
                // recognisable rather than a row of page numbers.
                let start = min(text.count - 1, max(0, Int(Double(text.count) * pageFraction)))
                let from = text.index(text.startIndex, offsetBy: start)
                let rest = text[from...]
                let cut = String(rest.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Say it's cut rather than ending mid-word with no explanation.
                return cut.count < rest.count ? cut + "…" : cut
            } ?? ""
        )
        reloadRecord()
    }

    private func saveQuote(_ text: String) {
        guard let bookID = record?.linkedBookID else { return }
        store.addQuote(bookID: bookID, text: text, page: nil)
        withAnimation { quoteSaved = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { quoteSaved = false }
        }
    }

    private func reloadRecord() {
        record = library.record(id: recordID)
    }

    // MARK: - Progress

    /// Weighted by chapter length, not chapter count: a 40-page chapter and a
    /// 2-page one are not the same fraction of a book, and a bar that says
    /// otherwise is worse than no bar.
    private var bookProgress: Double {
        guard let record, let characters = record.chapterCharacters, !characters.isEmpty else {
            guard let package, package.spine.count > 1 else { return 0 }
            return (Double(chapter) + pageFraction) / Double(package.spine.count)
        }
        let total = Double(characters.reduce(0, +))
        guard total > 0 else { return 0 }
        let before = Double(characters.prefix(chapter).reduce(0, +))
        let current = Double(characters[safe: chapter] ?? 0) * pageFraction
        return min(1, (before + current) / total)
    }

    private var pageFraction: Double {
        pageCount > 1 ? Double(page) / Double(pageCount - 1) : 0
    }

    private var timeLeft: String? {
        guard let record, let characters = record.chapterCharacters, !characters.isEmpty else { return nil }
        let total = characters.reduce(0, +)
        let remaining = Int(Double(total) * (1 - bookProgress))
        return ReadingSession.timeLeftDescription(characters: remaining, at: record.charactersPerMinute)
    }

    private var charactersPerPage: Int {
        guard let record, let characters = record.chapterCharacters,
              let chapterChars = characters[safe: chapter], pageCount > 0
        else { return 0 }
        return chapterChars / max(1, pageCount)
    }

    // MARK: - Actions

    private func handleTap(_ side: Int) {
        switch side {
        case -1: turn(-1)
        case 1: turn(1)
        default: withAnimation(.easeInOut(duration: 0.15)) { chrome.toggle() }
        }
    }

    private func turn(_ direction: Int) {
        // A tap is activity whether or not there's a page to go to, so the clock
        // keeps running at the end of a book. Counting the page, though, waits for
        // the turn to actually happen — tapping forward on the last page is not a
        // page read, and the same goes for the haptic.
        session.markActivity()
        let next = page + direction
        if next < 0 {
            guard chapter > 0 else { return }
            countTurn()
            chapter -= 1
            // Landing on the last page of the previous chapter is what going
            // "back" means; page 0 would skip its whole content.
            page = Int.max
        } else if next >= pageCount {
            guard let package, chapter + 1 < package.spine.count else { return }
            countTurn()
            chapter += 1
            page = 0
        } else {
            countTurn()
            page = next
        }
        if chrome { withAnimation(.easeInOut(duration: 0.15)) { chrome = false } }
    }

    private func countTurn() {
        Haptics.pageTurn()
        session.countPage(characters: charactersPerPage)
    }

    // MARK: - Lifecycle

    private func open() async {
        guard let stored = library.record(id: recordID) else {
            openError = "That book isn't in your library any more."
            return
        }
        record = stored
        chapter = stored.chapter
        do {
            let opened = try library.open(stored)
            package = opened
            // Character counts drive both the progress bar and the time
            // estimate. Computing them means decompressing and stripping every
            // chapter, so it happens once, off the main thread, and is cached.
            if stored.chapterCharacters == nil {
                let texts = await Task.detached(priority: .userInitiated) {
                    (0..<opened.spine.count).map { (try? opened.plainText(forChapter: $0)) ?? "" }
                }.value
                chapterText = texts
                let counts = texts.map(\.count)
                record?.chapterCharacters = counts
                if var updated = record { updated.chapterCharacters = counts; library.update(updated) }
            } else {
                // Already counted, but search and bookmark snippets still want
                // the text — computed off the main thread, once.
                chapterText = await Task.detached(priority: .utility) {
                    (0..<opened.spine.count).map { (try? opened.plainText(forChapter: $0)) ?? "" }
                }.value
            }
            page = pageFor(stored.chapterProgress)
            session.markActivity()
        } catch {
            openError = error.localizedDescription
        }
    }

    private func pageFor(_ fraction: Double) -> Int {
        // pageCount isn't known until the chapter has laid out, so this is
        // refined once the web view reports back.
        Int((fraction * Double(max(1, pageCount - 1))).rounded())
    }

    private func persist() {
        guard var record else { return }
        record.chapter = chapter
        record.chapterProgress = pageFraction
        record.progress = bookProgress
        record.lastOpenedAt = ISO8601.string(from: Date())
        // Only the seconds this record hasn't been told about yet. `persist()` runs
        // on every backgrounding as well as on close, and adding the running total
        // each time counted the same sitting two or three times over — which is
        // what made "N min read" on the reader shelf drift upwards.
        //
        // A sitting that reset (a 15-minute lull) leaves the session's total lower
        // than what's already recorded; then all of it is new.
        let unrecorded = session.activeSeconds >= persistedSeconds
            ? session.activeSeconds - persistedSeconds
            : session.activeSeconds
        record.activeSeconds += unrecorded
        persistedSeconds = session.activeSeconds
        record.charactersPerMinute = ReadingSession.blend(
            stored: record.charactersPerMinute,
            measured: session.measuredCharactersPerMinute
        )
        library.update(record)
        self.record = record
    }

    private func finish() {
        session.pause()
        let minutes = Int(session.minutes.rounded())
        let pagesRead = session.pagesTurned
        persist()

        // A session in the reader is a session on the shelf — that is the whole
        // point of linking a book, and the reason the reader isn't a separate app.
        //
        // Logged on pages *or* minutes: a few pages read in under half a minute is
        // still a sitting, and it used to vanish.
        if let record, let bookID = record.linkedBookID, minutes > 0 || pagesRead > 0 {
            store.logReaderSession(
                bookID: bookID,
                pages: Double(pagesRead),
                minutes: Double(minutes),
                note: "📖 eReader session"
            )
        }
        if minutes > 0 || pagesRead > 0 {
            summary = SessionSummary(
                minutes: minutes,
                pages: max(0, pagesRead),
                progress: bookProgress,
                linkedTitle: record?.linkedBookID.flatMap { store.state.book(id: $0)?.title }
            )
        }
    }
}

/// Shown when the reader closes — what that sitting was worth.
struct SessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: ReaderView.SessionSummary

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.closed.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("\(summary.minutes) minute\(summary.minutes == 1 ? "" : "s") of reading")
                .font(.title3.bold())
            Text("\(Int(summary.progress * 100))% through the book")
                .foregroundStyle(.secondary)
            if let title = summary.linkedTitle {
                Text("Logged to “\(title)”")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .presentationDetents([.height(280)])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
