import BookshelfCore
import SwiftUI

/// The account section of Settings: who you're signed in as, whether sync is
/// working, and the three destructive things — sign out, change password,
/// delete account.
struct AccountSection: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(BookshelfStore.self) private var store

    @Binding var showingAuth: Bool
    @State private var showingConflictLog = false
    @State private var showingPasswordChange = false
    @State private var showingDelete = false
    @State private var signOutWarning: String?
    @State private var busy = false

    var body: some View {
        Section {
            if let account = sync.account {
                LabeledContent("Signed in as", value: account.email)
                    .lineLimit(1)
                syncStatusRow

                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { busy = true; await sync.pull(); busy = false }
                }
                .disabled(busy)

                if !sync.conflictLog.isEmpty {
                    Button("Sync conflicts (\(sync.conflictLog.count))", systemImage: "arrow.triangle.branch") {
                        showingConflictLog = true
                    }
                }

                Button("Change password", systemImage: "key") { showingPasswordChange = true }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await signOut() }
                }
                Button("Delete account", systemImage: "trash", role: .destructive) { showingDelete = true }
            } else {
                Button("Sign in to sync", systemImage: "person.crop.circle") { showingAuth = true }
                if case .needsLogin = sync.status {
                    Label("Your session expired — sign in again to resume syncing. Your books are safe on this device.",
                          systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            if sync.account == nil {
                Text("Optional. Without an account everything stays on this device.")
            }
        }
        .sheet(isPresented: $showingConflictLog) { ConflictLogView() }
        .sheet(isPresented: $showingPasswordChange) { ChangePasswordView() }
        .sheet(isPresented: $showingDelete) { DeleteAccountView() }
        .alert("Signed out", isPresented: .constant(signOutWarning != nil), presenting: signOutWarning) { _ in
            Button("OK") { signOutWarning = nil }
        } message: { warning in
            Text(warning)
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        LabeledContent("Sync") {
            switch sync.status {
            case .syncing:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") }
            case .idle:
                if let last = sync.lastSyncedAt {
                    Text(last.formatted(.relative(presentation: .named)))
                } else {
                    Text("Up to date")
                }
            case .offline:
                Label("Offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
            case .needsLogin:
                Label("Sign in again", systemImage: "key").foregroundStyle(.orange)
            case .error(let message):
                Text(message).foregroundStyle(.orange).font(.footnote).multilineTextAlignment(.trailing)
            case .signedOut:
                Text("Off")
            }
        }
    }

    private func signOut() async {
        busy = true
        defer { busy = false }
        // Signing out clears this device, so anything unsynced has to go up
        // first. If it can't, say so rather than quietly deleting a day's
        // reading in the name of privacy.
        let pushed = await sync.signOut()
        if !pushed {
            signOutWarning = "Some recent changes couldn't be uploaded before signing out, so they only existed on this device and are now gone. Next time, sync before signing out."
        }
    }
}

/// The conflict history — every time two devices disagreed and which copy won.
struct ConflictLogView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if sync.conflictLog.isEmpty {
                    ContentUnavailableView("No conflicts", systemImage: "checkmark.circle",
                                           description: Text("Every change has merged cleanly."))
                } else {
                    ForEach(sync.conflictLog) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.choice.prefix(1).uppercased() + entry.choice.dropFirst())
                                .font(.subheadline)
                            Text("during \(entry.origin) · \(entry.books) books after")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let at = ISO8601.date(from: entry.at) {
                                Text(at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Sync conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ChangePasswordView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current)
                        .textContentType(.password)
                    SecureField("New password", text: $new)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    // The server revokes every other session on a password
                    // change — that is the point of changing it after losing a
                    // device, and users should know it will happen.
                    Text("At least 10 characters. Changing your password signs out your other devices.")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Change") { Task { await submit() } }
                            .disabled(current.isEmpty || new.count < 10 || new != confirm)
                    }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await sync.changePassword(current: current, new: new)
            current = ""; new = ""; confirm = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Deleting an account. Required by App Store guideline 5.1.1(v), and the
/// friction here is deliberate: it is irreversible and total.
struct DeleteAccountView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmed = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This deletes your account and everything on it — your bookshelf, your reading history, your recommendations and your club comments. It cannot be undone.")
                        .font(.callout)
                    // Export first, not as an afterthought: this is the last
                    // moment the data exists.
                    Label("Export a backup first if you want to keep your reading history.",
                          systemImage: "square.and.arrow.up")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Books", value: "\(store.state.books.count)")
                    LabeledContent("Sessions", value: "\(store.state.books.reduce(0) { $0 + $1.logs.count })")
                }

                Section {
                    SecureField("Your password", text: $password)
                        .textContentType(.password)
                    Toggle("I understand this can't be undone", isOn: $confirmed)
                } footer: {
                    Text("Your password is required so that someone with your unlocked phone can't delete your account.")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.footnote)
                }

                Section {
                    Button("Delete my account permanently", role: .destructive) {
                        Task { await submit() }
                    }
                    .disabled(!confirmed || password.isEmpty || busy)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if busy { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await sync.deleteAccount(password: password)
            password = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The divergence prompt. Shown when both this device and the account hold
/// changes the other hasn't seen — the one case where guessing loses data.
struct ConflictResolutionView: View {
    @Environment(SyncEngine.self) private var sync
    let conflict: SyncEngine.Conflict

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(conflict.origin == .signIn
                         ? "This account already has a bookshelf, and this device has one too."
                         : "Your bookshelf was changed on another device since this one last synced.")
                    Text("They've both changed, so one has to win. Nothing is deleted until you choose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await sync.resolve(useServer: false) }
                    } label: {
                        choice(
                            title: "Keep this device's copy",
                            detail: "\(conflict.localBookCount) book\(conflict.localBookCount == 1 ? "" : "s")",
                            note: "Uploads it, replacing the account's version.",
                            symbol: "iphone"
                        )
                    }

                    Button {
                        Task { await sync.resolve(useServer: true) }
                    } label: {
                        choice(
                            title: "Keep the account's copy",
                            detail: "\(conflict.serverBookCount) book\(conflict.serverBookCount == 1 ? "" : "s")"
                                + (conflict.serverUpdatedAt.flatMap(ISO8601.date(from:)).map { ", changed \($0.formatted(.relative(presentation: .named)))" } ?? ""),
                            note: "Downloads it, replacing what's on this device.",
                            symbol: "icloud"
                        )
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Either way, the choice is recorded in Settings → Sync conflicts.")
                }
            }
            .navigationTitle("Two versions")
            .navigationBarTitleDisplayMode(.inline)
        }
        // No cancel: leaving it unresolved means sync stays stuck and the next
        // push 409s again. Choosing is the only way forward.
        .interactiveDismissDisabled()
    }

    private func choice(title: String, detail: String, note: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
