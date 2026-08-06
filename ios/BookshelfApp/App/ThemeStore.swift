import BookshelfCore
import Observation
import SwiftUI

/// The chosen accent colour, and everything that has to be told when it changes.
///
/// Held as an object rather than an `@AppStorage` in a view because three things
/// need it: the view tree's tint, the Home Screen widgets, and whichever account
/// is signed in — and the last of those means it has to be re-read on sign-in,
/// which a plain `@AppStorage` key can't express.
@Observable
@MainActor
final class ThemeStore {

    private(set) var theme: AppTheme
    private(set) var appearance: AppearanceMode
    /// The account the current choice belongs to, so signing in as someone else
    /// loads their colour instead of inheriting yours.
    private var accountID: String?

    private let defaults: UserDefaults
    private var onChange: (() -> Void)?

    init(accountID: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accountID = accountID
        self.theme = ThemeStorage.read(accountID: accountID, from: defaults)
        self.appearance = ThemeStorage.readAppearance(accountID: accountID, from: defaults)
    }

    /// Called after any change, to republish the widget snapshot. Set by the app
    /// once the publisher exists — the two would otherwise have to construct
    /// each other.
    func onThemeChanged(_ handler: @escaping () -> Void) {
        onChange = handler
    }

    func select(_ appearance: AppearanceMode) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        ThemeStorage.writeAppearance(appearance, accountID: accountID, to: defaults)
    }

    func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        ThemeStorage.write(theme, accountID: accountID, to: defaults)
        onChange?()
    }

    /// Re-read for whoever is signed in now.
    ///
    /// Two people share this app; the colour follows the person, not the phone.
    func accountChanged(to id: String?) {
        guard id != accountID else { return }
        accountID = id
        appearance = ThemeStorage.readAppearance(accountID: id, from: defaults)
        let next = ThemeStorage.read(accountID: id, from: defaults)
        guard next != theme else { return }
        theme = next
        onChange?()
    }

}
