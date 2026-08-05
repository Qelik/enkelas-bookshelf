import BookshelfCore
import SwiftUI
import VisionKit

/// Add a book by pointing the camera at the barcode on its back cover.
///
/// Structured around the fact that **the camera may not be available at all** —
/// no hardware support, permission denied, or the Simulator. Rather than treating
/// that as an error state, typing the number is a first-class path: it's the
/// fallback when a barcode is scuffed, and the only path on a device that can't
/// scan.
struct ScanBookView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Where a scanned book lands. Matches the shelf the user was looking at.
    let status: BookStatus

    @State private var unavailable: BarcodeScanner.Unavailable?
    @State private var typed = ""
    @State private var stage: Stage = .waiting
    @State private var added: [String] = []

    fileprivate enum Stage: Equatable {
        case waiting
        case looking(isbn: String)
        case found(isbn: String, doc: OpenLibrary.Doc)
        /// The barcode was valid but Open Library has nothing for it. Offering to
        /// add it by hand beats a dead end — the book exists, the catalogue just
        /// doesn't know it.
        case unknown(isbn: String)
        case failed(isbn: String, message: String)
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
                result
            }
            .navigationTitle("Scan a book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(added.isEmpty ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task { await prepare() }
        }
    }

    // MARK: - Camera

    private var camera: some View {
        ZStack(alignment: .bottom) {
            BarcodeScanner { isbn in
                // Ignore a code already on the shelf from this session rather
                // than looking it up again — a barcode sits in frame for
                // hundreds of frames.
                guard stage.isbn != isbn, !added.contains(isbn) else { return }
                Haptics.saved()
                Task { await look(up: isbn) }
            }
            .ignoresSafeArea(edges: .horizontal)

            Text("Point at the barcode on the back cover")
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: .capsule)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: 320)
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

    // MARK: - Result and manual entry

    @ViewBuilder
    private var result: some View {
        Form {
            Section {
                HStack {
                    TextField("ISBN", text: $typed)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .onSubmit(submitTyped)
                    Button("Find", action: submitTyped)
                        .disabled(ISBN.normalize(typed) == nil)
                }
            } header: {
                Text("Or type the number")
            } footer: {
                // Say why a number is refused *before* they hit Find, since the
                // check digit makes "looks like an ISBN" and "is one" differ.
                if !typed.isEmpty, ISBN.normalize(typed) == nil {
                    Text("That isn't a valid ISBN — check for a mistyped digit.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The 13-digit number under the barcode.")
                }
            }

            switch stage {
            case .waiting:
                EmptyView()

            case .looking(let isbn):
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up \(ISBN.formatted(isbn))…")
                            .foregroundStyle(.secondary)
                    }
                }

            case .found(let isbn, let doc):
                Section {
                    HStack(spacing: 12) {
                        CatalogueCover(url: doc.coverURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(doc.title ?? "Untitled").font(.headline)
                            if !doc.authorLine.isEmpty {
                                Text(doc.authorLine).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(detail(doc, isbn)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Button("Add to \(status.displayName)") { add(doc, isbn: isbn) }
                        .buttonStyle(.borderedProminent)
                }

            case .unknown(let isbn):
                Section {
                    Text("No catalogue entry for \(ISBN.formatted(isbn)).")
                        .foregroundStyle(.secondary)
                    Button("Add it by hand") { addBare(isbn: isbn) }
                }

            case .failed(let isbn, let message):
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("Try again") { Task { await look(up: isbn) } }
                }
            }

            if !added.isEmpty {
                Section("Added") {
                    ForEach(added, id: \.self) { title in
                        Label(title, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detail(_ doc: OpenLibrary.Doc, _ isbn: String) -> String {
        var parts: [String] = []
        if let pages = doc.number_of_pages_median { parts.append("\(pages) pages") }
        if let year = doc.first_publish_year { parts.append(String(year)) }
        parts.append(ISBN.formatted(isbn))
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func prepare() async {
        // Request first, then check. An undetermined permission reports as
        // available, so checking first would start the camera and show a black
        // rectangle behind the system prompt. Asking is a no-op once answered,
        // and pointless on a device that can't scan at all — hence the guard.
        if DataScannerViewController.isSupported {
            _ = await BarcodeScanner.requestCameraAccess()
        }
        unavailable = BarcodeScanner.availability()
    }

    private func submitTyped() {
        guard let isbn = ISBN.normalize(typed) else { return }
        Task { await look(up: isbn) }
    }

    private func look(up isbn: String) async {
        stage = .looking(isbn: isbn)
        do {
            let hits = try await library.search(title: "", isbn: isbn)
            // Prefer a hit that actually lists this ISBN: a bare title search can
            // return a different edition with a different page count.
            let best = hits.first { ($0.isbn ?? []).contains { ISBN.normalize($0) == isbn } } ?? hits.first
            stage = best.map { .found(isbn: isbn, doc: $0) } ?? .unknown(isbn: isbn)
        } catch {
            stage = .failed(isbn: isbn, message: error.localizedDescription)
        }
    }

    private func add(_ doc: OpenLibrary.Doc, isbn: String) {
        var draft = NewBook.Draft()
        draft.title = doc.title ?? "Untitled"
        draft.author = doc.authorLine
        draft.status = status
        draft.totalPages = doc.number_of_pages_median.map(Double.init)
        draft.isbn = isbn
        draft.coverURL = doc.coverURL?.absoluteString ?? ""
        draft.publishedYear = doc.first_publish_year.map(Double.init)
        // Open Library's subject list is long and noisy; the first entry is the
        // broad one and the rest are cataloguing detail nobody wants as a genre.
        draft.genre = doc.subject?.first ?? ""
        guard let book = NewBook.make(draft) else { return }
        store.add(book: book)
        finish(book.title)
    }

    private func addBare(isbn: String) {
        // Titled by its number so it's findable, and obviously needing a name.
        var draft = NewBook.Draft()
        draft.title = "Untitled (\(ISBN.formatted(isbn)))"
        draft.status = status
        draft.isbn = isbn
        guard let book = NewBook.make(draft) else { return }
        store.add(book: book)
        finish(book.title)
    }

    private func finish(_ title: String) {
        added.append(title)
        typed = ""
        stage = .waiting
        Haptics.unlocked()
    }
}

private extension ScanBookView.Stage {
    /// The ISBN this stage concerns, for de-duplicating repeat reads.
    var isbn: String? {
        switch self {
        case .waiting: nil
        case .looking(let i), .unknown(let i): i
        case .found(let i, _), .failed(let i, _): i
        }
    }
}

/// A cover straight from the catalogue, before the book exists on the shelf.
///
/// `BookCover` takes a `WireBook`, and there isn't one yet — the whole point of
/// this screen is deciding whether to create it.
struct CatalogueCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 46, height: 69)
        .clipShape(.rect(cornerRadius: 3))
    }
}
