import BookshelfCore
import SwiftUI
import UIKit
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// True for the gallery preview and for a shelf that has never been written,
    /// so a widget can say "no books yet" instead of showing invented ones.
    let isPlaceholder: Bool
}

/// Reads what the app published to the App Group.
///
/// There is no polling and no refresh interval to speak of: the app calls
/// `WidgetCenter.reloadAllTimelines()` when the shelf changes, which is the only
/// moment any of this can change. A timeline that refreshed on a timer would
/// spend the extension's daily budget redrawing identical pixels.
///
/// The one exception is midnight — "read today" and "pages left today" become
/// wrong the instant the date rolls over, with nothing having happened in the
/// app to trigger a reload.
struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The widget gallery has no data of its own; showing a real shelf there
        // is better than an empty box, but a first-run user has none.
        guard let published = WidgetSnapshot.published() else {
            completion(SnapshotEntry(date: Date(), snapshot: .preview, isPlaceholder: true))
            return
        }
        completion(SnapshotEntry(date: Date(), snapshot: published, isPlaceholder: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let published = WidgetSnapshot.published()
        let entry = SnapshotEntry(
            date: now,
            snapshot: published ?? WidgetSnapshot(),
            isPlaceholder: published == nil
        )
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

extension WidgetSnapshot {
    /// Gallery preview content. Recognisably fake — a real title here would look
    /// like the user's own shelf and make an empty widget confusing.
    static let preview = WidgetSnapshot(
        reading: [
            Item(id: "preview", title: "The Name of the Wind", author: "Patrick Rothfuss",
                 currentPage: 214, pages: 662, progress: 214.0 / 662.0, hue: 284),
        ],
        streakCurrent: 12, streakLongest: 31, readToday: false,
        pagesToday: 18, pagesTargetToday: 42,
        goalTarget: 24, goalDone: 9, goalYear: 2026, goalExpected: 11.4,
        title: "Bookshelf", theme: .plum, updatedAt: Date()
    )
}

// MARK: - Shared bits

extension WidgetSnapshot {
    /// The accent whoever owns this shelf picked. A widget in the app's
    /// colour and an app in another looks like two different apps.
    var accent: Color {
        Color(uiColor: UIColor { traits in
            let rgb = theme.accent(dark: traits.userInterfaceStyle == .dark)
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

extension WidgetSnapshot.Item {
    /// The same gradient the app draws for a book with no cover art, so a widget
    /// and the shelf show the same spine.
    var coverGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: Double(hue) / 360, saturation: 0.35, brightness: 0.55),
                Color(hue: Double(hue) / 360, saturation: 0.45, brightness: 0.38),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// A widget cannot open an arbitrary screen; it opens a URL the app then routes.
enum WidgetLink {
    static let scheme = "bookshelf"

    static func book(_ id: String) -> URL {
        // Percent-encoded: ids are normally UUIDs, but an imported shelf can
        // carry anything, and one space makes the URL nil and the tap dead.
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return URL(string: "\(scheme)://book/\(escaped)") ?? shelf
    }

    static let shelf = URL(string: "\(scheme)://reading")!
    static let progress = URL(string: "\(scheme)://progress")!
}
