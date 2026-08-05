// Renders the app icon.
//
// CoreGraphics rather than an SVG toolchain: this machine has no rsvg-convert,
// ImageMagick or Pillow, and `swift` ships with Xcode. It also means the icon is
// reproducible from source — regenerate at any size instead of hand-editing a
// PNG nobody can diff.
//
//   swift ios/Tools/make-app-icon.swift <out-dir>
//
// Writes icon-<variant>-1024.png for each variant plus contact-sheet.png, which
// shows each one at 1024, 180 and 60 points. The 60 is the one that matters:
// an icon that only works large is an icon nobody recognises on their phone.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Plumbing

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// Opaque on purpose: an App Store icon with an alpha channel is rejected at
/// upload, and `.noneSkipLast` is what guarantees the PNG has none.
func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("couldn't create \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
}

func linearGradient(_ ctx: CGContext, in rect: CGRect, _ from: CGColor, _ to: CGColor) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()
}

func roundedRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

/// Rotate about a point — used for the leaning spine. Restores the state itself
/// so callers can't leak a transform into the next shape.
func rotated(_ ctx: CGContext, about pivot: CGPoint, degrees: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -pivot.x, y: -pivot.y)
    body()
    ctx.restoreGState()
}

// MARK: - Palette
//
// The plum is the placeholder-cover family the app and the web version already
// draw for a book with no art (hue ≈ 290), so the icon belongs to the same set
// of colours as the shelf behind it.

let plumLight = rgb(0x7A5389)
let plumDark = rgb(0x33203C)
let shelfInk = rgb(0x241C1A)
let cream = rgb(0xF7EFE0)
let creamDim = rgb(0xE4D6C0)
let gold = rgb(0xE8B44C)
let rose = rgb(0xCF8478)
let ink = rgb(0x2A2420)

// MARK: - Variants

/// One per `AppTheme`, so the Home Screen icon can follow the colour the user
/// picked in Settings. Values duplicated from `AppTheme.accent(dark:)` because
/// this script is standalone — it can't import BookshelfCore.
///
/// The *dark* accent is used: an icon sits on an arbitrary wallpaper, so it needs
/// the brighter of the two to stay distinct, and the light accents are too muted
/// at 60 points.
enum Theme: String, CaseIterable {
    case plum, blush, ocean, forest, ember, graphite

    var accent: CGColor {
        switch self {
        case .plum: rgb(0xBD93CE)
        case .blush: rgb(0xFF9EC4)
        case .ocean: rgb(0x63C2E8)
        case .forest: rgb(0x7DC79D)
        case .ember: rgb(0xF0916A)
        case .graphite: rgb(0xB6B6C0)
        }
    }

    /// The gradient the books stand against — the accent, deepened so cream
    /// spines stay legible on top of it.
    var wall: (CGColor, CGColor) {
        (accent.deepened(to: 0.58), accent.deepened(to: 0.30))
    }
}

extension CGColor {
    /// Darken to a target brightness in HSB, boosting saturation as it goes.
    ///
    /// Scaling the RGB channels toward black instead loses the hue: the accents
    /// are pale, so multiplying them drops saturation and everything converges on
    /// mauve-brown. Blush and Plum came out near-identical at 60 points, which
    /// defeats the entire point of the icon following the theme. Working in HSB
    /// keeps the hue exactly and lets saturation rise to compensate for the lost
    /// brightness.
    func deepened(to brightness: CGFloat) -> CGColor {
        guard let c = components, c.count >= 3 else { return self }
        var (h, s, v) = CGColor.toHSB(r: c[0], g: c[1], b: c[2])
        s = min(1, s * 1.55)
        v = brightness
        let (r, g, b) = CGColor.toRGB(h: h, s: s, v: v)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func toHSB(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h: CGFloat = 0
        if delta > 0 {
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    static func toRGB(h: CGFloat, s: CGFloat, v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s == 0 { return (v, v, v) }
        let sector = (h / 60).truncatingRemainder(dividingBy: 6)
        let i = floor(sector)
        let f = sector - i
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(i) {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// Everything is expressed against a 1024 grid and scaled, so the same code
/// renders the 1024 asset and the 60-point legibility check.
func draw(_ theme: Theme, in ctx: CGContext, origin: CGPoint, size: CGFloat) {
    let s = size / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * s, y: origin.y + y * s)
    }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s)
    }

    let (wallTop, wallBottom) = theme.wall
    linearGradient(ctx, in: r(0, 0, 1024, 1024), wallTop, wallBottom)

        // Three spines on a shelf. Distinctive on purpose — almost every reading
        // app is an open book, and a shelf is what this app actually is.
        //
        // A near-black shelf rather than a coloured one: the wall is now the
    // theme's colour, and rose against a Blush or Ember wall disappears.
    // Dark reads as a shelf in shadow against every accent.
    roundedRect(ctx, r(126, 174, 772, 58), radius: 29 * s, shelfInk)

        roundedRect(ctx, r(222, 232, 148, 486), radius: 24 * s, creamDim)
        roundedRect(ctx, r(244, 606, 104, 28), radius: 14 * s, wallBottom)

        roundedRect(ctx, r(390, 232, 164, 598), radius: 26 * s, cream)
        roundedRect(ctx, r(414, 716, 116, 32), radius: 16 * s, wallBottom)

        // Leaning against the middle one, pivoting on its own base corner so the
        // foot stays planted on the shelf instead of floating above it.
        rotated(ctx, about: p(574, 232), degrees: -13) {
            roundedRect(ctx, r(574, 232, 150, 522), radius: 24 * s, gold)
            roundedRect(ctx, r(598, 652, 102, 28), radius: 14 * s, wallBottom)
        }

}

func render(_ theme: Theme, size: CGFloat) -> CGImage {
    let ctx = makeContext(width: Int(size), height: Int(size))
    draw(theme, in: ctx, origin: .zero, size: size)
    return ctx.makeImage()!
}

// MARK: - Main

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for theme in Theme.allCases {
    write(render(theme, size: 1024), to: outDir.appending(path: "AppIcon-\(theme.rawValue.capitalized)-1024.png"))
}

// Contact sheet: each variant large, then at the two sizes iOS actually shows.
let previewSizes: [CGFloat] = [360, 180, 60]
let gutter: CGFloat = 40
let rowHeight = previewSizes[0] + gutter * 2
let sheetWidth = gutter + previewSizes.reduce(0) { $0 + $1 + gutter }
let sheetHeight = rowHeight * CGFloat(Theme.allCases.count)

let sheet = makeContext(width: Int(sheetWidth), height: Int(sheetHeight))
sheet.setFillColor(rgb(0xF2F2F5))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

for (row, theme) in Theme.allCases.enumerated() {
    // Top row first: CoreGraphics counts y upward, the reader counts down.
    let rowBottom = sheetHeight - CGFloat(row + 1) * rowHeight
    var x = gutter
    for size in previewSizes {
        draw(theme, in: sheet, origin: CGPoint(x: x, y: rowBottom + gutter), size: size)
        x += size + gutter
    }
}
write(sheet.makeImage()!, to: outDir.appending(path: "contact-sheet.png"))
print("wrote \(Theme.allCases.count) themed icons + contact-sheet.png to \(outDir.path)")
