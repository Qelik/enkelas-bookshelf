import BookshelfCore
import SwiftUI
import UIKit

/// The accent colour, as SwiftUI sees it.
///
/// **Deliberately not inside `ThemeStore`.** `UIColor(dynamicProvider:)` is
/// imported from Objective-C without `@Sendable`, so in Swift 6 a closure handed
/// to it *inherits the isolation of wherever it was written*. Written inside
/// `@MainActor final class ThemeStore`, the provider became main-actor isolated —
/// and UIKit calls a dynamic provider whenever it resolves the colour for a trait
/// collection, including on `com.apple.SwiftUI.AsyncRenderer`. That tripped the
/// main-actor assertion and crashed the app in
/// `_dispatch_assert_queue_fail` ("Block was expected to execute on queue").
///
/// At file scope this is nonisolated, so the provider is too, and UIKit may call
/// it from any thread — which is the contract it actually has.
extension AppTheme {
    var color: Color {
        Color(uiColor: UIColor { traits in
            UIColor(self.accent(dark: traits.userInterfaceStyle == .dark))
        })
    }

    /// The page behind everything.
    var background: Color {
        Color(uiColor: UIColor { traits in
            UIColor(self.background(dark: traits.userInterfaceStyle == .dark))
        })
    }

    /// The back of the bookcase.
    var shelfBack: Color {
        Color(uiColor: UIColor { traits in
            UIColor(self.shelfBack(dark: traits.userInterfaceStyle == .dark))
        })
    }

    /// The board the books stand on.
    var shelfPlank: Color {
        Color(uiColor: UIColor { traits in
            UIColor(self.shelfPlank(dark: traits.userInterfaceStyle == .dark))
        })
    }

    /// Cards and rows sitting on `background`.
    var surface: Color {
        Color(uiColor: UIColor { traits in
            UIColor(self.surface(dark: traits.userInterfaceStyle == .dark))
        })
    }
}

extension UIColor {
    /// The four lines `BookshelfCore` deliberately doesn't have: it stays free of
    /// SwiftUI and UIKit so `swift test` runs on macOS without a simulator, and
    /// hands out RGB components instead.
    convenience init(_ rgb: AppTheme.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

// MARK: - Environment

private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.fallback.color
}

private struct ThemeBackgroundKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.fallback.background
}

private struct ThemeSurfaceKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.fallback.surface
}

extension EnvironmentValues {
    /// The accent as a plain `Color`, for the handful of places that need the
    /// colour itself rather than the ambient tint.
    ///
    /// A `Color` rather than the store: reading an `@Observable @MainActor` object
    /// from inside a render path is what caused the crash above, and a view that
    /// only wants a colour has no business holding the thing that persists it.
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }

    var themeBackground: Color {
        get { self[ThemeBackgroundKey.self] }
        set { self[ThemeBackgroundKey.self] = newValue }
    }

    var themeSurface: Color {
        get { self[ThemeSurfaceKey.self] }
        set { self[ThemeSurfaceKey.self] = newValue }
    }
}

// MARK: - Applying it

/// The theme's page colour behind a screen.
///
/// `List`, `Form` and `ScrollView` paint `systemGroupedBackground` themselves, so
/// tinting the container alone does nothing — the scroll content has to be told
/// to stop painting over it first. That pairing is the whole reason this is a
/// modifier rather than a `.background()` at each call site: half of it silently
/// does nothing.
private struct ThemedPage: ViewModifier {
    @Environment(\.themeBackground) private var background

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(background)
    }
}

/// Rows that sit *on* the page as cards — grouped lists and forms.
private struct ThemedRows: ViewModifier {
    @Environment(\.themeSurface) private var surface

    func body(content: Content) -> some View {
        content.listRowBackground(surface)
    }
}

extension View {
    /// Tint a screen's page. Apply to the `List`/`Form`/`ScrollView` itself.
    func themedPage() -> some View { modifier(ThemedPage()) }

    /// Card-style rows on the tinted page, for grouped lists and forms.
    func themedRows() -> some View { modifier(ThemedRows()) }

    /// Transparent rows, for plain lists where the page colour should show
    /// through rather than each row being its own card.
    func themedPlainRows() -> some View { listRowBackground(Color.clear) }
}
