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

    static let dailyIdentifier = "daily-reading"
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

    /// Schedule the daily reminder at `time`'s hour and minute.
    ///
    /// One repeating request rather than one per day: iOS caps an app at 64
    /// pending notifications, and a rolling schedule would spend them all and
    /// then quietly stop.
    static func scheduleDaily(at time: Date, calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "Time to read"
        content.body = "A few pages keeps the streak going."
        content.sound = .default

        var when = DateComponents()
        when.hour = calendar.component(.hour, from: time)
        when.minute = calendar.component(.minute, from: time)

        try? await center.add(UNNotificationRequest(
            identifier: dailyIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        ))
    }

    static func cancelDaily() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [dailyIdentifier])
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
