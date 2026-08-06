import BookshelfCore
import Foundation
import UserNotifications

/// Two reminders, both of which the web version can't send at all.
///
/// A daily nudge at a time the reader picks, and a warning the day before a
/// library book is due. Nothing else: notification permission is spent the
/// moment it's abused, and a reading tracker that pesters gets muted.
@MainActor
enum Reminders {

    /// The old single repeating request. Kept only so an install that still
    /// has one queued gets it cleared rather than fired forever.
    static let dailyIdentifier = "daily-reading"
    static let dailyPrefix = "daily-reading-"
    static let loanPrefix = "loan-due-"

    // MARK: - Permission

    /// Ask once, at the moment the user turns a reminder on — never at launch,
    /// where the question has no context and the honest answer is "no".
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Daily nudge

    /// How many days of nudges are queued at once.
    ///
    /// A repeating request would be simpler, but its content is fixed at
    /// scheduling time — it cannot name the book you're actually reading, which
    /// is the entire point. So each day gets its own one-shot, written for that
    /// day's shelf, and the queue is re-armed whenever the app is opened.
    ///
    /// Fourteen because iOS caps an app at 64 pending notifications and the loan
    /// reminders need room too. Someone who doesn't open the app for a fortnight
    /// stops being nudged, which is the right way round: the alternative is an
    /// app that keeps talking to someone who has stopped listening.
    static let queuedDays = 14

    /// Queue the next fortnight of nudges, each written for its own day.
    static func scheduleDaily(
        at time: Date,
        state: WireState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        let center = UNUserNotificationCenter.current()
        await cancelQueuedNudges()

        let hour = calendar.component(.hour, from: time)
        let minute = calendar.component(.minute, from: time)

        for offset in 0..<queuedDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  // Today's slot may already have passed.
                  fire > now
            else { continue }

            // Written for the shelf as it stands. It will be out of date by the
            // time a distant one fires — hence the re-arm on every launch, which
            // is where the accuracy actually comes from.
            let nudge = ReadingNudges.nudge(for: state, on: fire, calendar: calendar)

            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.body
            content.sound = .default
            if let bookID = nudge.bookID {
                // Tapping it opens the book rather than the app's front door.
                content.userInfo = ["bookID": bookID]
            }

            try? await center.add(UNNotificationRequest(
                identifier: "\(dailyPrefix)\(offset)",
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                    repeats: false
                )
            ))
        }
    }

    /// Rewrite the queue, if the user has the daily nudge switched on.
    ///
    /// Called on every activation: a nudge naming "you're 40 pages from the end"
    /// stops being true the moment those pages are read, and the queue is written
    /// up to a fortnight ahead.
    static func rearmDailyIfOn(state: WireState, now: Date = Date()) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "daily-reminder-on") else { return }
        guard await authorizationStatus() == .authorized else { return }
        let seconds = defaults.double(forKey: "daily-reminder-time")
        let time = Calendar.current.startOfDay(for: now)
            .addingTimeInterval(seconds > 0 ? seconds : 20 * 3600)
        await scheduleDaily(at: time, state: state, now: now)
    }

    static func cancelDaily() {
        Task { await cancelQueuedNudges() }
    }

    private static func cancelQueuedNudges() async {
        let center = UNUserNotificationCenter.current()
        let queued = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(dailyPrefix) || $0 == dailyIdentifier }
        center.removePendingNotificationRequests(withIdentifiers: queued)
    }

    // MARK: - Loan due

    static func cancelLoanReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(loanPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    /// Re-schedule every borrowed book's due warning.
    ///
    /// Rebuilt wholesale from the shelf each time rather than patched: due dates
    /// get edited and books get returned, and a stale reminder for a book already
    /// back on the shelf is the fastest way to get notifications turned off.
    static func refreshLoanReminders(from state: WireState, now: Date = Date()) async {
        await cancelLoanReminders()
        guard await authorizationStatus() == .authorized else { return }

        let center = UNUserNotificationCenter.current()

        let calendar = Calendar.current
        for book in state.books {
            guard !book.loanDue.isEmpty,
                  let due = ISO8601.date(from: book.loanDue) ?? dayOnly(book.loanDue, calendar),
                  // The day before, at 9am: on the day itself is too late to
                  // get to a library.
                  let fire = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: due)),
                  let at9 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fire),
                  at9 > now
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Due back tomorrow"
            content.body = book.title
            content.sound = .default
            content.userInfo = ["bookID": book.id]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at9),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: loanPrefix + book.id, content: content, trigger: trigger
            ))
        }
    }

    /// `loanDue` is stored as a bare `YYYY-MM-DD`, which the ISO8601 parser the
    /// rest of the app uses — built for full timestamps — will not accept.
    private static func dayOnly(_ raw: String, _ calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
