import BookshelfCore
import SwiftUI
import UniformTypeIdentifiers

/// The ePubs on this device.
struct EPUBShelfView: View {
    @Environment(EPUBLibrary.self) private var library
    @Environment(\.themeBackground) private var background
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeAccent) private var accent

    @State private var importing = false
    @State private var importError: String?
    @State private var linking: EPUBRecord?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("No ePubs yet", systemImage: "books.vertical")
                    } description: {
                        Text("Bring an .epub over from Files, Mail or Safari and read it here — your reading time is logged to the matching book on your shelf.")
                    } actions: {
                        Button("Add an ePub…") { importing = true }
                            .buttonStyle(.borderedProminent)
                    }
                        .themedState()
                } else {
                    List {
                        ForEach(library.books) { record in
                            NavigationLink(value: record.id) { row(record) }
                                .themedPlainRows()
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        library.delete(id: record.id)
                                    }
                                    Button("Link", systemImage: "link") { linking = record }
                                        .tint(accent)
                                }
                        }
                    }
                    .listStyle(.plain)
                    .themedPage()
                }
            }
            .themedPage()
            .navigationTitle("Reader")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // A large title vanishes entirely once the list has rows — the shelf
            // reads as an unlabelled list of books with no clue which tab it is.
            // Inline is also what every other tab does.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { ReaderView(recordID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add an ePub", systemImage: "plus") { importing = true }
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]
            ) { result in
                handleImport(result)
            }
            .sheet(item: $linking) { record in
                LinkBookView(record: record)
            }
            .alert("Couldn't add that book", isPresented: .constant(importError != nil), presenting: importError) { _ in
                Button("OK") { importError = nil }
            } message: { Text($0) }
        }
    }

    private func row(_ record: EPUBRecord) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(
                    colors: [
                        Color(hue: Double(record.title.stableHue) / 360, saturation: 0.35, brightness: 0.55),
                        Color(hue: Double(record.title.stableHue) / 360, saturation: 0.45, brightness: 0.38),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 40, height: 60)
                .overlay {
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(.white.opacity(0.85))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.headline).lineLimit(2)
                if !record.author.isEmpty {
                    Text(record.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if record.progress > 0 {
                    ProgressView(value: record.progress)
                }
                Text(subtitle(record))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(_ record: EPUBRecord) -> String {
        var parts: [String] = []
        if record.progress > 0 { parts.append("\(Int(record.progress * 100))%") }
        if record.activeSeconds >= 60 { parts.append("\(Int(record.activeSeconds / 60)) min read") }
        if let id = record.linkedBookID, let book = store.state.book(id: id) {
            parts.append("logs to “\(book.title)”")
        } else {
            parts.append("not linked to a book")
        }
        return parts.joined(separator: " · ")
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            do {
                let record = try library.import(from: url)
                // Offer the link straight away: an ePub that isn't attached to a
                // shelf book reads fine but logs nothing, which is the whole
                // point of reading it here rather than in Books.
                if store.state.books.contains(where: { !$0.title.isEmpty }) { linking = record }
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// Attach an ePub to a book on the shelf, so reading it logs sessions there.
struct LinkBookView: View {
    @Environment(\.themeBackground) private var background
    @Environment(EPUBLibrary.self) private var library
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let record: EPUBRecord
    @State private var query = ""

    private var candidates: [WireBook] {
        // Best guess first: a book whose title looks like the ePub's.
        let all = store.state.books.filter { $0.matches(query) }
        guard query.isEmpty else { return all }
        return all.sorted { a, b in
            similarity(a.title) > similarity(b.title)
        }
    }

    private func similarity(_ title: String) -> Int {
        let a = Set(title.lowercased().split(separator: " "))
        let b = Set(record.title.lowercased().split(separator: " "))
        return a.intersection(b).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.id) { book in
                        Button {
                            var updated = record
                            updated.linkedBookID = book.id
                            library.update(updated)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(book.title).foregroundStyle(.primary)
                                    if !book.author.isEmpty {
                                        Text(book.author).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if record.linkedBookID == book.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Log reading time to")
                } footer: {
                    Text("Minutes spent in the reader are added as sessions on the book you pick.")
                }

                if record.linkedBookID != nil {
                    Section {
                        Button("Unlink", role: .destructive) {
                            var updated = record
                            updated.linkedBookID = nil
                            library.update(updated)
                            dismiss()
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a book")
            .themedPage()
            .navigationTitle(record.title)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
            }
        }
    }
}
