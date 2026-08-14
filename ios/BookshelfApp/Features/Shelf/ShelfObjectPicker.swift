import BookshelfCore
import SwiftUI

/// Choosing something to put on the shelf.
///
/// Shows the actual drawing rather than a name and an icon: these are decorative
/// objects, so what they look like *is* the choice being made.
struct ShelfObjectPicker: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss

    @State private var philosopher = ShelfObjectKind.philosophers[0]

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ShelfObjectKind.allCases, id: \.self) { kind in
                        Button { add(kind) } label: { tile(kind) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .themedPage()
            .navigationTitle("Add to the shelf")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func tile(_ kind: ShelfObjectKind) -> some View {
        VStack(spacing: 8) {
            // On a stretch of the real shelf, because that's where it's going —
            // a plant on a white card tells you nothing about how it'll look.
            ZStack(alignment: .bottom) {
                themes.theme.shelfBack
                ShelfObjectView(object: preview(kind))
                    .scaleEffect(scale(kind), anchor: .bottom)
                    // `scaleEffect` shrinks the drawing but not the space it
                    // claims, so a 148pt plant still asked for 148pt inside a
                    // 104pt tile and shoved the plank off the bottom. Taking the
                    // scaled height back in layout is what keeps them agreeing.
                    .frame(height: kind.size.height * scale(kind))
                    .padding(.bottom, 8)
                Rectangle()
                    .fill(themes.theme.shelfPlank)
                    .frame(height: 6)
            }
            .frame(height: 104)
            .clipShape(.rect(cornerRadius: 10))

            Text(kind == .bust ? philosopher : kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Everything shown at a size that fits the tile, whatever its real height.
    private func scale(_ kind: ShelfObjectKind) -> Double {
        min(1, 78 / kind.size.height)
    }

    private func preview(_ kind: ShelfObjectKind) -> ShelfObject {
        ShelfObject(id: "preview-\(kind.rawValue)", kind: kind, tint: kind.defaultTint,
                    label: kind == .bust ? philosopher : "")
    }

    private func add(_ kind: ShelfObjectKind) {
        store.addShelfObject(kind, label: kind == .bust ? philosopher : "")
        // The next bust is a different philosopher, so tapping twice doesn't
        // silently give you two of the same one.
        if kind == .bust, let i = ShelfObjectKind.philosophers.firstIndex(of: philosopher) {
            philosopher = ShelfObjectKind.philosophers[(i + 1) % ShelfObjectKind.philosophers.count]
        }
        Haptics.unlocked()
        dismiss()
    }
}

/// A shelf object being edited, wrapped so `.sheet(item:)` has something to key
/// on. Conforming `String` to `Identifiable` retroactively would be a very broad
/// change to a stdlib type for the sake of one sheet.
struct EditingShelfObject: Identifiable, Hashable {
    let id: String
}

/// Recolour it, rename it, or take it off the shelf.
struct ShelfObjectEditor: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss

    let objectID: String
    @State private var tint: Double = 0
    @State private var label = ""

    private var object: ShelfObject? { store.state.shelfObject(id: objectID) }

    var body: some View {
        NavigationStack {
            Group {
                if let object {
                    Form {
                        Section {
                            ZStack(alignment: .bottom) {
                                themes.theme.shelfBack
                                ShelfObjectView(object: ShelfObject(
                                    id: object.id, kind: object.kind, tint: tint, label: label
                                ))
                                .padding(.bottom, 10)
                                Rectangle().fill(themes.theme.shelfPlank).frame(height: 7)
                            }
                            .frame(height: 150)
                            .clipShape(.rect(cornerRadius: 12))
                            .listRowInsets(EdgeInsets())
                        }

                        // Only for the drawn objects. A hue drives a drawing
                        // completely, so every value works; over a photograph
                        // of carved wood the same slider is a bad filter.
                        if !object.kind.isPhotographic {
                            Section("Colour") {
                                Slider(value: $tint, in: 0...359, step: 1)
                                    .tint(Color(hue: tint / 360, saturation: 0.5, brightness: 0.6))
                                    .onChange(of: tint) { _, new in
                                        store.updateShelfObject(id: objectID, tint: new)
                                    }
                            }
                        }

                        if object.kind == .bust {
                            Section("Who is it?") {
                                Picker("Philosopher", selection: $label) {
                                    ForEach(ShelfObjectKind.philosophers, id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }
                                .onChange(of: label) { _, new in
                                    store.updateShelfObject(id: objectID, label: new)
                                }
                            }
                        }

                        Section {
                            Button("Take it off the shelf", systemImage: "trash", role: .destructive) {
                                store.removeShelfObject(id: objectID)
                                Haptics.saved()
                                dismiss()
                            }
                        }
                    }
                } else {
                    // Reachable if it was removed on another device mid-edit.
                    ContentUnavailableView("Not on the shelf", systemImage: "questionmark")
                        .themedState()
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(object?.displayName ?? "Object")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                guard let object else { return }
                tint = object.tint
                label = object.label.isEmpty ? ShelfObjectKind.philosophers[0] : object.label
            }
        }
    }
}
