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
    /// The plant, the cat, the bust. They stand in `shelfOrder` alongside the
    /// books, so they pack and drag exactly the way a book does.
    var objects: [ShelfObject] = []
    var order: [String] = []
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
    /// Tapping an object opens its editor rather than a book page.
    var onSelectObject: ((String) -> Void)?
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
    /// The arrangement mid-drag, as shelves of ids. Modelled the way it looks
    /// rather than as a flat list, because "which shelf is this on" is the
    /// thing being edited.
    @State private var liveRows: [[String]] = []
    @State private var frames: [String: CGRect] = [:]
    @State private var plankFrames: [Int: CGRect] = [:]
    /// The arrangement as it stood when the carry began. Every move is worked
    /// out from this, not from the last frame — see `carry(to:)`.
    @State private var carryOriginRows: [[String]] = []
    /// The shelf the carried thing came off, so a drag that can't be placed
    /// leaves it where it was.
    @State private var carryStartLevel = 0
    /// How wide a shelf is, so the drag can ask whether one more thing fits.
    @State private var caseWidth = 0.0

    /// Everything on the shelf, keyed by id.
    private var itemsByID: [String: ShelfItem] {
        // The photo's aspect goes into the layout, not just the drawing: a
        // packer measuring one width while the view draws another is how rows
        // overflow the shelf.
        let spines = books.map { book in
            ShelfLayout.spine(
                for: book,
                photoAspect: SpineImageCache.shared.aspect(for: book.id, from: photos)
            )
        }
        var out: [String: ShelfItem] = [:]
        for spine in spines { out[spine.id] = .book(spine) }
        for object in objects { out[object.id] = .object(object) }
        return out
    }

    /// The arrangement the order describes, before anything is measured against
    /// the width of the case.
    ///
    /// Read from the order's shelf breaks rather than from the packer, because
    /// the packer only ever fills from the top — which is what stopped anything
    /// being put on the third shelf while the first had room.
    private var storedShelves: [[ShelfItem]] {
        let lookup = itemsByID
        let effective = ShelfOrder.rows(of: order)

        var rows = effective.map { row in row.compactMap { lookup[$0] } }
        // Anything the order has never heard of — a book added since, or one
        // that arrived from another device — goes on the last shelf rather than
        // vanishing.
        let placed = Set(effective.joined())
        let unplaced = lookup.keys.filter { !placed.contains($0) }.sorted().compactMap { lookup[$0] }
        if !unplaced.isEmpty {
            if rows.isEmpty { rows = [[]] }
            rows[rows.count - 1].append(contentsOf: unplaced)
        }
        return rows
    }

    /// The planks to draw. **One plank is one shelf.**
    ///
    /// A stored shelf too wide for the case spills onto the plank below, and
    /// that plank is then a shelf in its own right. It used to stay part of the
    /// level above it, and with forty books that quietly broke the drag: four
    /// planks all called level 0, so the frames they reported overwrote each
    /// other and most of the case belonged to no shelf at all. A book dragged
    /// down the case would stick to the top row, jump between rows, and never
    /// reach the third one.
    ///
    /// Three minimum: a case with one occupied plank floating in a tall empty
    /// box reads as a rendering bug rather than furniture, and the empty ones
    /// are where a growing library visibly has room to go.
    private func planks(width: Double) -> [[ShelfItem]] {
        // Mid-drag the shelves are whatever the finger has made of them. Not
        // re-packed: the packer would wrap an over-full row onto another plank
        // and every index below the drop would shift out from under the drag.
        if draggingID != nil, !liveRows.isEmpty {
            let lookup = itemsByID
            return liveRows.map { row in row.compactMap { lookup[$0] } }
        }
        var out: [[ShelfItem]] = []
        for shelf in storedShelves {
            let packed = ShelfLayout.rows(shelf, width: width)
            out.append(contentsOf: packed.isEmpty ? [[]] : packed)
        }
        while out.count < Self.minimumShelves { out.append([]) }
        return out
    }

    static let minimumShelves = 3

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - caseInset * 2
            let rows = planks(width: usable)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { level, items in
                        shelf(items, level: level, width: usable)
                    }
                }
                // What the case can hold, published so the drag can pack the
                // same way the drawing does.
                .preference(key: CaseWidthKey.self, value: usable)
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
            .onPreferenceChange(PlankFramesKey.self) { plankFrames = $0 }
            .onPreferenceChange(CaseWidthKey.self) { caseWidth = $0 }
            // The scroll view must not follow the finger while a book is being
            // carried; the drag is the gesture, not a pan.
            .scrollDisabled(draggingID != nil)
            .simultaneousGesture(carryGesture, isEnabled: onReorder != nil)
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

    private func shelf(_ row: [ShelfItem], level: Int, width: Double) -> some View {
        VStack(spacing: 0) {
            // Bottom-aligned: things stand on the plank, they don't hang from it.
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(row) { item in
                    itemView(item)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: SpineFramesKey.self,
                                    value: [item.id: g.frame(in: .named(caseSpace))]
                                )
                            }
                        )
                        .onTapGesture {
                            Haptics.pageTurn()
                            switch item {
                            case .book: onSelect(item.id)
                            case .object: onSelectObject?(item.id)
                            }
                        }
                        // Only the *hold* belongs to the item — see `carryGesture`
                        // for why the sliding half can't live here.
                        .gesture(
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in beginCarrying(item.id) },
                            isEnabled: onReorder != nil
                        )
                }
                Spacer(minLength: 0)
            }
            // A floor, so an empty shelf is a shelf rather than a hairline. The
            // tallest book sets it when there is one; an empty plank still gets
            // a bay you could stand a book in.
            .frame(minHeight: ShelfLayout.maxHeight * 0.86, alignment: .bottom)
            .frame(width: width, alignment: .leading)
            // The whole bay, so a drop can find which *level* the finger is
            // over — including an empty one, which has no items to hit-test.
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: PlankFramesKey.self,
                        value: [level: g.frame(in: .named(caseSpace))]
                    )
                }
            )
            // Only the books are inset; the board runs the full width of the
            // case. A plank stopping short of the sides reads as a shelf sawn
            // off rather than one built into the wall.
            .padding(.horizontal, caseInset)

            plank
        }
    }

    @ViewBuilder
    private func itemView(_ item: ShelfItem) -> some View {
        switch item {
        case .book(let spine):
            SpineView(
                spine: spine,
                accent: accent,
                photo: SpineImageCache.shared.image(for: spine.id, from: photos),
                dimmed: highlight != nil && highlight != spine.id,
                lit: highlight == spine.id,
                carried: draggingID == spine.id
            )
        case .object(let object):
            ShelfObjectView(object: object, carried: draggingID == object.id)
                // Dimmed alongside the books when one is being pointed out, or
                // the plant stays bright while every book behind it recedes.
                .saturation(highlight != nil ? 0.15 : 1)
                .opacity(highlight != nil ? 0.4 : 1)
        }
    }

    // MARK: - Rearranging

    /// Sliding a held book around, attached to the whole case rather than to the
    /// book.
    ///
    /// It has to live here, and this is the bug that cost the most to find:
    /// moving an item to another shelf moves its view to another `HStack`, so
    /// SwiftUI tears the old one down — and a gesture dies with the view that
    /// owns it. `onEnded` never arrived, so a cross-shelf drag looked perfect on
    /// screen and committed nothing. Sliding *within* a shelf kept the same view
    /// alive, which is exactly why that half always worked.
    ///
    /// The case is never torn down, so its `onEnded` always arrives.
    /// `simultaneousGesture` rather than `gesture` so taps and scrolling still
    /// reach the shelf underneath; when nothing is being carried this does
    /// nothing at all.
    private var carryGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(caseSpace))
            .onChanged { drag in
                guard draggingID != nil else { return }
                carry(to: drag.location)
            }
            .onEnded { _ in finishCarrying() }
    }

    private func beginCarrying(_ id: String) {
        guard draggingID == nil else { return }
        Haptics.saved()
        // Seeded from what's on screen, objects included — otherwise carrying a
        // book would drop every decoration out of the arrangement it's about to
        // save. Padded out to the visible planks so an empty shelf is somewhere
        // a thing can actually be dropped, rather than a gap with no row behind
        // it.
        var rows = planks(width: caseWidth).map { $0.map(\.id) }
        while rows.count < max(Self.minimumShelves, plankFrames.count) { rows.append([]) }
        liveRows = rows
        carryOriginRows = rows
        carryStartLevel = rows.firstIndex { $0.contains(id) } ?? 0
        draggingID = id
    }

    /// Move the carried thing to wherever the finger is now.
    ///
    /// Works in shelf-and-slot terms rather than on one flat list, and that is
    /// the whole point: the packer fills from the top, so on a flat list an
    /// ornament could never be put on the third shelf while the first still had
    /// room — it would be pulled straight back up.
    /// Rebuilt from the arrangement the drag started with, every time, rather
    /// than nudged from wherever the last frame left it. Dragging from the top
    /// of the case to the bottom crosses every shelf on the way, and each one
    /// it touched used to keep the shuffle it got in passing — so a book moved
    /// three shelves down quietly rearranged the two it travelled through.
    /// Starting from the original each time means only the shelf under the
    /// finger ever changes.
    private func carry(to point: CGPoint) {
        guard let draggingID else { return }
        let level = self.level(at: point.y)

        var rows = carryOriginRows
        while rows.count <= level { rows.append([]) }
        for i in rows.indices { rows[i].removeAll { $0 == draggingID } }
        let slot = insertionSlot(in: rows[level], at: point.x)
        rows[level].insert(draggingID, at: min(slot, rows[level].count))
        makeRoom(&rows, from: level, keeping: draggingID)

        // Nothing actually moved. Animating anyway fires a haptic for nothing,
        // which reads as the shelf twitching under a still finger.
        guard rows != liveRows else { return }
        withAnimation(.snappy(duration: 0.18)) { liveRows = rows }
        Haptics.pageTurn()
    }

    /// Push whatever no longer fits onto the shelf below, and keep going.
    ///
    /// A case with fifty books on it has no empty shelves, so a drop that
    /// simply refused when a shelf was full would mean an ornament could never
    /// be put on the third shelf at all — which is what it felt like. Shoving
    /// something in makes room the way it does on a real shelf: whatever is on
    /// the end goes down to the next one, and so on to the bottom of the case.
    ///
    /// What moves is never the thing being carried. It stays exactly where it
    /// was put, or the drop would look like the shelf had thrown it back.
    private func makeRoom(_ rows: inout [[String]], from level: Int, keeping carried: String) {
        let lookup = itemsByID
        var i = level
        while i < rows.count {
            while rows[i].count > 1,
                  ShelfLayout.overflows(rows[i].compactMap { lookup[$0] }, width: caseWidth) {
                guard let victim = rows[i].last(where: { $0 != carried }),
                      let at = rows[i].lastIndex(of: victim) else { break }
                if i + 1 == rows.count { rows.append([]) }
                rows[i].remove(at: at)
                rows[i + 1].insert(victim, at: 0)
            }
            i += 1
        }
    }

    /// Which shelf level the finger is over.
    ///
    /// Falls back to the nearest bay rather than giving up, because the bands
    /// don't quite tile the case: the plank between two bays belongs to
    /// neither, and everything below the last one is off the bottom of them
    /// all. A drop aimed at a board — or dragged past the end of the case,
    /// which is how you'd reach for a shelf that isn't drawn yet — has to land
    /// somewhere rather than snapping back.
    private func level(at y: Double) -> Int {
        let last = max(0, liveRows.count - 1)
        guard !plankFrames.isEmpty else { return min(carryStartLevel, last) }
        if let hit = plankFrames.first(where: { $0.value.minY <= y && y <= $0.value.maxY })?.key {
            return min(hit, last)
        }
        let nearest = plankFrames.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
        return min(nearest ?? carryStartLevel, last)
    }

    /// Where in a shelf the finger falls, counting slots from the left.
    ///
    /// Past the last item gives the end slot, which is why this is a scan
    /// rather than a hit test against other items: the bare stretch of plank
    /// beyond the last book is where most ornaments actually live, and there is
    /// nothing there to aim at.
    private func insertionSlot(in row: [String], at x: Double) -> Int {
        var slot = 0
        for candidate in row {
            guard let frame = frames[candidate] else { continue }
            if x > frame.midX { slot += 1 } else { break }
        }
        return slot
    }

    private func finishCarrying() {
        defer {
            draggingID = nil
            liveRows = []
            carryOriginRows = []
        }
        guard draggingID != nil, !liveRows.isEmpty else { return }
        // Only what's on screen: the shelf may be filtered, and the store
        // splices this run back into the full arrangement.
        onReorder?(ShelfOrder.flatten(liveRows))
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

/// Where each shelf level's bay is. Separate from the spine frames because an
/// *empty* shelf has nothing in it to hit-test, and an empty shelf is exactly
/// where somebody wants to put the first ornament.
private struct PlankFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        // Last one wins, and the keys are unique now that a plank *is* a shelf.
        // They weren't always: several planks shared a level, this merged their
        // bands into one, and level 0's band then covered most of the case — so
        // a book dragged anywhere near the middle read as belonging to the top
        // shelf. Keep it a plain overwrite, so a duplicate key is a visible bug
        // rather than a band that silently swallows the bookcase.
        value.merge(nextValue()) { _, new in new }
    }
}

/// How wide a shelf is, reported up from the layout so the drag can pack the
/// same way the drawing does.
private struct CaseWidthKey: PreferenceKey {
    static let defaultValue = 0.0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
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
