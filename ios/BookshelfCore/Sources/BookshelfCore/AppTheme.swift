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
