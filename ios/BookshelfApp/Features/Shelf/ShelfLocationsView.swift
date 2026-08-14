import BookshelfCore
import SwiftUI

/// Your shelves as places in the room, and what's on each one.
///
/// The question this answers — *where is my copy?* — is the one a reading
/// tracker is uniquely placed to answer and none of them do, because none of
/// them model the physical object. `book.location` has been in the data model
/// since the web app's Library Map with no way to set it or read it back; this
/// is the other half.
struct ShelfLocationsView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background

    /// Opened straight onto one book's shelf, from "Where is it?".
    var findingBookID: String?

    @State private var renaming: ShelfLocation?
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case shelf(name: String, highlight: String?)
        case unplaced
    }

    private var places: [ShelfLocation] { store.state.shelfLocations }
    private var unplaced: [WireBook] { store.state.booksWithoutLocation }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if places.isEmpty && unplaced.isEmpty {
                    ContentUnavailableView {
                        Label("No shelves yet", systemImage: "mappin.and.ellipse")
                    } description: {
                        Text("Say where a book lives — “Living room, top shelf” — and it'll show up here. Then you can find your copy without hunting for it.")
                    }
                    .themedState()
                } else {
                    list
                }
            }
            .navigationTitle("Where things are")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .shelf(let name, let highlight):
                    ShelfContentsView(locationName: name, highlight: highlight)
                case .unplaced:
                    UnplacedBooksView()
                }
            }
            .sheet(item: $renaming) { RenameLocationView(location: $0) }
            // Arriving from a book's "Where is it?": go straight to its shelf
            // with the spine picked out, rather than making somebody who asked a
            // specific question navigate to the answer.
            .onAppear {
                guard let findingBookID, path.isEmpty else { return }
                let where_ = store.state.location(ofBookID: findingBookID)
                guard !where_.isEmpty else { return }
                path = [.shelf(name: where_, highlight: findingBookID)]
            }
        }
    }

    private var list: some View {
        List {
            if !places.isEmpty {
                Section("Your shelves") {
                    ForEach(places) { place in
                        NavigationLink(value: Route.shelf(name: place.name, highlight: nil)) {
                            LabeledContent {
                                Text("\(place.count)").monospacedDigit()
                            } label: {
                                Label(place.name, systemImage: "books.vertical")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Rename", systemImage: "pencil") { renaming = place }
                        }
                    }
                }
            }
            if !unplaced.isEmpty {
                Section {
                    NavigationLink(value: Route.unplaced) {
                        LabeledContent {
                            Text("\(unplaced.count)").monospacedDigit()
                        } label: {
                            Label("Not placed yet", systemImage: "tray")
                        }
                    }
                } footer: {
                    Text("Books you own that haven't been given a shelf.")
                }
            }
        }
        .themedPage()
        .themedRows()
    }
}

/// One shelf, drawn as a shelf.
///
/// The bookcase rather than a list, because the point is to match what you're
/// looking at in the room — and with a book singled out when you came here
/// asking about a particular one.
private struct ShelfContentsView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background

    let locationName: String
    let highlight: String?

    @State private var selected: String?
    @State private var asList = false

    private var books: [WireBook] { store.state.books(atLocation: locationName) }

    var body: some View {
        Group {
            if asList {
                List {
                    ForEach(books, id: \.id) { book in
                        NavigationLink(value: book.id) { BookRow(book: book) }
                            .themedPlainRows()
                    }
                }
                .listStyle(.plain)
                .themedPage()
            } else {
                // Same arrangement as the main bookcase, and rearrangeable here
                // too — this is a real shelf in a room, so the order on screen
                // should be able to match the order on the wall. Not while
                // pointing a book out, though: there the shelf is an answer to
                // a question, not something to tidy.
                BookshelfWallView(
                    books: books,
                    objects: store.state.shelfObjects,
                    order: store.state.shelfOrder,
                    highlight: highlight,
                    onReorder: highlight == nil ? { store.setShelfOrder(visible: $0) } : nil
                ) { selected = $0 }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let highlight, let book = books.first(where: { $0.id == highlight }) {
                // Says which spine is lit. On a full shelf the highlight alone
                // leaves you comparing it against the title you had in mind.
                Label("“\(book.title)” is here", systemImage: "arrow.down")
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
        .navigationTitle(locationName)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
        .navigationDestination(item: $selected) { BookDetailView(bookID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    asList ? "Show as a shelf" : "Show as a list",
                    systemImage: asList ? "books.vertical" : "list.bullet"
                ) { withAnimation(.easeInOut(duration: 0.2)) { asList.toggle() } }
                .labelStyle(.iconOnly)
            }
        }
    }
}

/// Owned books with nowhere to be, and a way to place them in one pass.
private struct UnplacedBooksView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background

    @State private var chosen: Set<String> = []
    @State private var placing = false

    private var books: [WireBook] { store.state.booksWithoutLocation }

    var body: some View {
        List(books, id: \.id, selection: $chosen) { book in
            BookRow(book: book).themedPlainRows()
        }
        .listStyle(.plain)
        .themedPage()
        // Always on: this screen exists to move books, and making somebody find
        // an Edit button first is a step between them and the only thing here.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Not placed yet")
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !chosen.isEmpty {
                Button {
                    placing = true
                } label: {
                    Label("Put \(chosen.count) book\(chosen.count == 1 ? "" : "s") on a shelf", systemImage: "mappin")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.thinMaterial)
            }
        }
        .sheet(isPresented: $placing) {
            LocationPickerView(bookIDs: Array(chosen), current: "") { chosen = [] }
        }
    }
}

/// Rename a shelf, taking everything on it along.
private struct RenameLocationView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    let location: ShelfLocation
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Shelf name", text: $name)
                } footer: {
                    Text("All \(location.count) book\(location.count == 1 ? "" : "s") on this shelf move with it.")
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Rename shelf")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = location.name }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.renameLocation(from: location.name, to: name)
                        Haptics.saved()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Say where a book lives — picking a shelf you already have, or naming a new one.
struct LocationPickerView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    let bookIDs: [String]
    let current: String
    var onDone: () -> Void = {}

    @State private var typed = ""

    private var existing: [ShelfLocation] { store.state.shelfLocations }
    private var isMultiple: Bool { bookIDs.count > 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Living room, top shelf", text: $typed)
                        .autocorrectionDisabled()
                    Button("Put it here", systemImage: "mappin") { apply(typed) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(isMultiple ? "A shelf for \(bookIDs.count) books" : "A new shelf")
                }

                // Existing shelves first in practice, because after the first
                // few books this is the only section anybody uses.
                if !existing.isEmpty {
                    Section("Shelves you already have") {
                        ForEach(existing) { place in
                            Button {
                                apply(place.name)
                            } label: {
                                LabeledContent {
                                    if ShelfLocation.key(place.name) == ShelfLocation.key(current) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    } else {
                                        Text("\(place.count)").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                } label: {
                                    Label(place.name, systemImage: "books.vertical")
                                }
                            }
                        }
                    }
                }

                if !current.isEmpty, !isMultiple {
                    Section {
                        Button("Take it off the shelf", systemImage: "tray", role: .destructive) { apply("") }
                    } footer: {
                        Text("You'll still own it — you just won't have said where it is.")
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(isMultiple ? "Place books" : "Where is it?")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func apply(_ name: String) {
        if bookIDs.count == 1, let id = bookIDs.first {
            store.setLocation(bookID: id, to: name)
        } else {
            store.setLocation(bookIDs: bookIDs, to: name)
        }
        Haptics.saved()
        onDone()
        dismiss()
    }
}
