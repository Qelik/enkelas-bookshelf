import BookshelfCore
import PhotosUI
import SwiftUI

/// Photograph a shelf, get your library.
///
/// The reason people abandon reading trackers is that nobody types in two
/// hundred books. Goodreads has no answer to this, and the cataloguing apps do
/// one barcode at a time — which a spine doesn't have.
///
/// **The review list is the feature.** OCR on a worn spine is wrong often
/// enough that adding what it guessed would quietly corrupt a library that took
/// years to build, so nothing is added until it's confirmed, every row shows the
/// crop it came from and the text read off it, and books already on the shelf
/// are marked as such rather than doubled.
struct ShelfieImportView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    /// Where confirmed books land, and optionally which shelf they go on — a
    /// shelfie *is* a location, which is what pairs this with "where things are".
    var location: String = ""

    @State private var stage: Stage = .choosing
    @State private var photo: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var candidates: [ShelfieCandidate] = []
    @State private var matching = false
    @State private var shelfName = ""
    @State private var added = 0

    private enum Stage: Equatable {
        case choosing
        case reading
        case reviewing
        case done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choosing: chooser
                case .reading: reading
                case .reviewing: review
                case .done: finished
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Scan a shelf")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .done ? "Done" : "Cancel") { dismiss() }
                }
                if stage == .reviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(keeping.count)") { commit() }
                            .disabled(keeping.isEmpty)
                    }
                }
            }
            .onAppear { shelfName = location }
            .photosPicker(isPresented: .constant(false), selection: $picked)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                ShelfCameraPicker { image in
                    photo = image
                    Task { await run(image) }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Choosing a photo

    private var chooser: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Point at a shelf")
                    .font(.title3.bold())
                Text("One photo, straight on, with the spines filling the frame. You'll get a list to confirm — nothing is added until you say so.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take a photo", systemImage: "camera") { takingPhoto = true }
                        .buttonStyle(.borderedProminent)
                }
                // Not a fallback for the Simulator — plenty of people already
                // have photographs of their shelves, and this is the only way to
                // use one.
                PhotosPicker(selection: $picked, matching: .images) {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Working

    private var reading: some View {
        VStack(spacing: 18) {
            Spacer()
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay { ProgressView().controlSize(.large).tint(.white) }
            } else {
                ProgressView().controlSize(.large)
            }
            Text("Finding the spines…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Reviewing

    @ViewBuilder
    private var review: some View {
        if candidates.isEmpty {
            ContentUnavailableView {
                Label("No spines found", systemImage: "questionmark.viewfinder")
            } description: {
                Text("Try again with the shelf filling the frame, straight on, and as much light as you can get. Spines at an angle or in shadow are hard to read.")
            } actions: {
                Button("Try another photo") { stage = .choosing }
                    .buttonStyle(.borderedProminent)
            }
            .themedState()
        } else {
            List {
                Section {
                    ForEach($candidates) { $candidate in
                        ShelfieRow(candidate: $candidate, crops: crops)
                    }
                } header: {
                    HStack {
                        Text("\(candidates.count) spine\(candidates.count == 1 ? "" : "s")")
                        if matching {
                            Spacer()
                            ProgressView().controlSize(.mini)
                            Text("looking them up…").font(.caption)
                        }
                    }
                } footer: {
                    Text("Tap a row to keep or skip it. Nothing is added until you tap Add.")
                }

                Section("Where they live") {
                    TextField("Shelf, e.g. Living room", text: $shelfName)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("\(added) book\(added == 1 ? "" : "s") added", systemImage: "checkmark.circle.fill")
        } description: {
            Text(shelfName.isEmpty ? "They're on your Want to Read shelf." : "They're on “\(shelfName)”.")
        } actions: {
            Button("Scan another shelf") {
                candidates = []
                photo = nil
                added = 0
                stage = .choosing
            }
            .buttonStyle(.borderedProminent)
        }
        .themedState()
    }

    // MARK: - Work

    private var keeping: [ShelfieCandidate] { candidates.filter { $0.decision == .keep } }
    /// Crops kept out of the candidate list so the value type stays `Sendable`
    /// and cheap to diff — a `UIImage` in there makes every list update copy them.
    @State private var crops: [String: UIImage] = [:]

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        photo = image
        await run(image)
    }

    private func run(_ image: UIImage) async {
        stage = .reading
        candidates = []
        crops = [:]

        // Off the main actor: rectangle detection plus two OCR passes per spine
        // is seconds of work on a shelf of thirty.
        let found = await Task.detached(priority: .userInitiated) {
            await ShelfieScanner.scan(image)
        }.value

        var built: [ShelfieCandidate] = []
        for item in found where item.text.isEmpty == false {
            var candidate = ShelfieCandidate(quad: item.quad, text: item.text)
            // Books already on the shelf default to skipped rather than being
            // hidden: seeing them marked is how you know the scan worked on that
            // part of the shelf.
            if let existing = store.state.existingBook(matching: candidate) {
                candidate.duplicateOfID = existing.id
                candidate.decision = .skip
            } else {
                candidate.decision = .keep
            }
            crops[candidate.id] = item.crop
            built.append(candidate)
        }

        candidates = built
        stage = .reviewing
        guard !built.isEmpty else { return }

        matching = true
        await ShelfieScanner.match(built) { index, doc in
            guard index < candidates.count else { return }
            candidates[index].match = doc
            // Re-checked once the catalogue has named it: a spine that read as
            // "HOBBIT" only matches the shelf's "The Hobbit" after the lookup.
            if let existing = store.state.existingBook(matching: candidates[index]) {
                candidates[index].duplicateOfID = existing.id
                candidates[index].decision = .skip
            }
        }
        matching = false
    }

    private func commit() {
        let shelf = shelfName.trimmingCharacters(in: .whitespaces)
        var count = 0
        for candidate in keeping {
            var draft = NewBook.Draft()
            draft.title = candidate.match?.title ?? candidate.text.title
            guard !draft.title.isEmpty else { continue }
            draft.author = candidate.displayAuthor
            draft.status = .want
            draft.owned = true
            draft.totalPages = candidate.match?.number_of_pages_median.map(Double.init)
            draft.coverURL = candidate.match?.coverURL?.absoluteString ?? ""
            draft.publishedYear = candidate.match?.first_publish_year.map(Double.init)
            draft.isbn = candidate.match?.isbn?.first ?? ""
            draft.genre = candidate.match?.subject?.first ?? ""
            guard let book = NewBook.make(draft) else { continue }
            store.add(book: book)
            if !shelf.isEmpty { store.setLocation(bookID: book.id, to: shelf) }
            count += 1
        }
        added = count
        Haptics.unlocked()
        stage = .done
    }
}

/// One spine, with the evidence for what it says it is.
private struct ShelfieRow: View {
    @Binding var candidate: ShelfieCandidate
    let crops: [String: UIImage]

    var body: some View {
        Button {
            candidate.decision = candidate.decision == .keep ? .skip : .keep
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // The crop, upright. This is what makes a row checkable at a
                // glance against the shelf you just photographed.
                if let crop = crops[candidate.id] {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 66)
                        .clipShape(.rect(cornerRadius: 3))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(candidate.decision == .keep ? .primary : .secondary)
                        .lineLimit(2)
                    if !candidate.displayAuthor.isEmpty {
                        Text(candidate.displayAuthor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if candidate.duplicateOfID != nil {
                        Label("Already on your shelves", systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if candidate.match == nil {
                        // Said plainly. A row showing the raw OCR as though it
                        // were a catalogue match is the one that gets confirmed
                        // by mistake.
                        Label("Read off the spine — no match found", systemImage: "text.viewfinder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: candidate.decision == .keep ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(candidate.decision == .keep ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// The system camera, full frame — a shelfie wants the whole shelf, so there is
/// deliberately no guide rectangle like the single-spine scanner has.
private struct ShelfCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ShelfCameraPicker
        init(_ parent: ShelfCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
