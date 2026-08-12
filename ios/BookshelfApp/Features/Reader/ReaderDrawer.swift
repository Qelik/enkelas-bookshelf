import BookshelfCore
import SwiftUI

/// Contents, bookmarks and highlights in one drawer.
///
/// Three tabs rather than three sheets: they're all "take me somewhere in this
/// book", and a reader shouldn't have to remember which button opens which list.
struct ReaderDrawer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeBackground) private var background
    @Environment(\.themeAccent) private var accent

    let package: EPUBPackage
    let record: EPUBRecord
    let current: Int
    var onChapter: (Int) -> Void
    var onJump: (Int, Int) -> Void
    var onRemoveBookmark: (String) -> Void
    var onRemoveHighlight: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case contents = "Contents", bookmarks = "Bookmarks", highlights = "Highlights"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .contents

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .contents: contentsList
                case .bookmarks: bookmarksList
                case .highlights: highlightsList
                }
            }
            // spacing: 0 — see the note in ShelfView; the default leaves a gap in
            // the safe area that no background covers.
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                // Not `.bar`: the system material ignores the theme and leaves a
                // strip of white under the drawer's title.
                .background(background)
            }
            .themedPage()
            .navigationTitle(record.title)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private var contentsList: some View {
        List {
            if package.toc.isEmpty {
                // Plenty of books ship without a usable TOC; the spine is always
                // there, so fall back to it rather than showing nothing.
                ForEach(Array(package.spine.enumerated()), id: \.offset) { index, chapter in
                    chapterRow(title: chapter.title ?? "Section \(index + 1)", indent: 0, index: index)
                        .themedPlainRows()
                }
            } else {
                ForEach(package.toc) { entry in
                    chapterRow(
                        title: entry.title,
                        indent: entry.depth,
                        index: package.spine.firstIndex { $0.path == entry.path }
                    )
                    .themedPlainRows()
                }
            }
        }
        .listStyle(.plain)
        .themedPage()
    }

    @ViewBuilder
    private func chapterRow(title: String, indent: Int, index: Int?) -> some View {
        Button {
            if let index { onChapter(index) }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .padding(.leading, CGFloat(indent) * 16)
                Spacer()
                if index == current { Image(systemName: "book").foregroundStyle(.tint) }
            }
        }
        .disabled(index == nil)
    }

    @ViewBuilder
    private var bookmarksList: some View {
        if record.bookmarks.isEmpty {
            ContentUnavailableView {
                Label("No bookmarks", systemImage: "bookmark")
            } description: {
                Text("Tap the ribbon while reading to mark where you are.")
            }
                .themedState()
        } else {
            List {
                ForEach(record.bookmarks) { bookmark in
                    Button {
                        onJump(bookmark.chapter, offsetFor(bookmark))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(bookmark.label).font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(bookmark.progress * 100))%")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if !bookmark.snippet.isEmpty {
                                Text(bookmark.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            onRemoveBookmark(bookmark.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }

    /// A bookmark stores a fraction through the chapter; jumping needs a
    /// character offset, so scale it by the chapter's length.
    private func offsetFor(_ bookmark: EPUBRecord.Bookmark) -> Int {
        let chars = record.chapterCharacters?[safe: bookmark.chapter] ?? 0
        return Int(Double(chars) * bookmark.progress)
    }

    @ViewBuilder
    private var highlightsList: some View {
        if record.highlights.isEmpty {
            ContentUnavailableView {
                Label("No highlights", systemImage: "highlighter")
            } description: {
                Text("Select any passage while reading to highlight it.")
            }
                .themedState()
        } else {
            List {
                ForEach(record.highlights) { highlight in
                    Button {
                        onJump(highlight.chapter, highlight.start)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(highlight.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                            Text(package.spine[safe: highlight.chapter]?.title
                                 ?? "Chapter \(highlight.chapter + 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            onRemoveHighlight(highlight.id)
                        }
                        ShareLink(item: highlight.text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(accent)
                    }
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }
}

/// Full-book search.
struct ReaderSearchView: View {
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    let package: EPUBPackage
    let cachedText: [String]
    var onSelect: (EPUBSearchResult) -> Void

    @State private var query = ""
    @State private var results: [EPUBSearchResult] = []
    @State private var truncated = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Group {
                if !searched {
                    ContentUnavailableView("Search this book", systemImage: "magnifyingglass",
                                           description: Text("Find any phrase across every chapter."))
                        .themedState()
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .themedState()
                } else {
                    List {
                        ForEach(results) { result in
                            Button {
                                onSelect(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.snippet)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                    HStack {
                                        Text(result.chapterTitle ?? "Chapter \(result.chapter + 1)")
                                        Spacer()
                                        Text("\(Int(result.fraction * 100))% in")
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if truncated {
                            // Say it rather than implying these are all of them.
                            Text("Showing the first \(EPUBPackage.searchLimit) matches.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                    .themedPage()
                }
            }
            .searchable(text: $query, prompt: "Find in book")
            // A book search isn't a sentence — capitalising the first word and
            // autocorrecting proper nouns out of it only gets in the way.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search, runSearch)
            .onChange(of: query) { _, value in
                if value.isEmpty { results = []; searched = false }
            }
            .themedPage()
            .navigationTitle("Search")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func runSearch() {
        let outcome = package.search(query, cachedText: cachedText.isEmpty ? nil : cachedText)
        results = outcome.results
        truncated = outcome.truncated
        searched = true
    }
}
