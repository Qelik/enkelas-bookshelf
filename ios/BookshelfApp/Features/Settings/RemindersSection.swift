import BookshelfCore
import SwiftUI
import UserNotifications

/// Reminder settings.
///
/// Permission is asked for here, when the user flips the switch — not at launch.
/// A notification prompt with no context gets declined, and iOS only lets an app
/// ask once.
struct RemindersSection: View {
    @Environment(BookshelfStore.self) private var store

    /// Stored locally, not in the shelf: a reminder time is about this phone, and
    /// syncing it would have someone's iPad buzz at 7am on their behalf.
    @AppStorage("daily-reminder-on") private var dailyOn = false
    @AppStorage("daily-reminder-time") private var dailySeconds: Double = 20 * 3600
    @AppStorage("loan-reminders-on") private var loanOn = false

    @State private var denied = false

    private var dailyTime: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(dailySeconds)
    }

    var body: some View {
        Section {
            Toggle("Daily reading reminder", isOn: Binding(
                get: { dailyOn },
                set: { on in Task { await setDaily(on) } }
            ))
            if dailyOn {
                DatePicker(
                    "At",
                    selection: Binding(
                        get: { dailyTime },
                        set: { newValue in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            dailySeconds = Double((parts.hour ?? 20) * 3600 + (parts.minute ?? 0) * 60)
                            Task { await Reminders.scheduleDaily(at: newValue) }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }

            Toggle("Library book due dates", isOn: Binding(
                get: { loanOn },
                set: { on in Task { await setLoan(on) } }
            ))
        } header: {
            Text("Reminders")
        } footer: {
            if denied {
                Text("Notifications are off for Bookshelf. Turn them on in Settings › Notifications.")
                    .foregroundStyle(.orange)
            } else {
                Text("A daily nudge, and a warning the day before a borrowed book is due back.")
            }
        }
        .task {
            // Permission can be revoked in Settings while the app is closed, so
            // a switch left on would silently promise notifications that never
            // arrive.
            let status = await Reminders.authorizationStatus()
            denied = status == .denied
            if status != .authorized, dailyOn || loanOn {
                dailyOn = false
                loanOn = false
                Reminders.cancelDaily()
            }
        }
    }

    private func setDaily(_ on: Bool) async {
        guard on else {
            dailyOn = false
            Reminders.cancelDaily()
            return
        }
        guard await ensureAuthorized() else { return }
        dailyOn = true
        await Reminders.scheduleDaily(at: dailyTime)
    }

    private func setLoan(_ on: Bool) async {
        guard on else {
            loanOn = false
            await Reminders.cancelLoanReminders()
            return
        }
        guard await ensureAuthorized() else { return }
        loanOn = true
        await Reminders.refreshLoanReminders(from: store.state)
    }

    /// Returns false — leaving the switch off — when permission isn't granted,
    /// so the UI never claims a reminder is set when it isn't.
    private func ensureAuthorized() async -> Bool {
        switch await Reminders.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = await Reminders.requestAuthorization()
            denied = !granted
            return granted
        default:
            denied = true
            return false
        }
    }
}
