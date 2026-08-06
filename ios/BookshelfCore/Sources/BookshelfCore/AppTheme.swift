import Foundation

/// The app's accent colour, chosen per person.
///
/// Two people share this app and want different colours, so the choice belongs to
/// whoever is signed in rather than to the app.
///
/// **Stored on the device, not in the shelf.** `normalize()` is a rebuild
/// whitelist — it reconstructs the blob field by field and drops anything it
/// doesn't know — so a `theme` smuggled into settings would be silently erased
/// the first time the web app touched the shelf. It is also the wrong thing to
/// sync: a colour is about the phone in your hand, and pushing it would repaint
/// the other person's device.
///
/// Colours are RGB components rather than SwiftUI `Color`s to keep `BookshelfCore`
/// free of SwiftUI — that is what lets `swift test` run on macOS in a second. Each
/// target does its own four-line conversion.
public enum AppTheme: String, CaseIterable, Sendable, Identifiable {
    case plum, blush, ocean, forest, ember, graphite

    public var id: String { rawValue }

    /// Matches the app icon, so a fresh install looks deliberate.
    public static let fallback = AppTheme.plum

    public var label: String {
        switch self {
        case .plum: "Plum"
        case .blush: "Blush"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .ember: "Ember"
        case .graphite: "Graphite"
        }
    }

    /// A one-line description of who each is for — the picker is a row of
    /// swatches, and a swatch alone doesn't say what it's called.
    public var blurb: String {
        switch self {
        case .plum: "The original."
        case .blush: "Pink, and unapologetic."
        case .ocean: "Cool and quiet."
        case .forest: "Green, easy on the eye."
        case .ember: "Warm, like a reading lamp."
        case .graphite: "No colour at all."
        }
    }

    /// Separate light and dark values on purpose: one accent can't serve both.
    /// A pink dark enough to read on white glows on black, and one bright enough
    /// for black disappears on white.
    public func accent(dark: Bool) -> RGB {
        switch (self, dark) {
        case (.plum, false): RGB(0x6D4B7C)
        case (.plum, true): RGB(0xBD93CE)
        case (.blush, false): RGB(0xC7185F)
        case (.blush, true): RGB(0xFF9EC4)
        case (.ocean, false): RGB(0x0B6E99)
        case (.ocean, true): RGB(0x63C2E8)
        case (.forest, false): RGB(0x2C6B45)
        case (.forest, true): RGB(0x7DC79D)
        case (.ember, false): RGB(0xB2451C)
        case (.ember, true): RGB(0xF0916A)
        case (.graphite, false): RGB(0x4A4A52)
        case (.graphite, true): RGB(0xB6B6C0)
        }
    }

    /// The page behind everything, tinted with the theme.
    ///
    /// **Barely tinted on purpose.** The text on top is the system's label
    /// colours, which are tuned for the system's own greys; push the background
    /// far toward a hue and the contrast ratio goes with it. This is the accent's
    /// hue at a few percent saturation — enough to feel like the theme, not
    /// enough to make anything harder to read.
    public func background(dark: Bool) -> RGB {
        let hue = accent(dark: dark)
        return dark
            ? RGB.blend(hue, into: RGB(0x0E0E10), amount: 0.10)
            : RGB.blend(hue, into: RGB(0xF2F2F7), amount: 0.10)
    }

    /// Cards and rows sitting on `background`.
    ///
    /// Lighter than the page in light mode and *lighter* again in dark, matching
    /// how the system's grouped backgrounds behave — a card darker than its page
    /// reads as a hole rather than a surface.
    public func surface(dark: Bool) -> RGB {
        let hue = accent(dark: dark)
        return dark
            ? RGB.blend(hue, into: RGB(0x1C1C1E), amount: 0.12)
            : RGB.blend(hue, into: RGB(0xFFFFFF), amount: 0.07)
    }

    /// The back of the bookcase, behind the books.
    ///
    /// Deep and desaturated so cream spines stay legible against it — the same
    /// relationship the app icon uses. Derived in HSB rather than by scaling RGB
    /// toward black, which drains the hue and turns every theme the same brown.
    public func shelfBack(dark: Bool) -> RGB {
        accent(dark: dark).deepened(toBrightness: dark ? 0.13 : 0.19, saturation: 0.55)
    }

    /// The board the books stand on. Lighter than the case so it reads as a
    /// separate piece of wood catching light.
    public func shelfPlank(dark: Bool) -> RGB {
        accent(dark: dark).deepened(toBrightness: dark ? 0.32 : 0.42, saturation: 0.62)
    }

    /// sRGB, 0…1.
    public struct RGB: Sendable, Hashable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `amount` of `tint` mixed into `base`.
        public static func blend(_ tint: RGB, into base: RGB, amount: Double) -> RGB {
            let a = min(1, max(0, amount))
            return RGB(
                red: base.red + (tint.red - base.red) * a,
                green: base.green + (tint.green - base.green) * a,
                blue: base.blue + (tint.blue - base.blue) * a
            )
        }

        /// Relative luminance, for checking a colour is still readable under text.
        public var luminance: Double {
            func channel(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        /// WCAG contrast ratio against another colour.
        public func contrast(with other: RGB) -> Double {
            let a = luminance, b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Toward a target brightness in HSB, keeping the hue exactly.
        ///
        /// Scaling RGB channels toward black instead loses saturation, and the
        /// pale accents all converge on the same mauve-brown — which is how the
        /// app icon's Blush and Plum ended up indistinguishable.
        public func deepened(toBrightness brightness: Double, saturation target: Double) -> RGB {
            let maxC = max(red, green, blue), minC = min(red, green, blue)
            let delta = maxC - minC
            var hue = 0.0
            if delta > 0 {
                if maxC == red { hue = (green - blue) / delta }
                else if maxC == green { hue = 2 + (blue - red) / delta }
                else { hue = 4 + (red - green) / delta }
                hue *= 60
                if hue < 0 { hue += 360 }
            }
            let s = delta == 0 ? 0 : target
            let v = brightness
            if s == 0 { return RGB(red: v, green: v, blue: v) }

            let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
            let i = floor(sector), f = sector - i
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch Int(i) {
            case 0: return RGB(red: v, green: t, blue: p)
            case 1: return RGB(red: q, green: v, blue: p)
            case 2: return RGB(red: p, green: v, blue: t)
            case 3: return RGB(red: p, green: q, blue: v)
            case 4: return RGB(red: t, green: p, blue: v)
            default: return RGB(red: v, green: p, blue: q)
            }
        }

        public init(_ hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }
}

// MARK: - Codable

extension AppTheme: Codable {
    /// Unknown names decode to the default rather than throwing.
    ///
    /// The widget reads a snapshot the app wrote, and the two are separate
    /// binaries that update at different moments. A theme added in a new app
    /// build would otherwise make the *whole* snapshot fail to decode and blank
    /// every widget — losing the shelf, the streak and the goal over a colour.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppTheme(rawValue: raw) ?? .fallback
    }
}

// MARK: - Per-account storage

/// Where a person's chosen theme is remembered.
///
/// Keyed by account id so two people sharing one device each keep their own
/// colour, and signing out doesn't hand your theme to the next person.
public enum ThemeStorage {
    private static let signedOutKey = "app-theme"

    public static func key(forAccount id: String?) -> String {
        guard let id, !id.isEmpty else { return signedOutKey }
        return "\(signedOutKey).\(id)"
    }

    public static func read(accountID: String?, from defaults: UserDefaults = .standard) -> AppTheme {
        guard let raw = defaults.string(forKey: key(forAccount: accountID)) else {
            // Falling back to the signed-out choice means someone who picked a
            // colour before making an account keeps it afterwards, rather than
            // having it reset by signing in.
            if accountID != nil, let shared = defaults.string(forKey: signedOutKey) {
                return AppTheme(rawValue: shared) ?? .fallback
            }
            return .fallback
        }
        return AppTheme(rawValue: raw) ?? .fallback
    }

    public static func write(
        _ theme: AppTheme, accountID: String?, to defaults: UserDefaults = .standard
    ) {
        defaults.set(theme.rawValue, forKey: key(forAccount: accountID))
    }
}


/// Light, dark, or whatever the phone is doing.
///
/// Per account like the theme: two people sharing a device shouldn't have to
/// agree about this either.
public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public extension ThemeStorage {
    private static var appearanceKey: String { "app-appearance" }

    static func key(appearanceFor id: String?) -> String {
        guard let id, !id.isEmpty else { return appearanceKey }
        return "\(appearanceKey).\(id)"
    }

    static func readAppearance(accountID: String?, from defaults: UserDefaults = .standard) -> AppearanceMode {
        let raw = defaults.string(forKey: key(appearanceFor: accountID))
            ?? defaults.string(forKey: appearanceKey)
        return raw.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static func writeAppearance(
        _ mode: AppearanceMode, accountID: String?, to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key(appearanceFor: accountID))
    }
}
