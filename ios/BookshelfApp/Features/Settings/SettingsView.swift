import BookshelfCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(BookshelfStore.self) private var store

    @State private var showingAuth = false
    @State private var importing = false
    @State private var exporting = false
    @State private var pendingImport: WireState?
    @State private var message: Message?

    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    var body: some View {
        NavigationStack {
            List {
                AccountSection(showingAuth: $showingAuth)

                Section("Your shelf") {
                    LabeledContent("Books", value: "\(store.state.books.count)")
                    LabeledContent("Sessions logged", value: "\(store.state.books.reduce(0) { $0 + $1.logs.count })")
                    LabeledContent("Pages read", value: Int(store.state.totalPagesRead).formatted())
                    if let changed = ISO8601.date(from: store.state.updatedAt) {
                        LabeledContent("Last change", value: changed.formatted(.relative(presentation: .named)))
                    }
                }

                ThemeSection()

                RemindersSection()

                Section {
                    Button("Import a bookshelf…", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export a backup…", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(store.state.books.isEmpty)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Exports use the same format as the web app's ⬇ Export, so a backup moves either way.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("Reading stats and the built-in reader are still to come.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingAuth) { AuthView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $exporting,
                document: BookshelfDocument(state: store.state),
                contentType: .json,
                defaultFilename: "enkelas-bookshelf"
            ) { result in
                if case .failure(let error) = result {
                    message = Message(title: "Export failed", body: error.localizedDescription)
                }
            }
            // Importing replaces everything. That is what the web app does too,
            // but it is worth one tap of confirmation when the shelf being
            // replaced isn't empty.
            .alert("Replace your shelf?", isPresented: .constant(pendingImport != nil), presenting: pendingImport) { incoming in
                Button("Replace \(store.state.books.count) books", role: .destructive) {
                    store.replace(with: incoming)
                    pendingImport = nil
                    message = Message(title: "Imported", body: "\(incoming.books.count) books are on your shelf.")
                }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { incoming in
                Text("The file has \(incoming.books.count) books. Everything currently on this device is replaced — export a backup first if you're not sure.")
            }
            .alert(item: $message) { m in
                Alert(title: Text(m.title), message: Text(m.body), dismissButton: .default(Text("OK")))
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = Message(title: "Couldn't open that file", body: error.localizedDescription)
        case .success(let url):
            // A file picked from Files or iCloud is outside the sandbox; without
            // this the read fails with a bare "no such file", which reads as a
            // corrupt export rather than a permissions problem.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let incoming = try BookshelfImport.read(Data(contentsOf: url))
                if store.state.books.isEmpty {
                    store.replace(with: incoming)
                    message = Message(title: "Imported", body: "\(incoming.books.count) books are on your shelf.")
                } else {
                    pendingImport = incoming
                }
            } catch {
                message = Message(title: "Couldn't read that file", body: error.localizedDescription)
            }
        }
    }
}

/// The export file. Same bytes the web app's ⬇ Export writes, so a backup taken
/// on the phone imports into the browser and back.
struct BookshelfDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var state: WireState

    init(state: WireState) { self.state = state }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        state = try BookshelfImport.read(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try state.encodedJSON(prettyPrinted: true))
    }
}

extension BookStatus {
    var displayName: String {
        switch self {
        case .want: "Want to read"
        case .reading: "Reading"
        case .finished: "Finished"
        case .dnf: "Did not finish"
        }
    }
}
