import SwiftUI
import UIKit

/// The three moments in this app worth feeling.
///
/// Deliberately short: haptics stop meaning anything once everything buzzes, and
/// the ones here mark a page turning, work being saved, and something being won.
/// Nothing fires for navigation or for typing.
///
/// Every call is a no-op when Reduce Motion is on — the setting is about
/// vestibular comfort, and a phone that keeps vibrating in someone's hand is the
/// same complaint by another route.
@MainActor
enum Haptics {

    static func pageTurn() {
        guard enabled else { return }
        // Selection, not impact: a page turn is a change of position, and impact
        // at this frequency reads as a fault.
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func saved() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func unlocked() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private static var enabled: Bool { !UIAccessibility.isReduceMotionEnabled }
}
