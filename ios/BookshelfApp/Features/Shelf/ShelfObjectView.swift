import BookshelfCore
import SwiftUI

/// The things on the shelf that aren't books, drawn.
///
/// **Shapes rather than emoji or images.** The bookcase is the one screen in
/// this app that isn't flat UI — spines are drawn with gradients, a lean and a
/// shadow, standing on a lit plank. An emoji pasted onto that reads as a
/// sticker on furniture, and a bitmap would need three resolutions and a
/// designer. Drawn shapes take the theme, scale to any size and cost nothing to
/// ship.
///
/// Every object is built from the same handful of primitives and tinted from
/// one hue, so a jade plant and a red-leafed one — or a marble bust and a
/// bronze one — are the same drawing with a different number.
struct ShelfObjectView: View {
    let object: ShelfObject
    var carried = false

    private var size: CGSize {
        let s = object.kind.size
        return CGSize(width: s.width, height: s.height)
    }

    /// The object's own colour ramp, from its single hue.
    private func shade(_ brightness: Double, _ saturation: Double = 0.45) -> Color {
        Color(hue: object.tint / 360, saturation: saturation, brightness: brightness)
    }

    // MARK: - Light
    //
    // One convention for the whole shelf: the light comes from the upper left,
    // the way it does in every drawn spine beside these. Objects lit from
    // different directions read as cut-outs pasted together, which is exactly
    // the flatness this is meant to fix.

    /// A rounded solid — the shading that turns an ellipse into a ball.
    ///
    /// Three parts, and the middle one is the one that does the work: a lit
    /// side, a **core shadow set in from the edge** rather than at it, and a
    /// thin bounce along the dark rim where the shelf throws light back up. A
    /// plain light-to-dark gradient reads as a gradient; this reads as a
    /// surface curving away.
    private func roundedSolid(_ base: Double, _ saturation: Double = 0.45) -> some ShapeStyle {
        RadialGradient(
            colors: [
                shade(min(1, base + 0.26), saturation * 0.8),
                shade(base, saturation),
                shade(max(0.06, base - 0.24), min(1, saturation + 0.12)),
                shade(max(0.08, base - 0.14), saturation),
            ],
            center: UnitPoint(x: 0.32, y: 0.26),
            startRadius: 0,
            endRadius: 90
        )
    }

    /// A turned surface — a pot, a candle jar, a neck. Lit down one side rather
    /// than from a point, the way a cylinder actually takes light.
    private func turnedSolid(_ base: Double, _ saturation: Double = 0.45) -> some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: shade(max(0.06, base - 0.16), saturation), location: 0),
                .init(color: shade(min(1, base + 0.22), saturation * 0.85), location: 0.24),
                .init(color: shade(base, saturation), location: 0.52),
                .init(color: shade(max(0.05, base - 0.26), min(1, saturation + 0.1)), location: 0.86),
                // The bounce off the plank, which stops the dark edge going dead.
                .init(color: shade(max(0.08, base - 0.12), saturation), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// A tight specular, for anything glazed — a pot, a jar, a polished stone.
    private func gloss(_ w: Double, _ h: Double, opacity: Double = 0.4) -> some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(opacity), .white.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: w, height: h)
            .blur(radius: 0.6)
    }

    /// What the object throws onto the plank. Wider and fainter than the object,
    /// offset away from the light.
    private var groundShadow: some View {
        Ellipse()
            .fill(.black.opacity(0.38))
            .frame(width: size.width * 0.92, height: max(4, size.height * 0.06))
            .blur(radius: 3)
            .offset(x: size.width * 0.06, y: max(2, size.height * 0.02))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The object's shadow on the plank, behind it. A figurine with no
            // contact shadow floats however well the object itself is shaded —
            // this is most of what makes it sit *in* the scene rather than on
            // top of it.
            groundShadow
            drawing
        }
        .frame(width: size.width, height: size.height)
        // Bottom-aligned like the books: things stand on the plank.
        .frame(maxHeight: .infinity, alignment: .bottom)
        .contentShape(.rect)
        .offset(y: carried ? -18 : 0)
            .scaleEffect(carried ? 1.06 : 1, anchor: .bottom)
            .shadow(color: .black.opacity(carried ? 0.5 : 0), radius: 8, y: 6)
            .zIndex(carried ? 1 : 0)
            .animation(.snappy(duration: 0.18), value: carried)
            .accessibilityElement()
            .accessibilityLabel(object.displayName)
    }

    @ViewBuilder
    private var drawing: some View {
        switch object.kind {
        case .plant: plant
        case .stackedBooks: stackedBooks
        case .candle: candle
        case .bookend: bookend
        case .photo: photo
        case .clock: clock
        case .cat: cat
        case .crystal: crystal
        case .bust: bust
        case .dragonPerched: dragonPerched
        case .dragonCoiled: dragonCoiled
        }
    }

    // MARK: - Plant

    private var plant: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            // A stack, not absolute offsets. Offsetting leaves upward from a
            // bottom-aligned container pushed them clean out of the object's own
            // frame and they were clipped by the shelf above — the foliage
            // vanished and a bare pot was left standing.
            VStack(spacing: -h * 0.04) {
                foliage(width: w, height: h * 0.7)
                pot(width: w, height: h * 0.3)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    /// Leaves on stems, fanned out from the middle and staying inside the frame.
    private func foliage(width w: Double, height h: Double) -> some View {
        ZStack(alignment: .bottom) {
            ForEach(0..<7, id: \.self) { i in
                leaf(index: i, width: w, height: h)
            }
        }
        .frame(width: w, height: h, alignment: .bottom)
    }

    private func leaf(index i: Int, width w: Double, height h: Double) -> some View {
        // -1…1 across the fan.
        let spread = Double(i - 3) / 3
        // Outer leaves sit lower, the way a trailing plant actually falls.
        let lift = h * (0.52 - abs(spread) * 0.26)
        // Leaves on the shadow side are darker: one light source, so the fan has
        // a lit half and a dark half rather than seven identical cut-outs.
        let facing = 0.44 + Double(i % 3) * 0.06 - spread * 0.1
        let stem = Capsule()
            .fill(shade(0.3, 0.55))
            .frame(width: 2.5, height: h * 0.4)
            .rotationEffect(.degrees(spread * 32), anchor: .bottom)
        let blade = ZStack {
            Ellipse().fill(roundedSolid(facing, 0.52))
            // The midrib, which is what stops a leaf reading as a lozenge.
            Capsule()
                .fill(shade(max(0.1, facing - 0.14), 0.55))
                .frame(width: w * 0.3, height: 1)
            // A wet-looking highlight along the upper edge.
            Ellipse()
                .fill(.white.opacity(0.22))
                .frame(width: w * 0.18, height: w * 0.05)
                .offset(x: -w * 0.05, y: -w * 0.045)
                .blur(radius: 0.8)
        }
        .frame(width: w * 0.36, height: w * 0.2)
        .rotationEffect(.degrees(spread * 46))
        .offset(x: spread * w * 0.36, y: -lift)
        return ZStack(alignment: .bottom) { stem; blade }
    }

    private func pot(width w: Double, height h: Double) -> some View {
        // Terracotta, lit as a cylinder — the light band down one side and the
        // bounce up the other are what give it a round belly instead of a flat
        // orange trapezoid.
        let clay = { (b: Double) in Color(hue: 0.055, saturation: 0.58, brightness: b) }
        return ZStack(alignment: .top) {
            Trapezoid(topInset: 0, bottomInset: 0.12)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: clay(0.4), location: 0),
                            .init(color: clay(0.72), location: 0.26),
                            .init(color: clay(0.56), location: 0.55),
                            .init(color: clay(0.3), location: 0.88),
                            .init(color: clay(0.42), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            // Soil in the rim, so the plant grows out of something.
            Ellipse()
                .fill(Color(hue: 0.08, saturation: 0.5, brightness: 0.2))
                .frame(height: 6)
                .padding(.horizontal, 3)
                .offset(y: 1)
            // The rim itself, catching light on its upper lip.
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(clay(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(colors: [clay(0.82), clay(0.46)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .padding(.bottom, 3)
            }
            .frame(height: 7)
            gloss(w * 0.1, h * 0.5, opacity: 0.2)
                .offset(x: -w * 0.17, y: h * 0.35)
        }
        .frame(width: w * 0.78, height: h)
    }

    // MARK: - Books lying flat

    private var stackedBooks: some View {
        GeometryReader { g in
            // Sizes worked out before the view builder: long arithmetic inside
            // one makes the type checker take minutes over a shape it can solve
            // instantly when the numbers arrive as plain Doubles.
            let w = g.size.width
            let h = g.size.height
            let each = (h - 4) / 3
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    stackedBook(index: i, width: w - Double(i) * w * 0.12, height: each)
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    /// One book in the stack. Each a different hue, stepping round the wheel
    /// from the object's own — a stack is never one colour.
    private func stackedBook(index: Int, width: Double, height: Double) -> some View {
        let hue = (object.tint + Double(index) * 47).truncatingRemainder(dividingBy: 360) / 360
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.38, brightness: 0.66), Color(hue: hue, saturation: 0.46, brightness: 0.4)], startPoint: .top, endPoint: .bottom))
            // The pages, seen along the fore-edge.
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 1.5)
                .padding(.horizontal, 3)
                .padding(.top, 3)
        }
        .frame(width: width, height: height)
    }

    // MARK: - Candle

    private var candle: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    flame.frame(width: w * 0.3, height: h * 0.22)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: 1.6, height: h * 0.07)
                    // The jar, with wax showing through.
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(shade(0.72, 0.2).opacity(0.5))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(turnedSolid(0.82, 0.28))
                            .padding(.horizontal, w * 0.12)
                            .padding(.top, w * 0.1)
                            .padding(.bottom, 3)
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .frame(height: h * 0.55)
                }
            }
        }
    }

    private var flame: some View {
        ZStack {
            Ellipse().fill(Color(hue: 0.09, saturation: 0.85, brightness: 1))
            Ellipse()
                .fill(Color(hue: 0.14, saturation: 0.35, brightness: 1))
                .padding(.horizontal, 2)
                .padding(.top, 4)
        }
        .shadow(color: Color(hue: 0.1, saturation: 0.9, brightness: 1).opacity(0.7), radius: 6)
    }

    // MARK: - Bookend

    private var bookend: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottomLeading) {
                // The foot, which is the half that does the work.
                RoundedRectangle(cornerRadius: 1)
                    .fill(shade(0.5, 0.12))
                    .frame(width: w, height: h * 0.1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(turnedSolid(0.6, 0.1))
                    .frame(width: w * 0.3, height: h)
            }
        }
    }

    // MARK: - Framed photo

    private var photo: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(turnedSolid(0.6, 0.4))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hue: 0.6, saturation: 0.25, brightness: 0.28))
                    .padding(w * 0.11)
                // A little landscape rather than a grey rectangle: at this size
                // the *suggestion* of a picture is what reads.
                ZStack(alignment: .bottom) {
                    Circle()
                        .fill(Color(hue: 0.58, saturation: 0.35, brightness: 0.62))
                        .frame(width: w * 0.2)
                        .offset(y: -h * 0.16)
                    Hills()
                        .fill(Color(hue: 0.55, saturation: 0.4, brightness: 0.42))
                }
                .padding(w * 0.13)
                .clipShape(.rect(cornerRadius: 1))
            }
        }
    }

    // MARK: - Clock

    private var clock: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(turnedSolid(0.58, 0.4))
                    Circle().fill(shade(0.93, 0.08)).padding(w * 0.11)
                    // Hands at ten past ten, which is how every clock is drawn.
                    Hand(angle: -60, length: 0.3).stroke(.black.opacity(0.7), style: .init(lineWidth: 2, lineCap: .round))
                    Hand(angle: 30, length: 0.24).stroke(.black.opacity(0.7), style: .init(lineWidth: 2, lineCap: .round))
                    Circle().fill(.black.opacity(0.7)).frame(width: 3)
                }
                .frame(width: w * 0.86, height: w * 0.86)
                RoundedRectangle(cornerRadius: 2)
                    .fill(shade(0.42, 0.4))
                    .frame(width: w * 0.5, height: max(3, h - w * 0.86))
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    // MARK: - Cat

    private var cat: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottomLeading) {
                // Curled body, shaded as a mass with a lit back and a dark belly.
                Ellipse().fill(roundedSolid(0.5, 0.5))
                    .frame(width: w * 0.86, height: h * 0.8)
                    .offset(x: w * 0.14)
                // The haunch, a second mass over the first — a curled cat is two
                // overlapping volumes, not one blob.
                Ellipse().fill(roundedSolid(0.58, 0.42))
                    .frame(width: w * 0.6, height: h * 0.54)
                    .offset(x: w * 0.3, y: -h * 0.1)
                // Tail, curled round the front and lit along its top.
                Tail()
                    .stroke(
                        LinearGradient(colors: [shade(0.56, 0.5), shade(0.34, 0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        style: .init(lineWidth: max(4, h * 0.16), lineCap: .round)
                    )
                    .frame(width: w * 0.4, height: h * 0.5)
                    .offset(x: w * 0.62, y: -h * 0.04)
                catHead(width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    private func catHead(width w: Double, height h: Double) -> some View {
        ZStack {
            // Ears behind the skull, with pink inners.
            Ear().fill(shade(0.44, 0.5)).frame(width: w * 0.11, height: h * 0.26)
                .offset(x: -w * 0.055, y: -h * 0.3)
            Ear().fill(shade(0.48, 0.5)).frame(width: w * 0.11, height: h * 0.26)
                .offset(x: w * 0.055, y: -h * 0.3)
            Ear().fill(Color(hue: 0.96, saturation: 0.3, brightness: 0.7))
                .frame(width: w * 0.05, height: h * 0.14)
                .offset(x: -w * 0.055, y: -h * 0.26)
            Ear().fill(Color(hue: 0.96, saturation: 0.3, brightness: 0.7))
                .frame(width: w * 0.05, height: h * 0.14)
                .offset(x: w * 0.055, y: -h * 0.26)

            Circle().fill(roundedSolid(0.56, 0.5))
            // Muzzle, catching the light — a cat's face is not a flat disc.
            Ellipse()
                .fill(shade(0.66, 0.34))
                .frame(width: w * 0.2, height: h * 0.16)
                .offset(y: h * 0.06)
                .blur(radius: 0.5)
            // Shut eyes — it's asleep, which is the whole charm.
            HStack(spacing: w * 0.05) {
                ClosedEye().stroke(.black.opacity(0.7), style: .init(lineWidth: 1.5, lineCap: .round))
                    .frame(width: w * 0.07, height: h * 0.08)
                ClosedEye().stroke(.black.opacity(0.7), style: .init(lineWidth: 1.5, lineCap: .round))
                    .frame(width: w * 0.07, height: h * 0.08)
            }
            .offset(y: h * 0.01)
            Triangle()
                .fill(Color(hue: 0.96, saturation: 0.4, brightness: 0.72))
                .frame(width: w * 0.035, height: h * 0.04)
                .rotationEffect(.degrees(180))
                .offset(y: h * 0.07)
        }
        .frame(width: w * 0.42, height: w * 0.42)
        .offset(y: -h * 0.14)
    }

    // MARK: - Ornament

    private var crystal: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            VStack(spacing: 0) {
                ZStack {
                    Diamond().fill(roundedSolid(0.62, 0.5))
                    // One lit face, so it reads as a solid rather than a symbol.
                    DiamondHalf().fill(.white.opacity(0.25))
                }
                .frame(width: w * 0.8, height: h * 0.86)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(shade(0.4, 0.12))
                    .frame(width: w, height: max(3, h * 0.1))
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    // MARK: - Bust

    private var bust: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            // Head, neck and shoulders as one connected silhouette. Drawn as
            // separate pieces it came out a chess pawn — a circle floating over
            // a triangle, which is what a bust is *not*.
            ZStack(alignment: .bottom) {
                bustPlinth(width: w, height: h)
                bustShoulders(width: w, height: h)
                bustHead(width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    private func bustPlinth(width w: Double, height h: Double) -> some View {
        VStack(spacing: 0) {
            Trapezoid(topInset: 0.1, bottomInset: 0)
                .fill(shade(0.6, 0.12))
                .frame(width: w * 0.5, height: h * 0.1)
            Rectangle()
                .fill(shade(0.48, 0.12))
                .frame(width: w * 0.72, height: h * 0.06)
        }
        .frame(width: w, height: h, alignment: .bottom)
    }

    private func bustShoulders(width w: Double, height h: Double) -> some View {
        // Wide at the bottom, narrowing into the neck — the classic cut of a
        // marble bust, which is most of what makes it readable this small.
        // Narrower and shorter than a full torso: a bust is mostly head, and
        // giving it a body's worth of shoulders is what made it read as a chess
        // piece rather than a carving. Lit as stone — a cool shadow side, a warm
        // lit side, and a bounce off the plank.
        ZStack {
            Trapezoid(topInset: 0.3, bottomInset: 0)
                .fill(turnedSolid(0.78, 0.07))
            // A draped edge, so the marble has a cut rather than a straight taper.
            Ellipse()
                .fill(shade(0.62, 0.1))
                .frame(width: w * 0.6, height: h * 0.05)
                .offset(y: h * 0.12)
                .blur(radius: 1.2)
        }
        .frame(width: w * 0.66, height: h * 0.3)
        .offset(y: -h * 0.14)
        .frame(width: w, height: h, alignment: .bottom)
    }

    private func bustHead(width w: Double, height h: Double) -> some View {
        ZStack {
            // Beard first, so the face sits over it.
            // Beard first, so the face sits over it.
            Ellipse()
                .fill(roundedSolid(0.68, 0.1))
                .frame(width: w * 0.5, height: h * 0.3)
                .offset(y: h * 0.09)
            // The skull, shaded as stone rather than filled flat.
            Ellipse()
                .fill(roundedSolid(0.86, 0.05))
                .frame(width: w * 0.54, height: h * 0.38)
            // Brow ridge and the shadow it casts — the single feature that most
            // says "carving" rather than "egg".
            Ellipse()
                .fill(.black.opacity(0.16))
                .frame(width: w * 0.42, height: h * 0.05)
                .offset(y: -h * 0.03)
                .blur(radius: 1.4)
            // Cheekbone catching the light.
            Ellipse()
                .fill(.white.opacity(0.24))
                .frame(width: w * 0.16, height: h * 0.07)
                .offset(x: -w * 0.11, y: h * 0.01)
                .blur(radius: 1.6)
            // A cap of hair, sitting slightly proud of the skull.
            Ellipse()
                .fill(roundedSolid(0.7, 0.11))
                .frame(width: w * 0.58, height: h * 0.2)
                .offset(y: -h * 0.14)
            // Blank eyes, the way carved marble has them.
            HStack(spacing: w * 0.11) {
                Ellipse().fill(shade(0.56, 0.12)).frame(width: w * 0.07, height: h * 0.028)
                Ellipse().fill(shade(0.56, 0.12)).frame(width: w * 0.07, height: h * 0.028)
            }
            .offset(y: -h * 0.02)
            .blur(radius: 0.4)
        }
        .frame(width: w, height: h * 0.4, alignment: .center)
        .offset(y: -h * 0.36)
        .frame(width: w, height: h, alignment: .bottom)
    }

    // MARK: - Dragons

    /// A dragon sitting up, wings folded — the shape a bookshelf figurine takes.
    ///
    /// Built silhouette-first: at 60×86 the only thing that reads is the
    /// outline, so the body, the arched neck and the raised wing are drawn as
    /// three large overlapping masses rather than as anatomy.
    private var dragonPerched: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack(alignment: .bottom) {
                dragonTail(width: w, height: h)
                dragonWing(width: w, height: h)
                dragonBody(width: w, height: h)
                dragonNeck(width: w, height: h)
                dragonHead(width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    private func dragonTail(width w: Double, height h: Double) -> some View {
        Tail()
            .stroke(shade(0.42, 0.55), style: .init(lineWidth: max(3, w * 0.09), lineCap: .round))
            .frame(width: w * 0.44, height: h * 0.26)
            .offset(x: w * 0.3, y: -h * 0.03)
            .frame(width: w, height: h, alignment: .bottom)
    }

    /// The raised wing, which is what separates a dragon from a lizard.
    private func dragonWing(width w: Double, height h: Double) -> some View {
        Wing()
            .fill(turnedSolid(0.36, 0.55))
            .frame(width: w * 0.52, height: h * 0.46)
            .rotationEffect(.degrees(-14))
            .offset(x: w * 0.2, y: -h * 0.34)
            .frame(width: w, height: h, alignment: .bottom)
    }

    private func dragonBody(width w: Double, height h: Double) -> some View {
        // A pear standing on its base: heavy haunches, chest tapering upward.
        Trapezoid(topInset: 0.3, bottomInset: 0.05)
            .fill(roundedSolid(0.5, 0.55))
            .frame(width: w * 0.56, height: h * 0.44)
            .offset(x: -w * 0.06)
            .frame(width: w, height: h, alignment: .bottom)
    }

    private func dragonNeck(width w: Double, height h: Double) -> some View {
        Neck()
            .stroke(shade(0.52, 0.55), style: .init(lineWidth: max(5, w * 0.15), lineCap: .round))
            .frame(width: w * 0.26, height: h * 0.3)
            .offset(x: -w * 0.16, y: -h * 0.38)
            .frame(width: w, height: h, alignment: .bottom)
    }

    private func dragonHead(width w: Double, height h: Double) -> some View {
        ZStack {
            // Snout pointing away from the body, so it reads as facing out.
            Ellipse()
                .fill(roundedSolid(0.56, 0.55))
                .frame(width: w * 0.34, height: h * 0.14)
            Horn()
                .fill(shade(0.74, 0.3))
                .frame(width: w * 0.1, height: h * 0.12)
                .offset(x: w * 0.07, y: -h * 0.1)
            Circle()
                .fill(Color(hue: 0.12, saturation: 0.9, brightness: 0.95))
                .frame(width: max(2, w * 0.05))
                .offset(x: -w * 0.07)
        }
        .offset(x: -w * 0.22, y: -h * 0.66)
        .frame(width: w, height: h, alignment: .bottom)
    }

    /// A dragon curled up asleep, seen from the side.
    private var dragonCoiled: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack(alignment: .bottom) {
                // An actual coil — a thick arc of body curling round on itself.
                // Overlapping ellipses read as a blob at this size; a ring with
                // a gap reads as a creature wrapped around nothing.
                Circle()
                    .trim(from: 0.04, to: 0.82)
                    .stroke(
                        shade(0.46, 0.55),
                        style: StrokeStyle(lineWidth: h * 0.3, lineCap: .round)
                    )
                    // Half the stroke falls outside the circle's own bounds, so
                    // the lift is that half — any less and it sinks through the
                    // plank, any more and it hovers over it.
                    .frame(width: w * 0.66, height: h * 0.62)
                    .offset(x: w * 0.08, y: -h * 0.1)
                coiledRidge(width: w, height: h)
                coiledTail(width: w, height: h)
                coiledHead(width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    /// Plates down the back, following the curve of the coil.
    /// Plates round the outside of the coil, following its curve.
    private func coiledRidge(width w: Double, height h: Double) -> some View {
        ForEach(0..<6, id: \.self) { i in
            // Spread over the top of the ring, each plate turned to face out.
            let angle = -150.0 + Double(i) * 34
            Triangle()
                .fill(shade(0.72, 0.35))
                .frame(width: w * 0.08, height: h * 0.15)
                .offset(y: -h * 0.32)
                .rotationEffect(.degrees(angle))
        }
        .offset(x: w * 0.08, y: -h * 0.16)
        .frame(width: w, height: h, alignment: .bottom)
    }

    /// The tail tip, tucked in beside the head the way a sleeping animal does.
    private func coiledTail(width w: Double, height h: Double) -> some View {
        Ellipse()
            .fill(roundedSolid(0.4, 0.55))
            .frame(width: w * 0.2, height: h * 0.12)
            .rotationEffect(.degrees(-24))
            .offset(x: w * 0.02, y: -h * 0.06)
            .frame(width: w, height: h, alignment: .bottom)
    }

    private func coiledHead(width w: Double, height h: Double) -> some View {
        ZStack {
            Ellipse()
                .fill(roundedSolid(0.58, 0.55))
                .frame(width: w * 0.32, height: h * 0.28)
            Horn()
                .fill(shade(0.76, 0.3))
                .frame(width: w * 0.08, height: h * 0.16)
                .offset(x: w * 0.07, y: -h * 0.15)
            // Shut, like the cat. A sleeping dragon is an ornament; an awake one
            // is a monster on your bookshelf.
            ClosedEye()
                .stroke(.black.opacity(0.6), style: .init(lineWidth: 1.3, lineCap: .round))
                .frame(width: w * 0.08, height: h * 0.05)
                .offset(x: -w * 0.03, y: -h * 0.01)
        }
        .offset(x: -w * 0.24, y: -h * 0.12)
        .frame(width: w, height: h, alignment: .bottom)
    }
}

// MARK: - Primitives
//
// Small shapes shared across the objects. Kept here rather than in Core: they
// are drawing, and `BookshelfCore` has no SwiftUI in it on purpose.

private struct Trapezoid: Shape {
    /// Fractions of the width taken off each side.
    var topInset: Double
    var bottomInset: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * topInset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * topInset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * bottomInset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * bottomInset, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/// The lit half of a diamond, so an ornament has a facet rather than being flat.
private struct DiamondHalf: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Hills: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.width * 0.25, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.width * 0.75, y: r.minY - r.height * 0.2))
        p.closeSubpath()
        return p
    }
}

private struct Hand: Shape {
    var angle: Double
    var length: Double
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radians = (angle - 90) * .pi / 180
        var p = Path()
        p.move(to: c)
        p.addLine(to: CGPoint(
            x: c.x + cos(radians) * r.width * length,
            y: c.y + sin(radians) * r.width * length
        ))
        return p
    }
}

private struct Ear: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct ClosedEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

private struct Tail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}

private struct Neck: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

private struct Wing: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.minY))
        // Scalloped trailing edge, which is what says "wing" at this size.
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.midY),
                       control: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Horn: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Beard: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
