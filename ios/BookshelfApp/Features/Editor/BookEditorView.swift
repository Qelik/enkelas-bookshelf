import BookshelfCore
import SwiftUI

/// What the editor sheet is being opened for. `Identifiable` so `.sheet(item:)`
/// rebuilds when the target changes rather than reusing a stale form.
enum BookEditorTarget: Identifiable {
    case new(BookStatus)
    case existing(WireBook)

    var id: String {
        switch self {
        case .new(let status): "new-\(status.rawValue)"
        case .existing(let book): book.id
        }
    }
}

/// Add or edit a book.
///
/// The "Look up" button is the point of this screen: typing a title and getting
/// the author, page count, year and cover filled in is the difference between
/// adding a book in five seconds and giving up halfway.
struct BookEditorView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    let target: BookEditorTarget

    @State private var title = ""
    @State private var author = ""
    @State private var totalPages = ""
    @State private var isbn = ""
    @State private var coverUrl = ""
    @State private var seriesName = ""
    @State private var seriesNumber = ""
    @State private var tagText = ""
    @State private var review = ""
    @State private var format: BookFormat = .physical
    @State private var status: BookStatus = .want
    @State private var owned = false
    @State private var rating: Double = 0

    @State private var lookup = LookupState.idle
    @State private var candidates: [OpenLibrary.Doc] = []

    enum LookupState: Equatable {
        case idle, searching, failed(String), done
    }

    private var isEditing: Bool { if case .existing = target { true } else { false } }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("Author", text: $author)
                        .textInputAutocapitalization(.words)
                    lookupRow
                }

                if !candidates.isEmpty {
                    Section("Did you mean") {
                        ForEach(candidates.prefix(5), id: \.self) { doc in
                            Button { apply(doc) } label: { candidateRow(doc) }
                                .buttonStyle(.plain)
                        }
                    }
                }

                Section("Details") {
                    Picker("Format", selection: $format) {
                        ForEach(BookFormat.allCases, id: \.self) {
                            Label($0.displayName, systemImage: $0.symbolName).tag($0)
                        }
                    }
                    LabeledContent(format == .audio ? "Minutes" : "Pages") {
                        TextField("Optional", text: $totalPages)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("ISBN", text: $isbn)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Tags, comma separated", text: $tagText)
                        .textInputAutocapitalization(.words)
                }

                Section("Series") {
                    TextField("Series name", text: $seriesName)
                    LabeledContent("Number") {
                        TextField("Optional", text: $seriesNumber)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Shelf") {
                    Picker("Status", selection: $status) {
                        ForEach(BookStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("I own this", isOn: $owned)
                    if status == .finished || status == .dnf {
                        RatingPicker(rating: $rating)
                    }
                }

                if status == .finished || status == .dnf || !review.isEmpty {
                    Section("Review") {
                        TextField("What did you think?", text: $review, axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(isEditing ? "Edit book" : "Add a book")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Lookup

    @ViewBuilder
    private var lookupRow: some View {
        switch lookup {
        case .searching:
            HStack { ProgressView().controlSize(.small); Text("Looking up…").foregroundStyle(.secondary) }
        case .failed(let message):
            // Never blocks saving — a lookup failure is a missing convenience,
            // not a reason to lose what they typed.
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            Button("Look up details", systemImage: "sparkle.magnifyingglass") {
                Task { await runLookup() }
            }
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func candidateRow(_ doc: OpenLibrary.Doc) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: doc.coverURL) { $0.resizable().scaledToFill() } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 34, height: 51)
            .clipShape(.rect(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title ?? "Untitled").font(.subheadline).lineLimit(1)
                Text(doc.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let pages = doc.number_of_pages_median, let year = doc.first_publish_year {
                    Text("\(pages) pages · \(String(year))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
    }

    private func runLookup() async {
        lookup = .searching
        candidates = []
        let docs: [OpenLibrary.Doc]
        do {
            docs = try await OpenLibrary().search(title: title, author: author, isbn: isbn)
        } catch {
            // "Nothing found" and "the service is down" are opposite instructions
            // — one says type it in yourself, the other says try again shortly.
            // Open Library 504s under load, so this is not a rare path.
            lookup = .failed(error.localizedDescription)
            return
        }
        guard !docs.isEmpty else {
            lookup = .failed("Nothing found — you can still fill this in yourself.")
            return
        }
        candidates = docs
        lookup = .done
        // Apply the best match straight away. The list stays visible so a wrong
        // guess is one tap to correct, rather than making everyone pick from a
        // list when the first hit is usually right.
        if let best = docs.first { apply(best) }
    }

    private func apply(_ doc: OpenLibrary.Doc) {
        if let t = doc.title, !t.isEmpty { title = t }
        let authors = doc.authorLine
        if !authors.isEmpty { author = authors }
        if let pages = doc.number_of_pages_median, pages > 0, totalPages.isEmpty { totalPages = String(pages) }
        if isbn.isEmpty, let first = doc.isbn?.first { isbn = first }
        if let url = doc.coverURL { coverUrl = url.absoluteString }
        if tagText.isEmpty, let subjects = doc.subject {
            // Open Library subjects are long and noisy; a handful is a starting
            // point, the whole list is unusable.
            tagText = subjects.prefix(4).joined(separator: ", ")
        }
    }

    // MARK: - Load and save

    private func load() {
        guard case .existing(let book) = target else {
            if case .new(let s) = target { status = s }
            return
        }
        title = book.title
        author = book.author
        totalPages = book.totalPages > 0 ? String(Int(book.totalPages)) : ""
        isbn = book.isbn
        coverUrl = book.coverUrl
        seriesName = book.seriesName
        seriesNumber = book.seriesNumber.map { JS.numberToString($0) } ?? ""
        tagText = book.tags.joined(separator: ", ")
        review = book.review
        format = book.format
        status = book.status
        owned = book.owned
        rating = book.rating ?? 0
    }

    private func save() {
        let tags = tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Normalizer.isJunkTag($0) }

        switch target {
        case .existing(var book):
            book.title = title.trimmingCharacters(in: .whitespaces)
            book.author = author.trimmingCharacters(in: .whitespaces)
            book.totalPages = Double(totalPages) ?? 0
            book.isbn = isbn.trimmingCharacters(in: .whitespaces)
            book.coverUrl = coverUrl
            book.seriesName = seriesName.trimmingCharacters(in: .whitespaces)
            book.seriesNumber = Double(seriesNumber)
            book.tags = tags
            book.review = review
            book.format = format
            book.owned = owned
            // Zero stars means unrated, matching the web app — not a zero rating.
            book.rating = rating > 0 ? rating : nil
            store.update(book: book)
            // Status goes through the store so the started/finished stamps are
            // applied by the same code path as everywhere else.
            if book.status != status { store.setStatus(status, for: book.id) }

        case .new:
            // Through NewBook, which routes via normalize() so a book added here
            // is byte-identical in shape to one added in the browser — or by the
            // barcode scanner, which uses the same path.
            var draft = NewBook.Draft()
            draft.title = title
            draft.author = author
            draft.status = status
            draft.totalPages = Double(totalPages)
            draft.isbn = isbn
            draft.coverURL = coverUrl
            draft.seriesName = seriesName
            draft.seriesNumber = Double(seriesNumber)
            draft.review = review
            draft.format = format
            draft.owned = owned
            draft.rating = rating
            draft.tags = tags
            guard let book = NewBook.make(draft) else { return }
            store.add(book: book)
        }
        dismiss()
    }
}

/// Tap a star to rate; tap the one you already picked to clear it. Half stars are
/// reachable by dragging, because the web app stores 4.5 and this has to be able
/// to produce the same values.
struct RatingPicker: View {
    @Binding var rating: Double

    var body: some View {
        HStack {
            Text("Rating")
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: symbol(for: i))
                        .foregroundStyle(.orange)
                        .onTapGesture {
                            rating = (rating == Double(i)) ? 0 : Double(i)
                        }
                }
                if rating > 0 {
                    Button("Clear", systemImage: "xmark.circle.fill") { rating = 0 }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                }
            }
            .imageScale(.large)
            .gesture(halfStarDrag)
        }
    }

    private var halfStarDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 5 stars across the row; round to the nearest half.
                let starWidth: CGFloat = 28
                let raw = Double(value.location.x / starWidth)
                rating = min(5, max(0, (raw * 2).rounded() / 2))
            }
    }

    private func symbol(for index: Int) -> String {
        let value = Double(index)
        if rating >= value { return "star.fill" }
        if rating >= value - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}
