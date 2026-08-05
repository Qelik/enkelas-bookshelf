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
}
