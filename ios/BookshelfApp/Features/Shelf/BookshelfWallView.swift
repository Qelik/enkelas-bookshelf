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
    /// One book to pick out of the row — the answer to "where is my copy?".
    ///
    /// Everything else dims rather than the spine merely glowing: on a full case
    /// a highlight competes with forty other coloured spines, and the eye finds
    /// the one lit object in a dark room far faster than the brightest of many.
    var highlight: String?
    /// The books, in the order they were left in. Nil means this shelf can't be
    /// rearranged — the "where is my copy?" lookup, where dragging would be a
    /// distraction from the question being asked.
    var onReorder: (([String]) -> Void)?
    var onSelect: (String) -> Void

    /// Inset from the pane edge to the inside of the case.
    private let caseInset = 14.0
    private let caseSpace = "bookcase"

    /// The book being carried, and where the shelf currently stands as a result.
    ///
    /// Held locally rather than committed on every frame: a store write per
    /// pixel of movement would push a sync on each one. It goes to the store
    /// once, when the finger lifts.
    @State private var draggingID: String?
    @State private var liveOrder: [String] = []
    @State private var frames: [String: CGRect] = [:]

    /// What to draw: the live arrangement while a book is being carried, and
    /// whatever the caller passed the rest of the time.
    private var shown: [WireBook] {
        guard draggingID != nil, !liveOrder.isEmpty else { return books }
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return liveOrder.compactMap { byID[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - caseInset * 2
            // The photo's aspect goes into the layout, not just the drawing:
            // a packer measuring one width while the view draws another is how
            // rows overflow the shelf.
            let spines = shown.map { book in
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
            .coordinateSpace(name: caseSpace)
            // Where every spine currently sits, so a carried book knows what
            // it's over. Read from the layout rather than recomputed, or the
            // packer and the hit test would disagree about where a book is.
            .onPreferenceChange(SpineFramesKey.self) { frames = $0 }
            // The scroll view must not follow the finger while a book is being
            // carried; the drag is the gesture, not a pan.
            .scrollDisabled(draggingID != nil)
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
                        photo: SpineImageCache.shared.image(for: spine.id, from: photos),
                        dimmed: highlight != nil && highlight != spine.id,
                        lit: highlight == spine.id,
                        carried: draggingID == spine.id
                    )
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: SpineFramesKey.self,
                                    value: [spine.id: g.frame(in: .named(caseSpace))]
                                )
                            }
                        )
                        .onTapGesture {
                            Haptics.pageTurn()
                            onSelect(spine.id)
                        }
                        .gesture(reorderGesture(for: spine.id), isEnabled: onReorder != nil)
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

    // MARK: - Rearranging

    /// Hold a book, then slide it along the shelf.
    ///
    /// `LongPressGesture` rather than a hand-rolled timer, and that is the whole
    /// point: it carries its own movement tolerance, so a finger resting on
    /// glass doesn't cancel the hold. The web app hand-rolled this and cancelled
    /// on *any* pointermove, which is a threshold no hand can meet — it was
    /// broken on touch from the day it shipped.
    private func reorderGesture(for id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(caseSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginCarrying(id)
                case .second(true, let drag?):
                    carry(to: drag.location)
                default:
                    break
                }
            }
            // Only reached when the hold succeeded, so a plain tap can't land
            // here and write an order nobody asked for.
            .onEnded { _ in finishCarrying() }
    }

    private func beginCarrying(_ id: String) {
        guard draggingID == nil else { return }
        Haptics.saved()
        liveOrder = books.map(\.id)
        draggingID = id
    }

    private func carry(to point: CGPoint) {
        guard let draggingID,
              let targetID = frames.first(where: { $0.value.contains(point) })?.key,
              targetID != draggingID,
              let from = liveOrder.firstIndex(of: draggingID),
              let to = liveOrder.firstIndex(of: targetID)
        else { return }
        withAnimation(.snappy(duration: 0.18)) {
            liveOrder.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        Haptics.pageTurn()
    }

    private func finishCarrying() {
        defer {
            draggingID = nil
            liveOrder = []
        }
        guard draggingID != nil, !liveOrder.isEmpty else { return }
        // Only the ids on screen: the shelf may be filtered, and the store
        // splices this run back into the full arrangement.
        onReorder?(liveOrder)
        Haptics.unlocked()
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

/// Where each spine sits, gathered from the laid-out rows so the hit test and
/// the packer can't disagree about where a book is.
private struct SpineFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
    /// Pushed back because another book is being pointed at.
    var dimmed = false
    /// This is the one you're looking for.
    var lit = false
    /// Being carried to a new place on the shelf.
    var carried = false

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
        // Everything else recedes; the one you asked for keeps its colour, gains
        // a rim and stands a little proud of the row — the way a book does when
        // somebody has pulled it half out for you.
        .saturation(dimmed ? 0.15 : 1)
        .opacity(dimmed ? 0.4 : 1)
        .overlay {
            if lit {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(accent, lineWidth: 2)
            }
        }
        .shadow(color: lit ? accent.opacity(0.9) : .clear, radius: 10)
        // Lifted off the plank and tilted upright while carried, so it's obvious
        // which book is in your hand and that the shelf is now in a mode.
        .offset(y: carried ? -18 : (lit ? -8 : 0))
        .scaleEffect(carried ? 1.06 : 1, anchor: .bottom)
        .shadow(color: .black.opacity(carried ? 0.5 : 0), radius: 8, y: 6)
        .zIndex(carried ? 1 : 0)
        .animation(.snappy(duration: 0.18), value: carried)
        // The tap target is the book, and only the book.
        //
        // `clipShape` masks drawing, not touches: the spine's contents — a title
        // laid out along the book's *height* and then rotated, a ribbon offset past
        // the edge — kept their own hit regions, which spill sideways over the
        // neighbours. An `HStack` hit-tests its children front-to-back, and later
        // siblings are on top, so a tap landing in that overlap resolved to the book
        // to the *right* of the one you aimed at.
        //
        // Before `rotationEffect`, so a leaning book's target leans with it.
        .contentShape(.rect(cornerRadius: 2))
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
