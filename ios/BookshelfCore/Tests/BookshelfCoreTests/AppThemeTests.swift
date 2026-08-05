import Foundation
import Testing
@testable import BookshelfCore

/// Two people share this app and want different colours, so the theme is stored
/// per account and travels to the widgets. Both of those are places it can go
/// wrong silently — the wrong person's colour, or no widget at all.
struct AppThemeTests {

    static func defaults() -> UserDefaults {
        // A private suite: `.standard` would leak between tests and pick up
        // whatever the last one wrote.
        let suite = UserDefaults(suiteName: "theme-tests-\(UUID().uuidString)")!
        return suite
    }

    @Test("each account keeps its own colour")
    func perAccount() {
        let d = Self.defaults()
        ThemeStorage.write(.blush, accountID: "wife", to: d)
        ThemeStorage.write(.ocean, accountID: "me", to: d)

        #expect(ThemeStorage.read(accountID: "wife", from: d) == .blush)
        #expect(ThemeStorage.read(accountID: "me", from: d) == .ocean)
        // Signing out doesn't hand your colour to whoever signs in next.
        #expect(ThemeStorage.read(accountID: nil, from: d) == .fallback)
    }

    @Test("a colour chosen before signing up survives signing up")
    func signedOutChoiceCarriesForward() {
        // Otherwise picking a colour, then making an account, silently resets it
        // — which reads as the app forgetting.
        let d = Self.defaults()
        ThemeStorage.write(.ember, accountID: nil, to: d)
        #expect(ThemeStorage.read(accountID: "new-account", from: d) == .ember)

        // Once that account has a choice of its own, that wins.
        ThemeStorage.write(.forest, accountID: "new-account", to: d)
        #expect(ThemeStorage.read(accountID: "new-account", from: d) == .forest)
        #expect(ThemeStorage.read(accountID: nil, from: d) == .ember)
    }

    @Test("a name we don't recognise falls back instead of failing")
    func unknownNameFallsBack() {
        let d = Self.defaults()
        d.set("chartreuse", forKey: ThemeStorage.key(forAccount: nil))
        #expect(ThemeStorage.read(accountID: nil, from: d) == .fallback)
    }

    @Test("a theme added by a newer app build doesn't blank every widget")
    func unknownThemeDoesNotBreakTheSnapshot() throws {
        // The app and the widget are separate binaries that update at different
        // moments. A strict decode here would throw on the *whole* snapshot and
        // lose the shelf, the streak and the goal — over a colour.
        let json = #"""
        {"reading":[],"streakCurrent":4,"streakLongest":9,"readToday":true,
         "pagesToday":30,"goalTarget":24,"goalDone":3,"goalYear":2026,
         "goalExpected":11.5,"title":"Wren's Bookshelf","theme":"marigold",
         "updatedAt":"2026-08-05T10:00:00Z"}
        """#
        let decoded = try JSONDecoder.snapshot.decode(WidgetSnapshot.self, from: Data(json.utf8))

        #expect(decoded.theme == .fallback)
        // Everything else still arrived, which is the point.
        #expect(decoded.streakCurrent == 4)
        #expect(decoded.title == "Wren's Bookshelf")
    }

    @Test("the chosen theme reaches the widgets")
    func themeRoundTripsThroughTheSnapshot() throws {
        var state = Normalizer(now: { Date(timeIntervalSince1970: 0) }, makeID: { "x" }).defaultState()
        state.books = [Fixture.book(id: "b1", title: "A Book")]

        let snapshot = WidgetSnapshot.make(from: state, title: "T", theme: .blush)
        let decoded = try JSONDecoder.snapshot.decode(
            WidgetSnapshot.self, from: try JSONEncoder.snapshot.encode(snapshot)
        )
        #expect(decoded.theme == .blush)
    }

    @Test("every theme has a distinct light and dark accent")
    func lightAndDarkDiffer() {
        // One accent can't serve both: dark enough to read on white is too dark
        // on black. A theme where they match is a theme someone forgot to finish.
        for theme in AppTheme.allCases {
            #expect(theme.accent(dark: false) != theme.accent(dark: true), "\(theme.label)")
            #expect(!theme.label.isEmpty)
            #expect(!theme.blurb.isEmpty)
        }
    }

    @Test("the default matches the app icon")
    func defaultIsPlum() {
        // A fresh install should look deliberate rather than arbitrary.
        #expect(AppTheme.fallback == .plum)
    }
}
