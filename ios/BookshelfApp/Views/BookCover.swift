import BookshelfCore
import SwiftUI

/// A book cover, or a legible stand-in when there isn't one.
///
/// The placeholder is not a grey box: a shelf imported from Goodreads arrives
/// with a lot of missing covers, and a wall of identical grey rectangles is
/// unusable. Hue is derived from the title, so each book keeps a stable colour
/// and the shelf stays scannable while covers backfill.
struct BookCover: View {
    let book: WireBook
    var width: CGFloat = 52

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Group {
            if !book.coverUrl.isEmpty, let url = URL(string: book.coverUrl) {
                // No spinner over the placeholder: the lettered gradient already
                // says which book this is, and a spinner that appears for two
                // frames on every scroll is worse than nothing.
                CoverImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: width * 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: width * 0.08)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityHidden(true)      // the title is right next to it
    }

    private var placeholder: some View {
        // stableHue, not hashValue: Swift seeds hashValue per process, so the
        // colour would change on every launch.
        let hue = Double(book.title.stableHue) / 360
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.35, brightness: 0.55),
                Color(hue: hue, saturation: 0.45, brightness: 0.38),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Text(book.title.prefix(1).uppercased())
                .font(.system(size: width * 0.45, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// One row on any shelf. Deliberately identical everywhere so a book looks the
/// same whether you meet it in Reading, Want or Library.
struct BookRow: View {
    let book: WireBook
    /// Your measured reading speed, when the screen showing this row has it.
    ///
    /// Passed in rather than derived here: measuring it walks every session log
    /// on the shelf, and a list row redrawn on every scroll is the last place
    /// that should happen. Nil simply means the line isn't shown.
    var pace: ReadingPace?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(book: book)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let series = seriesLine {
                    Text(series)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if book.status == .reading, let progress = book.progress {
                    ProgressView(value: progress)
                        .padding(.top, 2)
                    Text(progressLine(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let pace = paceLine {
                        Text(pace.text)
                            .font(.caption)
                            .foregroundStyle(pace.tonight ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                } else if let meta = metaLine {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if book.owned {
                Image(systemName: "house.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("On your shelf at home")
            }
        }
        .padding(.vertical, 4)
    }

    private var seriesLine: String? {
        guard !book.seriesName.isEmpty else { return nil }
        guard let n = book.seriesNumber else { return book.seriesName }
        return "\(book.seriesName) #\(JS.numberToString(n))"
    }

    private func progressLine(_ progress: Double) -> String {
        let read = Int(book.pagesRead)
        let total = Int(book.totalPages)
        return "\(read) of \(total) \(book.unitLabelShort) · \(Int(progress * 100))%"
    }

    /// What's left, in minutes you'd actually spend — and whether that's an
    /// evening. Tinted when it is, because "you could finish this tonight" is
    /// the one line here that changes what somebody does next.
    ///
    /// Audiobooks are skipped: their pages field holds minutes, so the maths
    /// that produces this doesn't apply to them.
    private var paceLine: (text: String, tonight: Bool)? {
        guard let pace, book.format != .audio, book.totalPages > 0 else { return nil }
        let remaining = book.pagesRemaining
        guard remaining > 0, let left = pace.timeLeftDescription(pages: remaining) else { return nil }
        guard pace.fitsInOneSitting(pages: remaining) else { return (left, false) }
        return ("\(left) — you could finish tonight", true)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let rating = book.rating {
            parts.append("\(JS.numberToString(rating))★")
        }
        if book.status == .finished, let date = book.finishedDate {
            parts.append(date.formatted(.dateTime.month(.abbreviated).year()))
        }
        if book.status == .dnf {
            parts.append("Did not finish")
        }
        if book.totalPages > 0, book.status != .finished, book.status != .dnf {
            parts.append("\(Int(book.totalPages)) \(book.unitLabelShort)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
