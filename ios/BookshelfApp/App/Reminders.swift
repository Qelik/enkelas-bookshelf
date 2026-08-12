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
    /// A book *you* lent out, waiting to come back. Its own prefix so cancelling
    /// one kind can't sweep away the other.
    static let lentPrefix = "lent-due-"

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
            .filter { $0.hasPrefix(loanPrefix) || $0.hasPrefix(lentPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    /// Re-arm after a loan changes, if these reminders are switched on.
    ///
    /// Without this the only refresh was on scene activation, so a date set just
    /// now scheduled nothing until the app had been backgrounded and reopened —
    /// for a reminder feature, indistinguishable from not working.
    static func loansChanged(state: WireState) {
        guard UserDefaults.standard.bool(forKey: "loan-reminders-on") else { return }
        Task { await refreshLoanReminders(from: state) }
    }

    /// Re-schedule the due warnings: books you borrowed, and books you lent out.
    ///
    /// Rebuilt wholesale from the shelf each time rather than patched: due dates
    /// get edited and books get returned, and a stale reminder for a book already
    /// back on the shelf is the fastest way to get notifications turned off.
    static func refreshLoanReminders(from state: WireState, now: Date = Date()) async {
        await cancelLoanReminders()
        guard await authorizationStatus() == .authorized else { return }

        let calendar = Calendar.current
        for book in state.books {
            // Borrowed: warn the day before, because the day itself is too late to
            // get to a library.
            if let due = ISO8601.date(from: book.loanDue) ?? dayOnly(book.loanDue, calendar),
               !book.loanDue.isEmpty {
                await schedule(
                    identifier: loanPrefix + book.id,
                    title: "Due back tomorrow",
                    body: book.title,
                    bookID: book.id,
                    on: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: due)),
                    calendar: calendar, now: now
                )
            }

            // Lent out: nudge on the day you asked for it back. There's no library
            // counter to beat, and "today" is when you'd actually send the message.
            if let due = book.lentDueDate, book.isLentOut {
                await schedule(
                    identifier: lentPrefix + book.id,
                    title: "Ask \(book.lentTo) for your book back",
                    body: book.title,
                    bookID: book.id,
                    on: calendar.startOfDay(for: due),
                    calendar: calendar, now: now
                )
            }
        }
    }

    /// One nudge at 9am on `day`, if that's still in the future.
    private static func schedule(
        identifier: String,
        title: String,
        body: String,
        bookID: String,
        on day: Date?,
        calendar: Calendar,
        now: Date
    ) async {
        guard let day,
              let at9 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
              at9 > now
        else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["bookID": bookID]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at9),
            repeats: false
        )
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    /// `loanDue` is stored as a bare `YYYY-MM-DD`, which the ISO8601 parser the
    /// rest of the app uses — built for full timestamps — will not accept.
    private static func dayOnly(_ raw: String, _ calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
