import BookshelfCore
import SwiftUI

extension AppearanceMode {
    /// `nil` hands the decision back to the system, which is what `.system` means
    /// — not "light".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
