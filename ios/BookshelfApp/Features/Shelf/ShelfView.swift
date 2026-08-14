import BookshelfCore
import SwiftUI

/// Explore / Want to Read / Library.
///
/// One screen with a segmented control rather than three tabs: the web app files
/// these as sub-navigation under a single "Shelf" group, and they share a search
/// field, a sort and a tag filter. Three tabs would triple the chrome for the
/// same list.
struct ShelfView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    var onAdd: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        /// The catalogue, not the shelf. First because finding a book comes before
        /// queueing it, and because it's the answer to "what next" — which is what
        /// somebody opening the Shelf tab with an empty list actually wants.
        case explore = "Explore"
        case want = "Want to Read"
        case library = "Library"
        var id: String { rawValue }

        /// Where a book scanned from this shelf should land.
        var status: BookStatus {
            switch self {
            // A book you're holding the barcode of is one you mean to read, wherever
            // you happened to be looking when you scanned it.
            case .explore, .want, .library: .want
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

    /// Owned used to be a shelf of its own, which split the library in two and
    /// meant a finished book you own appeared on neither list in full. It's a
    /// property of a book, so it belongs here with the other filters.
    enum Ownership: String, CaseIterable, Identifiable {
        case any = "All books"
        case owned = "Owned"
        case unowned = "Not owned"
        var id: String { rawValue }
    }

    @State private var section: Section = .want
    @State private var query = ""
    @State private var sort: Sort = .recent
    @State private var tag: String?
    @State private var ownership: Ownership = .any
    /// Narrows to books currently in someone else's hands. A toggle rather than a
    /// third state on `Ownership`: a book you lent out is one you own, so it reads
    /// as an extra condition, not an alternative to it.
    @State private var lentOut = false
    /// List or shelf. Sticks, because it's a preference about how you like to
    /// look at your books rather than a per-visit choice.
    @AppStorage("shelf-display") private var asShelf = false
    @State private var scanning = false
    @State private var shopping = false
    @State private var browsingShelves = false
    @State private var shelfie = false
    @State private var addingObject = false
    @State private var editingObject: EditingShelfObject?
    @State private var path: [String] = []

    /// The shelf, drawn as a shelf.
    ///
    /// Lifted out of `body` rather than inlined: with the objects added, the
    /// call has enough arguments that the type checker gave up on the whole
    /// view — "unable to type-check this expression in reasonable time" on a
    /// body that was already long.
    ///
    /// The bookcase always shows the arrangement you made, ignoring the Sort
    /// menu — the same rule the web app's shelf view uses. A shelf you arranged
    /// by hand and then find re-sorted by title isn't your shelf.
    private var bookcase: some View {
        BookshelfWallView(
            books: visibleBooks,
            objects: store.state.shelfObjects,
            order: store.state.shelfOrder,
            onReorder: { store.setShelfOrder(visible: $0) },
            onSelectObject: { editingObject = EditingShelfObject(id: $0) },
            onSelect: { path = [$0] }
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
            if section == .explore {
                ExploreView(query: query)
            } else if asShelf {
                bookcase
            } else {
            List {
                if !visibleBooks.isEmpty {
                    ForEach(visibleBooks, id: \.id) { book in
                        NavigationLink(value: book.id) {
                            BookRow(book: book)
                        }
                        .themedPlainRows()
                    }
                }
            }
            .listStyle(.plain)
            .themedPage()
            }
            }
            .overlay {
                if section != .explore, visibleBooks.isEmpty { emptyState }
            }
            // `spacing: 0`, because the default spacing is a gap in the *safe
            // area* — neither the inset's background nor the content's paints it,
            // so it showed as a white line under the picker. Obvious against the
            // dark bookcase, subtle but there against a list.
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Shelf", selection: $section) {
                    ForEach(Section.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                // `.bar` is the system's material, which stays grey whatever the
                // theme — the strip of white above the tinted content.
                .background(background)
            }
            // The same field, two meanings: on Explore it searches the catalogue,
            // everywhere else it searches your own books. The prompt is the only
            // thing that says which, so it has to change.
            .searchable(
                text: $query,
                prompt: section == .explore ? "Find a book to read" : "Title, author or tag"
            )
            // A catalogue query means nothing to your own books and vice versa, so
            // carrying it across the switch would silently filter the list you
            // just opened by whatever you last searched for.
            .onChange(of: section) { _, _ in query = "" }
            .navigationTitle("Shelf")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Inline, because the segmented control below already names the shelf
            // you're looking at. A large "Shelf" title on top of "Want to Read"
            // says the same thing twice and costs a third of the screen.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
            // The shelf that was on screen decides where a scanned book goes:
            // scanning from Want to Read means you want to read it.
            .sheet(isPresented: $scanning) { ScanBookView(status: section.status) }
            .sheet(isPresented: $shopping) { BookshopModeView() }
            .sheet(isPresented: $browsingShelves) { ShelfLocationsView() }
            .sheet(isPresented: $shelfie) { ShelfieImportView() }
            .sheet(isPresented: $addingObject) { ShelfObjectPicker() }
            .sheet(item: $editingObject) { ShelfObjectEditor(objectID: $0.id) }
            // Sorting, filtering and the bookcase are all about *your* books, so
            // they'd do nothing on Explore.
            .toolbar {
                if section != .explore {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Sort and filter", systemImage: "line.3.horizontal.decrease.circle") {
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Owned", selection: $ownership) {
                                ForEach(Ownership.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Toggle("Lent out", isOn: $lentOut)
                            Divider()
                            // Not a filter — a different question entirely
                            // ("where in the room is it?"), but it belongs with
                            // the other things you do to your own books.
                            Button("Where things are", systemImage: "mappin.and.ellipse") {
                                browsingShelves = true
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
                    // Only on the bookcase: a plant means nothing in a list, and
                    // an action that does nothing where it's shown is worse than
                    // one you have to go and find.
                    if asShelf {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Add something to the shelf", systemImage: "leaf") {
                                addingObject = true
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add a book", systemImage: "plus") {
                        Button("Scan a barcode", systemImage: "barcode.viewfinder") { scanning = true }
                        // The flagship import: a photo of a shelf beats typing
                        // in two hundred books, which is why most shelves never
                        // get catalogued at all.
                        Button("Scan a whole shelf", systemImage: "books.vertical") { shelfie = true }
                        Button("Enter by hand", systemImage: "square.and.pencil", action: onAdd)
                        Divider()
                        // Not adding a book — asking about one. Same camera,
                        // opposite question, so it sits with the other scan.
                        Button("In a shop?", systemImage: "bag") { shopping = true }
                    }
                }
            }
        }
    }

    // MARK: - Contents

    private var sourceBooks: [WireBook] {
        switch section {
        case .want: store.state.want
        case .library: store.state.library
        // Explore never reads this — its books aren't on the shelf yet.
        case .explore: []
        }
    }

    private var visibleBooks: [WireBook] {
        var books = sourceBooks.filter { $0.matches(query) }
        if let tag {
            books = books.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        switch ownership {
        case .any: break
        case .owned: books = books.filter(\.owned)
        case .unowned: books = books.filter { !$0.owned }
        }
        if lentOut {
            books = books.filter { !$0.lentTo.trimmingCharacters(in: .whitespaces).isEmpty }
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
        if !query.isEmpty || tag != nil || ownership != .any || lentOut {
            ContentUnavailableView.search
                .themedState()
        } else {
            switch section {
            case .explore:
                EmptyView()
            case .want:
                ContentUnavailableView {
                    Label("Nothing queued up", systemImage: "bookmark")
                } description: {
                    Text("Books you want to read next live here.")
                } actions: {
                    Button("Add a book", action: onAdd).buttonStyle(.borderedProminent)
                }
                    .themedState()
            case .library:
                ContentUnavailableView {
                    Label("No finished books yet", systemImage: "books.vertical")
                } description: {
                    Text("Books you finish — and ones you give up on — end up here.")
                }
                    .themedState()
            }
        }
    }
}
