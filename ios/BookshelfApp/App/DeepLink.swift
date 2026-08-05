import BookshelfCore
import Foundation
import Observation

/// Somewhere in the app that something outside it can ask for.
///
/// Four different systems need this and none of them can hand over a SwiftUI
/// view: a widget can only open a URL, Spotlight hands back an item identifier,
/// an App Intent runs in another process entirely, and Handoff arrives as an
/// `NSUserActivity`. They all funnel into this one enum so there is a single
/// place that decides what "open a book" means.
enum DeepLink: Equatable {
    case book(String)
    case reading
    case progress

    /// `bookshelf://book/<id>`, which is what the widgets emit.
    init?(url: URL) {
        guard url.scheme == "bookshelf" else { return nil }
        switch url.host() {
        case "book":
            let id = url.pathComponents.dropFirst().first ?? ""
            guard !id.isEmpty else { return nil }
            self = .book(id)
        case "reading":
            self = .reading
        case "progress":
            self = .progress
        default:
            return nil
        }
    }
}

/// A destination set by a process that isn't the app.
///
/// `openAppWhenRun` launches the app but gives the intent no way to say *where*
/// to land, so the intent writes here and the app reads it on the way up. The
/// App Group is the only storage both can see.
enum PendingDeepLink {
    private static let key = "pending-deep-link"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedContainer.groupIdentifier) ?? .standard
    }

    static func set(_ link: DeepLink) {
        switch link {
        case .book(let id): defaults.set("book:\(id)", forKey: key)
        case .reading: defaults.set("reading", forKey: key)
        case .progress: defaults.set("progress", forKey: key)
        }
    }

    /// Reads *and clears*. A destination that survived being consumed would send
    /// the app back to the same book on every subsequent launch.
    static func take() -> DeepLink? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        if raw.hasPrefix("book:") { return .book(String(raw.dropFirst(5))) }
        if raw == "reading" { return .reading }
        if raw == "progress" { return .progress }
        return nil
    }
}

enum RootTab: Hashable {
    case reading, shelf, reader, progress, community
}

/// Where the app currently is, for anything that wants to change it.
@Observable
@MainActor
final class Router {
    /// The tab shown by `RootView`.
    var tab: RootTab = .reading
    /// A book to push on top of the Reading tab, cleared once shown.
    var openBook: String?

    func follow(_ link: DeepLink) {
        switch link {
        case .book(let id):
            tab = .reading
            openBook = id
        case .reading:
            tab = .reading
            openBook = nil
        case .progress:
            tab = .progress
            openBook = nil
        }
    }

    func follow(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        follow(link)
    }

    /// Anything an intent left behind while the app was closed.
    func followPending() {
        guard let link = PendingDeepLink.take() else { return }
        follow(link)
    }
}
