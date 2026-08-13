import BookshelfCore
import SwiftUI

/// What you're left with when a book is over.
///
/// Every competitor ends a book with five stars and a review box — a rating *of*
/// the book. This app has been collecting the things that are actually yours all
/// along: the lines you marked, the characters you kept track of, the words you
/// looked up, what you wrote halfway through, how long it took. Gathered onto
/// one page they're worth keeping, which a rating never is.
///
/// The card follows `YearReviewView`'s pattern exactly — the card *is* a SwiftUI
/// view and `ImageRenderer` turns that same view into the shared image, so
/// there's one layout rather than a screen and a separate canvas drawing of it.
struct KeepsakeView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    let bookID: String
    @State private var shareItem: ShareableImage?

    private var book: WireBook? { store.state.book(id: bookID) }

    var body: some View {
        NavigationStack {
            Group {
                if let book, case let keepsake = book.keepsake(), keepsake.hasAnything {
                    ScrollView {
                        VStack(spacing: 20) {
                            KeepsakeCard(keepsake: keepsake)
                            shareButton(keepsake)
                            details(keepsake)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Nothing kept yet", systemImage: "bookmark")
                    } description: {
                        Text("Quotes, journal entries, characters and words you looked up all end up here. Mark something while you read and this page fills itself in.")
                    }
                    .themedState()
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Your record")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $shareItem) { ShareSheet(image: $0.image, caption: $0.caption) }
        }
    }

    private func shareButton(_ keepsake: BookKeepsake) -> some View {
        Button {
            Task { await render(keepsake) }
        } label: {
            Label("Share this", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @MainActor
    private func render(_ keepsake: BookKeepsake) async {
        let renderer = ImageRenderer(content: KeepsakeCard(keepsake: keepsake, forExport: true))
        // The device's scale, not the 1× default, or the shared image is soft.
        renderer.scale = max(displayScale, 2)
        guard let image = renderer.uiImage else { return }
        shareItem = ShareableImage(
            image: image,
            caption: "“\(keepsake.title)”\(keepsake.author.isEmpty ? "" : " by \(keepsake.author)")"
        )
    }

    // MARK: - Everything, below the card

    @ViewBuilder
    private func details(_ keepsake: BookKeepsake) -> some View {
        if !keepsake.quotes.isEmpty {
            section("Lines you marked", "quote.opening") {
                ForEach(keepsake.quotes, id: \.id) { quote in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quote.text)
                            .font(.callout.italic())
                        if let page = quote.page {
                            Text("page \(Int(page))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !keepsake.journal.isEmpty {
            section("What you said at the time", "text.quote") {
                ForEach(keepsake.journal, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).font(.callout)
                        HStack(spacing: 6) {
                            if let date = ISO8601.date(from: entry.date) {
                                Text(date, format: .dateTime.day().month(.abbreviated))
                            }
                            if let page = entry.page { Text("· page \(Int(page))") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !keepsake.characters.isEmpty {
            section("Who you followed", "person.2") {
                ForEach(keepsake.characters, id: \.id) { character in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.name).font(.callout.weight(.medium))
                        if !character.desc.isEmpty {
                            Text(character.desc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !keepsake.vocab.isEmpty {
            section("Words you looked up", "character.book.closed") {
                ForEach(keepsake.vocab, id: \.id) { word in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(word.word).font(.callout.weight(.medium))
                        if !word.def.isEmpty {
                            Text(word.def).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !keepsake.review.isEmpty {
            section("Your review", "text.bubble") {
                Text(keepsake.review)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The keepsake as one card — on screen, and rendered to the shared image.
struct KeepsakeCard: View {
    @Environment(\.themeSurface) private var surface
    let keepsake: BookKeepsake
    var forExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(keepsake.title)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .lineLimit(3)
                if !keepsake.author.isEmpty {
                    Text(keepsake.author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = keepsake.summaryLine {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let rating = keepsake.rating {
                StarRating(rating: rating)
            }

            if !keepsake.highlights.isEmpty {
                // Wrapping grid rather than a row: which tiles exist depends on
                // what was actually kept, so the count is never known up front.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 12
                ) {
                    ForEach(keepsake.highlights, id: \.label) { item in
                        VStack(spacing: 2) {
                            Text(item.value)
                                .font(.title3.weight(.semibold).monospacedDigit())
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            // One line, the last one marked — a card carrying every quote is a
            // document, and nobody shares a document.
            if let quote = keepsake.quotes.first {
                Divider()
                Text("“\(quote.text)”")
                    .font(.callout.italic())
                    .lineLimit(4)
                    // `ImageRenderer` proposes an unbounded width, so without
                    // this the quote lays out on one enormous line and then gets
                    // clipped by the card's frame — on screen it wraps, and only
                    // the exported image is wrong.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: forExport ? 380 : .infinity, alignment: .leading)
        // Paper for the exported card, the app's own surface on screen.
        .background(forExport ? Color(white: 0.97) : surface, in: .rect(cornerRadius: 20))
        // Pinned to light for export: a card rendered in dark mode and dropped
        // into a message thread reads as a screenshot of an app rather than as
        // something about a book.
        .environment(\.colorScheme, forExport ? .light : .current)
    }

}

private extension ColorScheme {
    static var current: ColorScheme {
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }
}
