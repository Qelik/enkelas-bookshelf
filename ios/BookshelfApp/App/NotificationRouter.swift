import BookshelfCore
import UserNotifications

/// Opens the book a notification was about.
///
/// A nudge that names a book and then drops you on the app's front door has
/// wasted the one thing it knew. The book id rides along in `userInfo` and lands
/// in `PendingDeepLink`, which `Router` already drains on activation — the same
/// path an App Intent uses.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let bookID = info["bookID"] as? String, !bookID.isEmpty else { return }
        await MainActor.run { PendingDeepLink.set(.book(bookID)) }
    }

    /// Show it even with the app open.
    ///
    /// The default is to swallow it, which makes the feature look broken to
    /// anyone testing it — and a banner is the honest thing regardless: the
    /// reminder fired, so say so.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
