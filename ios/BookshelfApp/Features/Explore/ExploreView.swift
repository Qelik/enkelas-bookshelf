import BookshelfCore
import SwiftUI

/// Find something to read next.
///
/// Lives inside `ShelfView` as its first section rather than as its own tab: it
/// shares the shelf's search field, and what you find here lands on the shelves
/// beside it. The field means "search the catalogue" while Explore is showing and
/// "search my books" everywhere else — one box, because two search fields on one
/// screen is worse than a prompt that changes.
struct ExploreView: View {
    @Environment(BookshelfStore.self) private var store

    /// Owned by `ShelfView`, so the segmented control and the search field stay in
    /// step. Empty means "browse", anything else means "search".
    let query: String

    /// A browse shelf. Trending is the catalogue's own feed; the rest are Open
    /// Library subject pages, whose slugs are not always the obvious word.
    struct Feed: Identifiable, Hashable {
        let label: String
        /// nil = the trending feed rather than a subject.
        let subject: String?
        var id: String { label }
    }

    static let feeds: [Feed] = [
        Feed(label: "Trending", subject: nil),
        Feed(label: "Fiction", subject: "fiction"),
        Feed(label: "Fantasy", subject: "fantasy"),
        Feed(label: "Romance", subject: "romance"),
        Feed(label: "Mystery", subject: "mystery"),
        Feed(label: "Thriller", subject: "thriller"),
        Feed(label: "Sci-fi", subject: "science_fiction"),
        Feed(label: "Historical", subject: "historical_fiction"),
        Feed(label: "Horror", subject: "horror"),
        Feed(label: "Young adult", subject: "young_adult_fiction"),
        Feed(label: "Classics", subject: "classics"),
        Feed(label: "Biography", subject: "biography"),
        Feed(label: "Poetry", subject: "poetry"),
    ]

    @State private var feed: Feed = ExploreView.feeds[0]
    @State private var books: [ExploreBook] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selected: ExploreBook?
    /// Titles added this visit, so a row can say so before the catalogue row and
    /// the new shelf entry have anything in common but a name.
    @State private var adding: Set<String> = []
    /// Which load is the current one.
    ///
    /// `.task(id:)` cancels the previous load, but cancellation is not a promise
    /// that its response won't arrive: a request for "The hobb" that Open Library
    /// answers slowly can land after the one for "The hobbit" and leave the screen
    /// full of hobby-horse books. Only the newest token may write.
    @State private var loadToken = 0

    @Environment(\.themeAccent) private var accent

    private let catalogue = OpenLibrary()

    /// Everything a load depends on. `.task(id:)` cancels the previous load when
    /// this changes, which is also what makes typing debounce rather than firing a
    /// request per keystroke.
    private struct Request: Equatable {
        var query: String
        var feed: String
    }

    var body: some View {
        content
            // spacing: 0 — the default gap in the safe area is painted by nobody
            // and shows as a white line. Same as the shelf picker above it.
            .safeAreaInset(edge: .top, spacing: 0) { if query.isEmpty { feedPicker } }
            .task(id: Request(query: query, feed: feed.id)) { await load() }
            .sheet(item: $selected) { book in
                ExploreDetailView(book: book, onShelf: onShelf(book)) { status, owned in
                    await add(book, as: status, owned: owned)
                }
            }
    }

    // MARK: - Chrome

    private var feedPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.feeds) { option in
                    let isCurrent = option == feed
                    Button(option.label) { feed = option }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        // One tint, two values: the accent marks the shelf you're
                        // on, grey the ones you aren't.
                        .tint(isCurrent ? accent : Color.gray)
                        .fontWeight(isCurrent ? .semibold : .regular)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if loading && books.isEmpty {
            ProgressView().themedState()
        } else if let failure, books.isEmpty {
            ContentUnavailableView {
                Label("Couldn't reach the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failure)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
                .themedState()
        } else if books.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to show", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("Try another shelf, or search for a title, an author or a subject.")
                }
                    .themedState()
            } else {
                ContentUnavailableView.search(text: query)
                    .themedState()
            }
        } else {
            List {
                ForEach(books) { book in
                    row(book)
                        .themedPlainRows()
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }

    private func row(_ book: ExploreBook) -> some View {
        Button {
            selected = book
        } label: {
            HStack(spacing: 12) {
                CatalogueCover(url: book.coverURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    if !book.author.isEmpty {
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let shelved = onShelf(book) {
                        Label(whereItIs(shelved), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    } else if !book.detailLine.isEmpty {
                        Text(book.detailLine).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                addControl(book)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func addControl(_ book: ExploreBook) -> some View {
        if adding.contains(book.id) {
            ProgressView()
        } else if onShelf(book) != nil {
            // Nothing: the row already says where it is, and a second copy of a
            // book you own is the one thing this screen exists to prevent.
            EmptyView()
        } else {
            Menu {
                Button("Want to read", systemImage: "bookmark") {
                    Task { await add(book, as: .want, owned: false) }
                }
                Button("Already read", systemImage: "books.vertical") {
                    Task { await add(book, as: .finished, owned: false) }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            // Stops the menu tap from also opening the detail sheet behind it.
            .buttonStyle(.plain)
        }
    }

    // MARK: - Loading

    /// Which feed the current query and chip name, and how long it stays fresh.
    private var request: (key: String, kind: ExploreCache.Kind) {
        if !query.isEmpty {
            (ExploreCache.key(search: query), .search)
        } else if let subject = feed.subject {
            (ExploreCache.key(subject: subject), .subject)
        } else {
            (ExploreCache.key(trending: .weekly), .trending)
        }
    }

    private func load() async {
        // Typing: wait long enough that a word doesn't cost five requests, and
        // long enough that a cache hit for a half-typed word never reaches the
        // screen. The sleep is cancelled by the next keystroke.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }

        let (key, kind) = request

        // Already seen it: on screen in this frame, no spinner and no clearing.
        if let cached = ExploreCache.shared.feed(key) {
            loadToken += 1
            books = cached.books
            failure = nil
            let age = Date().timeIntervalSince(cached.savedAt)
            guard age >= kind.ttl else { return }
            // Old enough to be worth checking, but the reader is already reading:
            // refresh underneath them rather than emptying the list first.
            await fetch(key: key, kind: kind, replacing: false)
            return
        }

        await fetch(key: key, kind: kind, replacing: true)
    }

    /// - Parameter replacing: whether to clear what's on screen first. True for a
    ///   feed nothing is cached for — leaving the previous chip's books up reads as
    ///   "this is Fantasy" when it isn't yet. False for a silent revalidation.
    private func fetch(key: String, kind: ExploreCache.Kind, replacing: Bool) async {
        loadToken += 1
        let token = loadToken
        if replacing {
            loading = true
            failure = nil
            books = []
        }
        // Only the newest load may report itself finished, or a stale one takes the
        // spinner away while the current one is still going.
        defer { if token == loadToken { loading = false } }

        do {
            let found: [ExploreBook]
            if !query.isEmpty {
                found = try await catalogue.discover(query)
            } else if let subject = feed.subject {
                found = try await catalogue.subject(subject)
            } else {
                found = try await catalogue.trending()
            }
            guard token == loadToken else { return }
            ExploreCache.shared.store(found, for: key, kind: kind)
            books = found
        } catch {
            guard token == loadToken else { return }
            // A failed *refresh* keeps what's already on screen: books that are
            // ten minutes old beat an error message about a book list.
            guard replacing else { return }
            books = []
            failure = error.localizedDescription
        }
    }

    // MARK: - Adding

    /// The shelf entry this catalogue row already corresponds to, if any.
    ///
    /// Matched on ISBN when both sides have one and on title plus author
    /// otherwise: the catalogue and a Goodreads import spell the same book
    /// differently often enough that an exact-string check would call almost
    /// nothing a duplicate.
    private func onShelf(_ book: ExploreBook) -> WireBook? {
        CatalogueAdd.onShelf(book, in: store.state)
    }

    private func whereItIs(_ book: WireBook) -> String {
        switch book.status {
        case .want: "On your want-to-read list"
        case .reading: "You're reading this"
        case .finished, .dnf: "In your library"
        }
    }

    private func add(_ book: ExploreBook, as status: BookStatus, owned: Bool) async {
        guard onShelf(book) == nil, !adding.contains(book.id) else { return }
        adding.insert(book.id)
        defer { adding.remove(book.id) }
        await CatalogueAdd.add(book, as: status, owned: owned, store: store, catalogue: catalogue)
    }
}

/// What the catalogue knows about one book, and the two decisions worth making
/// about it.
struct ExploreDetailView: View {
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    /// Held in state because it grows: a book that came from the community board
    /// arrives with a title, an author and a cover and nothing else, and the
    /// catalogue is asked for the rest once this screen opens.
    @State private var book: ExploreBook
    /// Set when this book is already on the shelf — then this screen is a
    /// reference rather than an add form.
    let onShelf: WireBook?
    /// Why somebody recommended it, when this book came from the board.
    let note: String?
    var onAdd: (BookStatus, Bool) async -> Void

    init(
        book: ExploreBook,
        onShelf: WireBook?,
        note: String? = nil,
        onAdd: @escaping (BookStatus, Bool) async -> Void
    ) {
        _book = State(initialValue: book)
        self.onShelf = onShelf
        self.note = note
        self.onAdd = onAdd
    }

    @State private var blurb: String?
    @State private var loadingBlurb = true
    @State private var owned = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    HStack(alignment: .top, spacing: 14) {
                        CoverImage(url: book.coverURL) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                                .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
                        }
                        .frame(width: 78, height: 117)
                        .clipShape(.rect(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.headline)
                            if !book.author.isEmpty {
                                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                            }
                            if !book.detailLine.isEmpty {
                                Text(book.detailLine).font(.caption).foregroundStyle(.tertiary)
                            }
                            if let editions = book.editions, editions > 1 {
                                Text("\(editions) editions")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let onShelf {
                    SwiftUI.Section {
                        Label(
                            "Already on your shelf as “\(onShelf.status.displayName)”",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    SwiftUI.Section {
                        Button {
                            add(.want)
                        } label: {
                            Label("Add to Want to Read", systemImage: "bookmark")
                        }
                        .disabled(busy)
                        Button {
                            add(.finished)
                        } label: {
                            Label("Add to Library — already read", systemImage: "books.vertical")
                        }
                        .disabled(busy)
                        // Per-button rather than on the Section: only the two adds
                        // are in flight while `busy`, and the switch should stay
                        // usable while one of them finishes.
                        Toggle("I own a copy", isOn: $owned)
                    } footer: {
                        Text("Owned books show up under the Owned filter in your library.")
                    }
                }

                // The recommender's own words come before the catalogue's: they're
                // the reason this book is on the board at all.
                if let note, !note.isEmpty {
                    SwiftUI.Section("Why they recommend it") {
                        Text(note).font(.callout)
                    }
                }

                if loadingBlurb {
                    SwiftUI.Section { ProgressView() }
                } else if let blurb {
                    SwiftUI.Section("About") { Text(blurb).font(.callout) }
                }

                if !book.subjects.isEmpty {
                    SwiftUI.Section("Subjects") {
                        Text(book.subjects.prefix(8).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Book")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                defer { loadingBlurb = false }
                // A recommendation carries no page count, no year and no work id, so
                // there is nothing to fetch a blurb *with* until the catalogue has
                // been asked. Free for a book that came from a feed already carrying
                // all three.
                book = await OpenLibrary().fill(book)
                guard let key = book.workKey else { return }
                // Already fetched in this sitting — most likely by the add flow, or
                // by opening this same book a moment ago.
                if ExploreCache.shared.knowsBlurb(for: key) {
                    blurb = ExploreCache.shared.blurb(for: key)
                    return
                }
                let fetched = await OpenLibrary().blurb(workKey: key)
                ExploreCache.shared.store(blurb: fetched, for: key)
                blurb = fetched
            }
        }
    }

    private func add(_ status: BookStatus) {
        busy = true
        Task {
            await onAdd(status, owned)
            dismiss()
        }
    }
}
