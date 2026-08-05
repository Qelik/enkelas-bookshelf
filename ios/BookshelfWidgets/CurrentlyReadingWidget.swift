import BookshelfCore
import SwiftUI
import WidgetKit

/// The book in your hand, with how far through it you are.
struct CurrentlyReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CurrentlyReading", provider: SnapshotProvider()) { entry in
            CurrentlyReadingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Currently Reading")
        .description("The book you're reading and how far through it you are.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct CurrentlyReadingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: lockScreen
        case .systemMedium: medium
        default: small
        }
    }

    private var books: [WidgetSnapshot.Item] { entry.snapshot.reading }

    // MARK: - Small

    @ViewBuilder
    private var small: some View {
        if let book = books.first {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(book.coverGradient)
                    .frame(width: 34, height: 50)
                    .overlay {
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                Spacer(minLength: 0)
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                ProgressView(value: book.progress)
                    .tint(entry.snapshot.accent)
                Text(pageLine(book))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(WidgetLink.book(book.id))
        } else {
            empty
        }
    }

    // MARK: - Medium

    @ViewBuilder
    private var medium: some View {
        if books.isEmpty {
            empty
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Two at most: a third row squeezes the bars to the point where
                // they stop reading as progress.
                ForEach(books.prefix(2)) { book in
                    Link(destination: WidgetLink.book(book.id)) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(book.coverGradient)
                                .frame(width: 28, height: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if !book.author.isEmpty {
                                    Text(book.author)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                ProgressView(value: book.progress).tint(entry.snapshot.accent)
                                Text(pageLine(book))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if books.count == 1 { Spacer(minLength: 0) }
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private var lockScreen: some View {
        if let book = books.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(1)
                ProgressView(value: book.progress)
                // Clamped: an imported shelf can carry more pages read than the
                // book has, and "−12 pages left" is worse than saying nothing.
                Text("\(Int(book.progress * 100))% · \(max(0, book.pages - book.currentPage)) pages left")
                    .font(.caption2)
            }
            .widgetURL(WidgetLink.book(book.id))
        } else {
            Text("Nothing on the go").font(.headline)
        }
    }

    // MARK: - Shared

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "book.closed").font(.title3).foregroundStyle(.secondary)
            Text(entry.isPlaceholder ? "No shelf yet" : "Nothing on the go")
                .font(.caption.weight(.semibold))
            Text("Start a book to see it here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetLink.shelf)
    }

    /// A book with no page count still deserves a line — just a percentage
    /// rather than "214 of 0".
    private func pageLine(_ book: WidgetSnapshot.Item) -> String {
        book.pages > 0
            ? "\(book.currentPage) of \(book.pages)"
            : "\(Int(book.progress * 100))%"
    }
}
