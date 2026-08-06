import BookshelfCore
import SwiftUI

/// Want to Read / Library / Owned.
///
/// One screen with a segmented control rather than three tabs: the web app files
/// these as sub-navigation under a single "Shelf" group, and they share a search
/// field, a sort and a tag filter. Three tabs would triple the chrome for the
/// same list.
struct ShelfView: View {
    @Environment(BookshelfStore.self) private var store
    var onAdd: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case want = "Want to Read"
        case library = "Library"
        case owned = "Owned"
        var id: String { rawValue }

        /// Where a book scanned from this shelf should land.
        var status: BookStatus {
            switch self {
            case .want: .want
            // Library and Owned are both places finished books live; a book
            // you just bought and scanned is one you mean to read.
            case .library, .owned: .want
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case title = "Title"
        case author = "Author"
        case rating = "Rating"
        case length = "Length"
        var id: String { rawValue }
    }

    @State private var section: Section = .want
    @State private var query = ""
    @State private var sort: Sort = .recent
    @State private var tag: String?
    /// List or shelf. Sticks, because it's a preference about how you like to
    /// look at your books rather than a per-visit choice.
    @AppStorage("shelf-display") private var asShelf = false
    @State private var scanning = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
            if asShelf {
                BookshelfWallView(books: visibleBooks) { path = [$0] }
            } else {
            List {
                if !visibleBooks.isEmpty {
                    ForEach(visibleBooks, id: \.id) { book in
                        NavigationLink(value: book.id) {
                            BookRow(book: book)
                        }
                    }
                }
            }
            .listStyle(.plain)
            }
            }
            .overlay {
                if visibleBooks.isEmpty { emptyState }
            }
            .safeAreaInset(edge: .top) {
                if !asShelf {
                    Picker("Shelf", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .searchable(text: $query, prompt: "Title, author or tag")
            .navigationTitle("Shelf")
            // Inline, because the segmented control below already names the shelf
            // you're looking at. A large "Shelf" title on top of "Want to Read"
            // says the same thing twice and costs a third of the screen.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
            // The shelf that was on screen decides where a scanned book goes:
            // scanning from Want to Read means you want to read it.
            .sheet(isPresented: $scanning) { ScanBookView(status: section.status) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Sort and filter", systemImage: "line.3.horizontal.decrease.circle") {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if !store.state.allTags.isEmpty {
                            Picker("Tag", selection: $tag) {
                                Text("All tags").tag(String?.none)
                                ForEach(store.state.allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        asShelf ? "Show as a list" : "Show as a shelf",
                        systemImage: asShelf ? "list.bullet" : "books.vertical"
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { asShelf.toggle() }
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add a book", systemImage: "plus") {
                        Button("Scan a barcode", systemImage: "barcode.viewfinder") { scanning = true }
                        Button("Enter by hand", systemImage: "square.and.pencil", action: onAdd)
                    }
                }
            }
        }
    }

    // MARK: - Contents

    private var sourceBooks: [WireBook] {
        // A real shelf holds everything, including the book currently in your
        // hand. Want / Library / Owned is a way of *managing* a list, and none of
        // those three sections contains `.reading` — so in shelf mode they'd hide
        // the one book you're most likely to have photographed.
        guard !asShelf else { return store.state.books }
        return switch section {
        case .want: store.state.want
        case .library: store.state.library
        case .owned: store.state.owned
        }
    }

    private var visibleBooks: [WireBook] {
        var books = sourceBooks.filter { $0.matches(query) }
        if let tag {
            books = books.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        return books.sorted(by: sortComparator)
    }

    private func sortComparator(_ a: WireBook, _ b: WireBook) -> Bool {
        switch sort {
        case .recent:
            // Library sorts by when you finished; the other shelves by when the
            // book arrived. Sorting a to-read pile by finish date would order it
            // by a field none of its books have.
            let ka = (section == .library ? a.libraryDate : a.addedDate) ?? .distantPast
            let kb = (section == .library ? b.libraryDate : b.addedDate) ?? .distantPast
            return ka > kb
        case .title:
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        case .author:
            // Books with no author sink rather than heading the list.
            if a.author.isEmpty != b.author.isEmpty { return !a.author.isEmpty }
            return a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
        case .rating:
            return (a.rating ?? -1) > (b.rating ?? -1)
        case .length:
            return a.totalPages > b.totalPages
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty || tag != nil {
            ContentUnavailableView.search
        } else {
            switch section {
            case .want:
                ContentUnavailableView {
                    Label("Nothing queued up", systemImage: "bookmark")
                } description: {
                    Text("Books you want to read next live here.")
                } actions: {
                    Button("Add a book", action: onAdd).buttonStyle(.borderedProminent)
                }
            case .library:
                ContentUnavailableView {
                    Label("No finished books yet", systemImage: "books.vertical")
                } description: {
                    Text("Books you finish — and ones you give up on — end up here.")
                }
            case .owned:
                ContentUnavailableView {
                    Label("Nothing marked as owned", systemImage: "house")
                } description: {
                    Text("Mark the books you own to check your shelf at home before buying a duplicate.")
                }
            }
        }
    }
}
