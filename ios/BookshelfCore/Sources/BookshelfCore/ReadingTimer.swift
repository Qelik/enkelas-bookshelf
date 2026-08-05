import Foundation
import Observation

/// The reading-session stopwatch, ported from `toggleTimer` / `runTimer` /
/// `restoreTimer` in `src/app.ts`.
///
/// It runs off an **absolute start timestamp mirrored to disk**, not a tick
/// count. That is the whole design: iOS suspends and eventually kills a
/// backgrounded app, and a counter held in memory would silently reset. Storing
/// the instant it started means reopening the book — even after a cold launch
/// hours later — resumes the same session with the right elapsed time.
///
/// The timestamp is what's persisted; the displayed value is always derived from
/// `now - start`, so a suspended app can't drift.
@Observable
@MainActor
public final class ReadingTimer {

    /// Sessions older than this are abandoned rather than resumed. Somebody who
    /// left the timer running overnight did not read for nine hours.
    public static let maximumSession: TimeInterval = 12 * 3600

    public struct Saved: Codable, Sendable, Equatable {
        public var start: Date
        public var bookID: String
    }

    public private(set) var running: Saved?
    /// Ticks once a second while running, purely so the view redraws.
    public private(set) var tick = 0

    private let defaults: UserDefaults
    private let key: String
    private var timer: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, key: String = "enkelas-bookshelf-timer") {
        self.defaults = defaults
        self.key = key
    }

    /// Elapsed seconds, derived from the start instant every time it's read.
    public var elapsed: TimeInterval {
        guard let running else { return 0 }
        return max(0, Date().timeIntervalSince(running.start))
    }

    public var elapsedMinutes: Int { Int((elapsed / 60).rounded()) }

    /// `MM:SS`, or `H:MM:SS` past an hour.
    public var display: String {
        let total = Int(elapsed)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    public func isRunning(for bookID: String) -> Bool { running?.bookID == bookID }

    // MARK: - Control

    public func start(bookID: String, at date: Date = Date()) {
        let saved = Saved(start: date, bookID: bookID)
        running = saved
        persist(saved)
        startTicking()
    }

    /// Stop and return the minutes to add to the session being logged.
    @discardableResult
    public func stop() -> Int {
        let minutes = elapsedMinutes
        running = nil
        timer?.cancel()
        timer = nil
        defaults.removeObject(forKey: key)
        return minutes
    }

    /// Resume this book's session if one is still fresh.
    ///
    /// Only *this* book's — someone with a timer running on one book who opens
    /// another's log should see a clean slate, and the first book's session must
    /// survive being looked away from.
    public func resume(for bookID: String, now: Date = Date()) {
        guard let saved = load(),
              saved.bookID == bookID,
              now.timeIntervalSince(saved.start) < Self.maximumSession
        else {
            // Deliberately does NOT clear what's stored: closing a sheet, or
            // glancing at a different book, must not discard a running session.
            stopTickingOnly()
            return
        }
        running = saved
        startTicking()
    }

    /// Stop the visible ticker, keep the stored session. For leaving a screen.
    public func pauseDisplay() { stopTickingOnly() }

    /// Any session still stored, regardless of book — lets the UI offer to
    /// resume after a cold launch.
    public func pendingSession(now: Date = Date()) -> Saved? {
        guard let saved = load(), now.timeIntervalSince(saved.start) < Self.maximumSession else { return nil }
        return saved
    }

    // MARK: - Internals

    private func startTicking() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick &+= 1
            }
        }
    }

    private func stopTickingOnly() {
        timer?.cancel()
        timer = nil
        running = nil
    }

    private func persist(_ saved: Saved) {
        defaults.set(try? JSONEncoder().encode(saved), forKey: key)
    }

    private func load() -> Saved? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }
}
