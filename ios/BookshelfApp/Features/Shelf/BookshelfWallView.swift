import BookshelfCore
import SwiftUI

/// The shelf, as a shelf.
///
/// Every other screen in this app is a list, which is the right shape for logging
/// and searching and the wrong shape for the thing a bookshelf is actually *for* —
/// standing back and looking at what you own. Spine thickness comes from the page
/// count, so a row of books reads at a glance the way a real one does.
struct BookshelfWallView: View {
    @Environment(\.themeAccent) private var accent
    @Environment(SpinePhotos.self) private var photos
    @Environment(ThemeStore.self) private var themes

    let books: [WireBook]
    var onSelect: (String) -> Void

    /// Inset from the pane edge to the inside of the case.
    private let caseInset = 14.0

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - caseInset * 2
            // The photo's aspect goes into the layout, not just the drawing:
            // a packer measuring one width while the view draws another is how
            // rows overflow the shelf.
            let spines = books.map { book in
                ShelfLayout.spine(
                    for: book,
                    photoAspect: SpineImageCache.shared.aspect(for: book.id, from: photos)
                )
            }
            let rows = ShelfLayout.rows(spines, width: usable)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        shelf(row, width: usable)
                    }
                }
                .padding(.top, 10)
                // The tab bar floats over the content, so the last shelf needs
                // room to clear it. Padding the *content* rather than insetting
                // the scroll view is what lets the case itself carry on behind
                // the bar to the bottom of the screen.
                .padding(.bottom, 96)
                // Fill the pane even with two books on it: a case that stops
                // where the books stop reads as a floating strip, not
                // furniture with room to grow into.
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
            // On the scroll view, not the content: a background *inside* the
            // scroll view stops at its container, which left the case ending in
            // a band of white above the tab bar and a hairline below the header.
            //
            // Bottom edge only. Letting it under the navigation bar too makes the
            // bar sample the dark case for its scroll-edge effect and flip to
            // white text — on a pale pink bar.
            .background(caseBack.ignoresSafeArea(edges: .bottom))
        }
    }

    // MARK: - One shelf

    private func shelf(_ row: [ShelfLayout.Spine], width: Double) -> some View {
        VStack(spacing: 0) {
            // Bottom-aligned: books stand on the plank, they don't hang from it.
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(row) { spine in
                    SpineView(
                        spine: spine,
                        accent: accent,
                        photo: SpineImageCache.shared.image(for: spine.id, from: photos)
                    )
                        .onTapGesture {
                            Haptics.pageTurn()
                            onSelect(spine.id)
                        }
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            // Only the books are inset; the board runs the full width of the
            // case. A plank stopping short of the sides reads as a shelf sawn
            // off rather than one built into the wall.
            .padding(.horizontal, caseInset)

            plank
        }
    }

    private var plank: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                // The board takes the theme like everything else, derived in HSB
                // so each colour keeps its hue instead of every shelf turning the
                // same brown.
                colors: [themes.theme.shelfPlank, themes.theme.shelfBack],
                startPoint: .top, endPoint: .bottom
            )
            // A lit front edge, which is most of what makes it read as a board
            // with thickness rather than a brown line.
            LinearGradient(
                colors: [.white.opacity(0.28), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 3)
        }
        .frame(height: 13)
        .clipShape(.rect(cornerRadius: 1.5))
        // Grounds the books instead of leaving them floating above the board.
        .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
        .padding(.bottom, 14)
    }

    /// The back of the case, behind the books.
    private var caseBack: some View {
        LinearGradient(
            colors: [themes.theme.shelfBack, themes.theme.shelfBack.opacity(0.82)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// One book, seen edge-on.
private struct SpineView: View {
    let spine: ShelfLayout.Spine
    let accent: Color
    /// The real thing, photographed. When present it replaces the drawn spine
    /// entirely — printed title, bands and all — because a photograph with our
    /// lettering on top of the publisher's is worse than either alone.
    let photo: UIImage?

    private var base: Color {
        Color(hue: Double(spine.hue) / 360, saturation: 0.42, brightness: 0.52)
    }

    var body: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    // Fit, not fill: the frame is already the photo's own aspect,
                    // and `fill` would crop away a sliver of the real spine.
                    .scaledToFit()
            } else {
                drawn
            }
            marker
        }
        .frame(width: spine.width, height: spine.height)
        .clipShape(.rect(cornerRadius: 2))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.black.opacity(0.35), lineWidth: 0.5)
        }
        .rotationEffect(.degrees(spine.lean), anchor: .bottom)
        .shadow(color: .black.opacity(0.4), radius: 2, x: 1)
        .accessibilityElement()
        .accessibilityLabel(spine.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    /// The drawn spine, for a book with no photograph.
    private var drawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        // Lighter on the left, darker on the right: a cylinder of
                        // paper catching light, which is what stops a row of
                        // spines looking like flat coloured bars.
                        colors: [base.opacity(0.95), base, base.opacity(0.62)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

            // Head and tail bands, the way a bound spine is printed.
            VStack {
                band
                Spacer()
                band
            }
            .padding(.vertical, 7)

            title
        }
    }

    /// Read state, drawn over a photograph as readily as over a drawn spine.
    @ViewBuilder
    private var marker: some View {
        // A finished book gets a foil dot; one in progress gets a ribbon down
        // the spine showing how far in you are. Both are readable side-on,
        // which a progress bar wouldn't be.
        if spine.finished {
                VStack {
                    Spacer()
                    Circle()
                        .fill(.white.opacity(0.75))
                        .frame(width: min(7, spine.width * 0.28))
                        .padding(.bottom, 13)
                }
            } else if spine.progress > 0.01 {
                // A bookmark hanging from the top down to where you've reached.
                // Drawn from the top rather than the bottom because that's the
                // direction a ribbon actually falls, and it makes "barely
                // started" a short tab instead of a nearly-full bar.
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 1.5, bottomTrailingRadius: 1.5)
                        .fill(accent.opacity(0.85))
                        .frame(width: 2.5, height: max(8, spine.height * min(1, spine.progress) * 0.7))
                    Spacer(minLength: 0)
                }
                .frame(width: 2.5, alignment: .top)
                .offset(x: spine.width / 2 - 6)
        }
    }

    private var band: some View {
        Rectangle()
            .fill(.white.opacity(0.22))
            .frame(height: 2)
            .padding(.horizontal, 3)
    }

    /// Rotated to run up the spine, the way a real one is printed.
    private var title: some View {
        Text(spine.title)
            .font(.system(size: min(11, spine.width * 0.32), weight: .semibold, design: .serif))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
            // Sized to the spine's *height* before rotating, so a long title
            // truncates along the book rather than overflowing it.
            .frame(width: spine.height - 26)
            .rotationEffect(.degrees(-90))
            // Read bottom-up, as almost every English-language spine is printed.
            .fixedSize()
    }

    private var accessibilityValue: String {
        if spine.finished { return "Finished" }
        if spine.progress > 0.01 { return "\(Int(spine.progress * 100))% read" }
        return spine.author.isEmpty ? "Not started" : spine.author
    }
}
