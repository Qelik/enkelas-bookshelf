import BookshelfCore
import SwiftUI

/// One book: where it is, how far in you are, and everything you've logged.
///
/// Reads the book back out of the store by id on every pass rather than holding
/// a copy, so logging a session updates this screen instead of leaving a stale
/// snapshot behind the sheet that made the change.
struct BookDetailView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let bookID: String
    @State private var logging = false
    @State private var editing: BookEditorTarget?
    @State private var confirmingDelete = false
    @State private var finishing: FinishBookView.Mode?
    @State private var markingDNF = false
    @State private var bookmarking = false
    @State private var lending = false
    @State private var addingNote: AddNoteView.Kind?

    private var book: WireBook? { store.state.book(id: bookID) }

    var body: some View {
        Group {
            if let book {
                List {
                    header(book)
                    if book.status == .reading { progressSection(book) }
                    actions(book)
                    details(book)
                    if book.isLentOut || book.bookmark != nil { statusStrip(book) }
                    if !book.review.isEmpty { review(book) }
                    notes(book)
                    sessions(book)
                }
                .listStyle(.insetGrouped)
                .navigationTitle(book.title)
                .navigationBarTitleDisplayMode(.inline)
                // Handoff: pick a book up on the iPad where you left it on the
                // phone. Not eligible for public indexing — see BookActivity.
                .userActivity(BookActivity.type) { activity in
                    BookActivity.configure(activity, with: book)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Edit", systemImage: "pencil") { editing = .existing(book) }
                            Button(book.owned ? "Not owned" : "Mark as owned",
                                   systemImage: book.owned ? "house.slash" : "house") {
                                store.toggleOwned(bookID: book.id)
                            }
                            Button(book.isLentOut ? "Lending…" : "Lend to someone",
                                   systemImage: "arrow.left.arrow.right") { lending = true }
                            if book.status == .finished {
                                Button("Finished a re-read", systemImage: "arrow.clockwise") {
                                    finishing = .reread
                                }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirmingDelete = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $logging) { LogSessionView(book: book) }
                .sheet(item: $editing) { BookEditorView(target: $0) }
                .sheet(item: $finishing) { FinishBookView(book: book, mode: $0) }
                .sheet(isPresented: $markingDNF) { DNFView(book: book) }
                .sheet(isPresented: $bookmarking) { BookmarkView(book: book) }
                .sheet(isPresented: $lending) { LendView(book: book) }
                .sheet(item: $addingNote) { AddNoteView(book: book, kind: $0) }
                .confirmationDialog(
                    "Delete “\(book.title)”?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete book", role: .destructive) {
                        store.delete(bookID: book.id)
                        dismiss()
                    }
                } message: {
                    // Deleting takes the reading history with it, which is the
                    // part people actually mind losing.
                    Text(book.logs.isEmpty
                         ? "This can't be undone."
                         : "This also deletes \(book.logs.count) logged session\(book.logs.count == 1 ? "" : "s"). This can't be undone.")
                }
            } else {
                // Reachable if the book is deleted while this screen is open.
                ContentUnavailableView("Book not found", systemImage: "questionmark.folder")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ book: WireBook) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                BookCover(book: book, width: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title).font(.title3.bold())
                    if !book.author.isEmpty {
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let rating = book.rating {
                        StarRating(rating: rating)
                    }
                    if !book.tags.isEmpty {
                        Text(book.tags.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func progressSection(_ book: WireBook) -> some View {
        Section("Progress") {
            if let progress = book.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(Int(book.pagesRead)) of \(Int(book.totalPages)) \(book.unitLabelShort)")
                        Spacer()
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                LabeledContent("Read so far", value: "\(Int(book.pagesRead)) \(book.unitLabelShort)")
            }

            if let estimate = book.estimatedFinish() {
                LabeledContent("Finishing around") {
                    Text(estimate.date, format: .dateTime.day().month(.abbreviated))
                        + Text(" · \(estimate.daysLeft) day\(estimate.daysLeft == 1 ? "" : "s")")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ book: WireBook) -> some View {
        Section {
            if book.status == .reading || book.status == .want {
                Button("Log a session", systemImage: "plus.circle.fill") { logging = true }
                Button("Bookmark where you are", systemImage: "bookmark") { bookmarking = true }
                // Finishing runs through its own sheet rather than the status
                // picker, because it also asks for a rating and tops up the
                // pages you never logged.
                Button("I finished it", systemImage: "checkmark.circle") { finishing = .finish }
                Button("Give up on it", systemImage: "xmark.circle") { markingDNF = true }
            }
            Picker("Status", selection: Binding(
                get: { book.status },
                set: { store.setStatus($0, for: book.id) }
            )) {
                ForEach(BookStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }

    @ViewBuilder
    private func details(_ book: WireBook) -> some View {
        Section("Details") {
            if book.totalPages > 0 {
                LabeledContent("Length", value: "\(Int(book.totalPages)) \(book.unitLabelShort)")
            }
            LabeledContent("Format", value: book.format.displayName)
            if !book.seriesName.isEmpty {
                LabeledContent("Series", value: book.seriesNumber.map { "\(book.seriesName) #\(JS.numberToString($0))" } ?? book.seriesName)
            }
            if let year = book.publishedYear {
                LabeledContent("Published", value: JS.numberToString(year))
            }
            if !book.isbn.isEmpty {
                LabeledContent("ISBN", value: book.isbn).font(.callout.monospaced())
            }
            if let started = book.startedDate {
                LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .omitted))
            }
            if let finished = book.finishedDate {
                LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .omitted))
            }
            if book.owned {
                LabeledContent("Owned", value: book.location.isEmpty ? "Yes" : book.location)
            }
            if book.readCount > 1 {
                LabeledContent("Read", value: "\(Int(book.readCount))×")
            }
            if let due = book.loanDueDate {
                LabeledContent("Library due", value: due.formatted(date: .abbreviated, time: .omitted))
            }
            if !book.dnfReason.isEmpty {
                LabeledContent("Stopped because", value: book.dnfReason)
            }
            if book.finishHistory.count > 1 {
                // Each finish, so a re-read shows its own date and rating rather
                // than being flattened into one.
                DisclosureGroup("Every time you finished it") {
                    ForEach(Array(book.finishHistory.enumerated()), id: \.offset) { _, record in
                        HStack {
                            Text(record.date.flatMap(ISO8601.date(from:))?
                                .formatted(date: .abbreviated, time: .omitted) ?? "Unknown date")
                            Spacer()
                            if let rating = record.rating {
                                Text("\(JS.numberToString(rating))★").foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func review(_ book: WireBook) -> some View {
        Section("Your review") {
            Text(book.review)
        }
    }

    /// What's true about the book right now that isn't progress — where you left
    /// off, and who has your copy.
    @ViewBuilder
    private func statusStrip(_ book: WireBook) -> some View {
        Section {
            if let bookmark = book.bookmark {
                Button { bookmarking = true } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.page.map { "Page \(Int($0))" } ?? "Bookmarked")
                                .foregroundStyle(.primary)
                            if !bookmark.note.isEmpty {
                                Text(bookmark.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if book.isLentOut {
                Button { lending = true } label: {
                    HStack {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lent to \(book.lentTo)").foregroundStyle(.primary)
                            if let days = book.daysLent() {
                                Text("\(days) day\(days == 1 ? "" : "s") ago")
                                    .font(.caption)
                                    // Amber past six weeks, matching the web app —
                                    // long enough that a nudge is fair.
                                    .foregroundStyle(days >= 45 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Quotes, journal, characters and vocabulary — the four kinds of note the
    /// web app keeps per book.
    @ViewBuilder
    private func notes(_ book: WireBook) -> some View {
        Section {
            Menu {
                ForEach(AddNoteView.Kind.allCases) { kind in
                    Button(kind.title, systemImage: kind.symbol) { addingNote = kind }
                }
            } label: {
                Label("Add a note", systemImage: "square.and.pencil")
            }
        } header: {
            Text("Notes")
        } footer: {
            if book.noteCount == 0 {
                Text("Quotes, journal entries, characters and words you looked up.")
            }
        }

        if !book.quotes.isEmpty {
            Section("Quotes") {
                ForEach(book.quotes, id: \.id) { quote in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{201C}\(quote.text)\u{201D}").italic()
                        if let page = quote.page {
                            Text("page \(JS.numberToString(page))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { deleteButton(.quote, book.id, quote.id) }
                }
            }
        }

        if !book.journal.isEmpty {
            Section("Journal") {
                ForEach(book.journal, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text)
                        HStack(spacing: 6) {
                            if let date = ISO8601.date(from: entry.date) {
                                Text(date, format: .dateTime.day().month(.abbreviated))
                            }
                            if let page = entry.page { Text("· page \(JS.numberToString(page))") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { deleteButton(.journal, book.id, entry.id) }
                }
            }
        }

        if !book.characters.isEmpty {
            Section("Characters") {
                ForEach(book.characters, id: \.id) { person in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.subheadline.weight(.medium))
                        if !person.desc.isEmpty {
                            Text(person.desc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { deleteButton(.character, book.id, person.id) }
                }
            }
        }

        if !book.vocab.isEmpty {
            Section("Words") {
                ForEach(book.vocab, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.word).font(.subheadline.weight(.medium))
                        if !entry.def.isEmpty {
                            Text(entry.def).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { deleteButton(.vocab, book.id, entry.id) }
                }
            }
        }
    }

    private func deleteButton(_ kind: BookshelfStore.NoteKind, _ bookID: String, _ noteID: String) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            store.deleteNote(kind, bookID: bookID, noteID: noteID)
        }
    }

    @ViewBuilder
    private func sessions(_ book: WireBook) -> some View {
        Section("Sessions") {
            if book.logs.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            } else {
                // Newest first: the last thing you did is the thing you want to
                // check or correct.
                ForEach(book.logs.sortedByDate().reversed(), id: \.id) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(Int(log.pages)) \(book.unitLabelShort)")
                                .font(.subheadline.weight(.medium))
                            if log.minutes > 0 {
                                Text("· \(Int(log.minutes)) min")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let date = ISO8601.date(from: log.date) {
                                Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !log.note.isEmpty {
                            Text(log.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.deleteLog(bookID: book.id, logID: log.id)
                        }
                    }
                }
            }
        }
    }
}

struct StarRating: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                // Half stars matter: the web app stores 4.5 and rounding it to 4
                // or 5 would visibly change someone's rating.
                Image(systemName: symbol(for: i))
                    .foregroundStyle(.orange)
            }
            Text(JS.numberToString(rating))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(JS.numberToString(rating)) out of 5")
    }

    private func symbol(for index: Int) -> String {
        let value = Double(index)
        if rating >= value { return "star.fill" }
        if rating >= value - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

extension BookFormat {
    var displayName: String {
        switch self {
        case .physical: "Physical"
        case .ebook: "E-book"
        case .audio: "Audiobook"
        }
    }

    var symbolName: String {
        switch self {
        case .physical: "book.closed"
        case .ebook: "ipad"
        case .audio: "headphones"
        }
    }
}
