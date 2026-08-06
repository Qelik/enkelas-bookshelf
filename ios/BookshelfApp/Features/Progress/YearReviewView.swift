import BookshelfCore
import SwiftUI

/// A year's reading, and a card you can share.
///
/// The web app draws its card on a `<canvas>` — roughly 120 lines of manual
/// text measuring and wrapping. Here the card *is* a SwiftUI view, and
/// `ImageRenderer` turns the same view into the image, so what's shared is
/// exactly what was on screen and there is only one layout to maintain.
struct YearReviewView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var year: Int
    @State private var shareItem: ShareableImage?

    init(year: Int) {
        _year = State(initialValue: year)
    }

    private var review: YearReview { store.state.yearReview(year) }
    private var availableYears: [Int] { store.state.yearsWithReading() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    yearPicker
                    if review.hasData {
                        ReviewCard(review: review)
                        shareButton
                    } else {
                        ContentUnavailableView {
                            Label("Nothing to review", systemImage: "calendar")
                        } description: {
                            Text("No books finished in \(String(year)) yet. Come back once you've read some.")
                        }
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
            .themedBackground(background)
            .navigationTitle("Year in Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(image: item.image, caption: item.caption)
            }
        }
    }

    private var yearPicker: some View {
        HStack {
            Button {
                year -= 1
            } label: {
                Label(String(year - 1), systemImage: "chevron.left")
            }
            .disabled(!availableYears.contains(year - 1) && year - 1 < (availableYears.min() ?? year))

            Spacer()
            // verbatim: Text localizes an interpolated Int and would render 2026
            // as "2 026".
            Text(verbatim: String(year)).font(.title2.bold())
            Spacer()

            Button {
                year += 1
            } label: {
                Label(String(year + 1), systemImage: "chevron.right")
                    .labelStyle(TrailingIconStyle())
            }
            // Never forward past this year — there is nothing there yet.
            .disabled(year >= Calendar.current.component(.year, from: Date()))
        }
        .font(.subheadline)
    }

    private var shareButton: some View {
        Button {
            Task { await renderCard() }
        } label: {
            Label("Share this card", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @MainActor
    private func renderCard() async {
        let renderer = ImageRenderer(content: ReviewCard(review: review, forExport: true))
        // Render at the device's scale so the shared image isn't soft on a
        // Retina screen — the default is 1×.
        renderer.scale = max(displayScale, 2)
        guard let image = renderer.uiImage else { return }
        shareItem = ShareableImage(
            image: image,
            caption: "My \(String(year)) in books — \(review.booksFinished) finished, \(review.pagesRead.formatted()) pages."
        )
    }
}

/// The card itself. One layout, shown on screen *and* rendered to the image.
struct ReviewCard: View {
    let review: YearReview
    var forExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(review.year))
                    .font(.system(size: 44, weight: .bold, design: .serif))
                Text("in books").font(.title3).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 14) {
                tile(review.booksFinished.formatted(), "books finished")
                tile(review.pagesRead.formatted(), "pages read")
                tile(review.daysReading.formatted(), "days reading")
                tile(review.averageRating.map { "\(JS.numberToString(($0 * 10).rounded() / 10))★" } ?? "—", "average rating")
                tile(review.topGenre ?? "—", "top genre")
                tile(review.busiestMonth ?? "—", "busiest month")
            }

            if let favourite = review.favourite {
                highlight("Favourite read", book: favourite, detail: favourite.rating.map {
                    "\(JS.numberToString($0))★"
                })
            }
            // Only when it isn't already the favourite — the same book twice
            // reads as a rendering bug.
            if let longest = review.longest, longest.id != review.favourite?.id {
                highlight("Longest book", book: longest, detail: "\(Int(longest.totalPages)) pages")
            }

            if forExport {
                Text("Enkela's Bookshelf")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(width: forExport ? 400 : nil)
        .background(
            // A fixed light background for the exported image: a card rendered
            // in dark mode and dropped into a bright chat looks broken.
            forExport
                ? AnyShapeStyle(Color(red: 0.98, green: 0.97, blue: 0.94))
                : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
            in: .rect(cornerRadius: 20)
        )
        .foregroundStyle(forExport ? AnyShapeStyle(Color(red: 0.16, green: 0.14, blue: 0.12)) : AnyShapeStyle(.primary))
        .environment(\.colorScheme, forExport ? .light : .current)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    private func highlight(_ title: String, book: WireBook, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                BookCover(book: book, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if !book.author.isEmpty {
                        Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Sharing

struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let caption: String
}

/// `UIActivityViewController` rather than `ShareLink`, because the image is
/// produced on demand rather than existing up front.
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let caption: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image, caption], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Label with the icon after the text, for a "next" button.
struct TrailingIconStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

private extension ColorScheme {
    /// The scheme currently in effect, so the on-screen card follows the system
    /// while the exported one is pinned to light.
    static var current: ColorScheme {
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }
}
