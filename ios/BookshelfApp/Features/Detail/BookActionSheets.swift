import BookshelfCore
import SwiftUI

/// The one-purpose sheets the book detail screen opens: finishing, re-reading,
/// giving up, bookmarking, lending, and adding a note.
///
/// Each mirrors a modal in the web app, and each writes through the store so the
/// finish/DNF/lend rules live in one place rather than in a view.

// MARK: - Finish / re-read

struct FinishBookView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Identifiable so `.sheet(item:)` rebuilds when switching between
    /// finishing and re-reading rather than reusing a stale form.
    enum Mode: String, Identifiable { case finish, reread; var id: String { rawValue } }

    let book: WireBook
    let mode: Mode

    @State private var rating: Double = 0
    @State private var date: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Finished", selection: $date, displayedComponents: .date)
                    RatingPicker(rating: $rating)
                } header: {
                    Text(book.title)
                } footer: {
                    if mode == .reread {
                        Text("This counts as read #\(Int(max(1, book.readCount)) + 1). Your pages aren't counted again — you've read them before.")
                    } else if book.totalPages > 0, book.pagesRead < book.totalPages {
                        // Say it before it happens: a silent 280-page log would
                        // look like a bug on the stats screen.
                        Text("The \(Int(book.totalPages - book.pagesRead)) pages you hadn't logged will be added so your totals are right.")
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(mode == .reread ? "Finished a re-read" : "Finished")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = rating > 0 ? rating : nil
                        switch mode {
                        case .finish: store.finish(bookID: book.id, rating: value, on: date)
                        case .reread: store.finishReread(bookID: book.id, rating: value, on: date)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                // A re-read is rated on its own; a first finish starts from
                // whatever you'd already given it.
                rating = mode == .reread ? 0 : (book.rating ?? 0)
            }
        }
    }
}

// MARK: - Did not finish

struct DNFView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let book: WireBook
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why did you stop? (optional)", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text(book.title)
                } footer: {
                    Text("It stays in your library with everything you logged — giving up on a book is part of the history, not a deletion.")
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Did not finish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.markDidNotFinish(bookID: book.id, reason: reason)
                        dismiss()
                    }
                }
            }
            .onAppear { reason = book.dnfReason }
        }
    }
}

// MARK: - Bookmark

struct BookmarkView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let book: WireBook
    @State private var page = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Page") {
                        TextField("Optional", text: $page)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    TextField("Note — where were you?", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text(book.title)
                } footer: {
                    Text("Leave both blank to remove the bookmark.")
                }

                if book.bookmark != nil {
                    Section {
                        Button("Remove bookmark", role: .destructive) {
                            store.clearBookmark(bookID: book.id)
                            dismiss()
                        }
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setBookmark(bookID: book.id, page: Double(page), note: note)
                        dismiss()
                    }
                }
            }
            .onAppear {
                page = book.bookmark?.page.map { String(Int($0)) } ?? ""
                note = book.bookmark?.note ?? ""
            }
        }
    }
}

// MARK: - Lending

struct LendView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let book: WireBook
    @State private var person = ""
    @State private var date: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Who has it?", text: $person)
                        .textInputAutocapitalization(.words)
                    DatePicker("Since", selection: $date, displayedComponents: .date)
                } header: {
                    Text(book.title)
                }

                if book.isLentOut {
                    Section {
                        Button("Mark as returned") {
                            store.markReturned(bookID: book.id)
                            dismiss()
                        }
                    } footer: {
                        if let days = book.daysLent() {
                            Text("Out for \(days) day\(days == 1 ? "" : "s").")
                        }
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Lend this book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.lend(bookID: book.id, to: person, on: date)
                        dismiss()
                    }
                    .disabled(person.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                person = book.lentTo
                date = book.lentAt.flatMap(ISO8601.date(from:)) ?? .now
            }
        }
    }
}

// MARK: - Notes

/// One sheet for all four note kinds — they differ only in their fields, and
/// four near-identical screens would be four places to fix a bug.
struct AddNoteView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, Identifiable, CaseIterable {
        case quote, journal, character, vocab
        var id: String { rawValue }

        var title: String {
            switch self {
            case .quote: "Save a quote"
            case .journal: "Journal entry"
            case .character: "Add a character"
            case .vocab: "Add a word"
            }
        }
        var symbol: String {
            switch self {
            case .quote: "quote.opening"
            case .journal: "text.book.closed"
            case .character: "person.text.rectangle"
            case .vocab: "character.book.closed"
            }
        }
        var label: String {
            switch self {
            case .quote: "Quote"
            case .journal: "Journal"
            case .character: "Character"
            case .vocab: "Word"
            }
        }
    }

    let book: WireBook
    let kind: Kind

    @State private var primary = ""
    @State private var secondary = ""
    @State private var page = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch kind {
                    case .quote:
                        TextField("The line", text: $primary, axis: .vertical).lineLimit(3...8)
                        pageField
                    case .journal:
                        TextField("What are you thinking?", text: $primary, axis: .vertical).lineLimit(3...8)
                        pageField
                    case .character:
                        TextField("Name", text: $primary)
                        TextField("Who are they?", text: $secondary, axis: .vertical).lineLimit(2...5)
                    case .vocab:
                        TextField("Word", text: $primary)
                        TextField("What does it mean?", text: $secondary, axis: .vertical).lineLimit(2...5)
                        pageField
                    }
                } header: {
                    Text(book.title)
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(primary.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var pageField: some View {
        LabeledContent("Page") {
            TextField("Optional", text: $page)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        let p = Double(page)
        switch kind {
        case .quote: store.addQuote(bookID: book.id, text: primary, page: p)
        case .journal: store.addJournalEntry(bookID: book.id, text: primary, page: p)
        case .character: store.addCharacter(bookID: book.id, name: primary, description: secondary)
        case .vocab: store.addVocab(bookID: book.id, word: primary, definition: secondary, page: p)
        }
        dismiss()
    }
}
