import Foundation

/// The reading clock, ported from `startClock()` / `markActivity()` / `cpm()` in
/// `src/reader.ts`.
///
/// This is the part of the reader worth porting rather than adopting from a
/// library. It measures *active* reading, not elapsed time: leaving a book open
/// on the table must not turn into an hour of reading, and the estimate of
/// "time left" is only useful if the speed it's built on is real.
///
/// Three rules, all from the web app:
///
/// - The clock stops after `idleTimeout` without a page turn or a touch.
/// - A gap longer than `sessionGap` starts a *new* session rather than
///   extending the old one — a book reopened the next morning is not one long
///   overnight session.
/// - Speed is learned per reader, seeded at `defaultCharactersPerMinute` until
///   there's enough evidence to replace the guess.
public struct ReadingSession: Sendable, Equatable {

    /// Two minutes without interaction and we stop counting.
    public static let idleTimeout: TimeInterval = 120
    /// A fifteen-minute lull means the next page belongs to a new session.
    public static let sessionGap: TimeInterval = 900
    /// ~200 words per minute, until the reader's own pace is known.
    public static let defaultCharactersPerMinute: Double = 1000
    /// Below this there isn't enough evidence to trust a measured pace.
    static let minimumSecondsToLearnSpeed: Double = 60
    static let minimumCharactersToLearnSpeed: Double = 500

    public private(set) var activeSeconds: Double = 0
    public private(set) var charactersRead: Double = 0
    private var lastActivity: Date?
    private var lastTick: Date?

    public init() {}

    /// A page turn or a touch. Returns true when the gap was long enough that
    /// this should count as a new session.
    @discardableResult
    public mutating func markActivity(at now: Date = Date()) -> Bool {
        defer { lastActivity = now; lastTick = lastTick ?? now }
        guard let last = lastActivity else { return false }
        let gap = now.timeIntervalSince(last)
        if gap >= Self.sessionGap {
            // Long enough away that this is a fresh sitting.
            activeSeconds = 0
            charactersRead = 0
            lastTick = now
            return true
        }
        return false
    }

    /// Advance the clock. Called on a timer while the reader is open; the time
    /// since the last tick only counts if the reader was actually interacting.
    public mutating func tick(at now: Date = Date()) {
        guard let last = lastTick, let activity = lastActivity else {
            lastTick = now
            return
        }
        let sinceActivity = now.timeIntervalSince(activity)
        if sinceActivity <= Self.idleTimeout {
            activeSeconds += now.timeIntervalSince(last)
        }
        lastTick = now
    }

    /// Called when a page is turned, with the characters on the page just read.
    public mutating func countPage(characters: Int, at now: Date = Date()) {
        markActivity(at: now)
        charactersRead += Double(max(0, characters))
    }

    /// Stop counting — the reader was closed or backgrounded.
    public mutating func pause() {
        lastTick = nil
    }

    public var minutes: Double { activeSeconds / 60 }

    /// The reader's measured pace, or nil while there isn't enough to go on.
    ///
    /// Guarded on both time and characters: thirty seconds of flicking through
    /// would otherwise "learn" a speed of several thousand a minute and make
    /// every estimate afterwards nonsense.
    public var measuredCharactersPerMinute: Double? {
        guard activeSeconds >= Self.minimumSecondsToLearnSpeed,
              charactersRead >= Self.minimumCharactersToLearnSpeed
        else { return nil }
        let rate = charactersRead / (activeSeconds / 60)
        // Anything outside human range is a measurement artefact, not a reader.
        guard rate > 200, rate < 20000 else { return nil }
        return rate
    }

    /// Blend a newly measured pace into the stored one.
    ///
    /// Weighted rather than replaced: one unusually fast chapter shouldn't
    /// rewrite the estimate, but a genuine change in pace should still show up
    /// over a few sittings.
    public static func blend(stored: Double?, measured: Double?) -> Double? {
        guard let measured else { return stored }
        guard let stored else { return measured }
        return stored * 0.7 + measured * 0.3
    }

    /// Minutes left, given how many characters remain.
    public static func minutesRemaining(characters: Int, at rate: Double?) -> Double? {
        guard characters > 0 else { return 0 }
        let cpm = rate ?? defaultCharactersPerMinute
        guard cpm > 0 else { return nil }
        return Double(characters) / cpm
    }

    /// "about 12 min left", "about 1 hr 5 min left" — or nil when there's
    /// nothing useful to say.
    public static func timeLeftDescription(characters: Int, at rate: Double?) -> String? {
        guard let minutes = minutesRemaining(characters: characters, at: rate), minutes >= 1 else { return nil }
        let total = Int(minutes.rounded())
        if total < 60 { return "about \(total) min left" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "about \(hours) hr left" : "about \(hours) hr \(rest) min left"
    }
}
