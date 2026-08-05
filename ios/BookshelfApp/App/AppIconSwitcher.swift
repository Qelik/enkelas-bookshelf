import BookshelfCore
import UIKit

/// Puts the theme on the Home Screen icon.
///
/// `setAlternateIconName` is the only public way to do this, and it comes with a
/// system alert the app can't suppress ("You have changed the icon for
/// Bookshelf"). That's the cost of the feature, not a bug to work around — the
/// private tricks that hide it are the sort of thing that fails review.
///
/// The alternates are declared at build time in
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`; nothing can be added at
/// runtime. Plum is the *primary* icon, so selecting it means passing `nil`
/// rather than a name.
@MainActor
enum AppIconSwitcher {

    /// Nil for the primary icon. A theme with no matching asset simply doesn't
    /// change the icon rather than throwing.
    static func iconName(for theme: AppTheme) -> String? {
        switch theme {
        case .plum: nil                       // the primary AppIcon
        case .blush: "AppIcon-Blush"
        case .ocean: "AppIcon-Ocean"
        case .forest: "AppIcon-Forest"
        case .ember: "AppIcon-Ember"
        case .graphite: "AppIcon-Graphite"
        }
    }

    static func apply(_ theme: AppTheme) async {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let wanted = iconName(for: theme)
        // Already right — calling anyway would pop the system alert for nothing,
        // which is the difference between a feature and an irritation.
        guard wanted != UIApplication.shared.alternateIconName else { return }
        try? await UIApplication.shared.setAlternateIconName(wanted)
    }
}
