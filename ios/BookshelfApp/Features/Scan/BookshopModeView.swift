import BookshelfCore
import SwiftUI
import VisionKit

/// Point the camera at a book in a shop and get a verdict, not a search result.
///
/// The inversion this screen exists for: every other tracker is a record of what
/// you've read. This one is useful at the moment money changes hands — *you own
/// this already*, *it's on your want list*, *this is book three and book two is
/// still unread*, *you've given up on this author twice*.
///
/// Two decisions shape it. The verdict appears **before** the network does: an
/// ISBN match against your own shelf needs no lookup, which matters because
/// bookshops have terrible signal and "do I already own this" is the question
/// that most needs answering. And it stays scanning — you walk a table picking
/// things up, and a screen you have to dismiss between books is one you stop
/// using by the third.
struct BookshopModeView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    @State private var unavailable: BarcodeScanner.Unavailable?
    @State private var typed = ""
    @State private var stage: Stage = .waiting

    private enum Stage: Equatable {
        case waiting
        case looking(isbn: String)
        case verdict(ShelfVerdict)

        var isbn: String? {
            switch self {
            case .waiting: nil
            case .looking(let isbn): isbn
            case .verdict(let v): v.isbn
            }
        }
    }

    private let library = OpenLibrary()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let unavailable {
                    manualOnly(unavailable)
                } else {
                    camera
                }
                body(for: stage)
            }
            .themedPage()
            .themedRows()
            .navigationTitle("In a shop")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await prepare() }
        }
    }

    // MARK: - Camera

    private var camera: some View {
        ZStack(alignment: .bottom) {
            BarcodeScanner { isbn in
                // A barcode sits in frame for hundreds of frames; only act on a
                // code that isn't already the one on screen.
                guard stage.isbn != isbn else { return }
                Haptics.saved()
                Task { await check(isbn) }
            }
            .ignoresSafeArea(edges: .horizontal)

            Text("Point at the barcode on the back")
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: .capsule)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder
    private func manualOnly(_ reason: BarcodeScanner.Unavailable) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "barcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(reason.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if reason == .cameraDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Verdict

    @ViewBuilder
    private func body(for stage: Stage) -> some View {
        Form {
            Section {
                HStack {
                    TextField("ISBN", text: $typed)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .onSubmit(submitTyped)
                    Button("Check", action: submitTyped)
                        .disabled(ISBN.normalize(typed) == nil)
                }
            } header: {
                Text("Or type the number")
            } footer: {
                if !typed.isEmpty, ISBN.normalize(typed) == nil {
                    Text("That isn't a valid ISBN — check for a mistyped digit.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The 13-digit number under the barcode.")
                }
            }

            switch stage {
            case .waiting:
                Section {
                    Label("Scan a book and this tells you what your own shelves already know about it.",
                          systemImage: "sparkle.magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            case .looking(let isbn):
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking \(ISBN.formatted(isbn))…").foregroundStyle(.secondary)
                    }
                }

            case .verdict(let verdict):
                verdictSection(verdict)
            }
        }
    }

    @ViewBuilder
    private func verdictSection(_ verdict: ShelfVerdict) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(verdict.outcome))
                    .font(.title2)
                    .foregroundStyle(tint(verdict.outcome))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict.headline)
                        .font(.headline)
                        .foregroundStyle(tint(verdict.outcome))
                    Text(verdict.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            ForEach(verdict.notes) { note in
                Label {
                    Text(note.text).font(.footnote)
                } icon: {
                    Image(systemName: note.symbol).foregroundStyle(tint(note.tone))
                }
            }
        }

        Section {
            if let id = verdict.matchedBookID, let book = store.state.book(id: id) {
                NavigationLink("Open “\(book.title)”") { BookDetailView(bookID: id) }
                if !book.owned {
                    Button("I own it now", systemImage: "house") {
                        store.toggleOwned(bookID: id)
                        Haptics.unlocked()
                    }
                }
            } else {
                Button("Add to Want to Read", systemImage: "bookmark") {
                    add(verdict, owned: false)
                }
                // Bought it on the spot. Saves the second trip through the app
                // that otherwise follows every "yes" this screen gives.
                Button("I'm buying it — add as owned", systemImage: "bag") {
                    add(verdict, owned: true)
                }
            }
            Button("Scan another", systemImage: "arrow.clockwise") {
                stage = .waiting
                typed = ""
            }
        }
    }

    // MARK: - Presentation

    private func symbol(_ outcome: ShelfVerdict.Outcome) -> String {
        switch outcome {
        case .owned: "checkmark.circle.fill"
        case .onShelf(.want): "bookmark.circle.fill"
        case .onShelf(.reading): "book.circle.fill"
        case .onShelf(.finished): "checkmark.seal.fill"
        case .onShelf(.dnf): "xmark.circle.fill"
        case .new: "sparkles"
        }
    }

    private func tint(_ outcome: ShelfVerdict.Outcome) -> Color {
        switch outcome {
        // Amber, not red: owning it already isn't an error, it's a saved £9.
        case .owned: .orange
        case .onShelf: .blue
        case .new: .green
        }
    }

    private func tint(_ tone: ShelfVerdict.Note.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .warning: .orange
        }
    }

    // MARK: - Actions

    private func prepare() async {
        // Request first, then check: an undetermined permission reports as
        // available, so checking first opens a black rectangle behind the system
        // prompt.
        if DataScannerViewController.isSupported {
            _ = await BarcodeScanner.requestCameraAccess()
        }
        unavailable = BarcodeScanner.availability()
    }

    private func submitTyped() {
        guard let isbn = ISBN.normalize(typed) else { return }
        Task { await check(isbn) }
    }

    /// Verdict first from what's already on the device, then again with the
    /// catalogue's answer folded in.
    ///
    /// Two passes rather than one so a bad connection can't cost you the answer:
    /// an ISBN you own matches offline, and the shop's wifi only ever adds the
    /// title, the author and the series number on top.
    private func check(_ isbn: String) async {
        let offline = ShelfVerdict.make(isbn: isbn, catalogue: nil, state: store.state)
        stage = .verdict(offline)

        // Only worth a lookup when the shelf couldn't identify it — a match by
        // ISBN already knows more about the book than Open Library does.
        guard offline.matchedBookID == nil else { return }
        stage = .looking(isbn: isbn)

        // Concurrently: the search index has the title and author, the edition
        // record has the series. Neither has both, and waiting for them in turn
        // doubles the time somebody stands in an aisle looking at a spinner.
        async let search = library.search(title: "", isbn: isbn)
        async let edition = library.series(isbn: isbn)

        let hits = try? await search
        // Prefer the edition that actually lists this ISBN; a title search can
        // hand back a different one with a different page count.
        let best = hits?.first { ($0.isbn ?? []).contains { ISBN.normalize($0) == isbn } } ?? hits?.first
        let series = await edition
        // Guard against a slow lookup landing after the next book was scanned.
        guard stage.isbn == isbn else { return }
        stage = .verdict(ShelfVerdict.make(isbn: isbn, catalogue: best, series: series, state: store.state))
    }

    private func add(_ verdict: ShelfVerdict, owned: Bool) {
        var draft = NewBook.Draft()
        draft.title = verdict.title
        draft.author = verdict.author
        draft.isbn = verdict.isbn
        draft.status = .want
        draft.owned = owned
        // The series the verdict worked out, kept — it's what makes the *next*
        // scan of this series able to warn about reading order.
        draft.seriesName = verdict.seriesName
        draft.seriesNumber = verdict.seriesNumber
        guard let book = NewBook.make(draft) else { return }
        store.add(book: book)
        Haptics.unlocked()
        stage = .waiting
        typed = ""
    }
}
