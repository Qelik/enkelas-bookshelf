import BookshelfCore
import SwiftUI

/// Sign in or create an account.
///
/// The password rules are the server's — it rejects anything under ten
/// characters, on a common-passwords list, or containing your own name or email.
/// Rather than duplicating that logic here and risking the two drifting apart,
/// the field states the minimum and the server's own sentence is shown verbatim
/// when it refuses.
struct AuthView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case signIn = "Sign in", register = "Create account" }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var resetSent = false

    private var canSubmit: Bool {
        guard !busy, email.contains("@"), password.count >= 10 else { return false }
        if mode == .register {
            return !fullName.trimmingCharacters(in: .whitespaces).isEmpty && password == confirmPassword
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .themedPlainRows()
                }

                Section {
                    if mode == .register {
                        TextField("Full name", text: $fullName)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        // newPassword tells the password manager to offer a
                        // generated one; the wrong hint here is why people reuse
                        // passwords.
                        .textContentType(mode == .register ? .newPassword : .password)
                    if mode == .register {
                        SecureField("Confirm password", text: $confirmPassword)
                            .textContentType(.newPassword)
                        if !confirmPassword.isEmpty, password != confirmPassword {
                            Label("Those don't match", systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    if mode == .register {
                        Text("At least 10 characters, and not your name or email address.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if mode == .signIn {
                    Section {
                        Button("Forgot your password?") {
                            Task { await sendReset() }
                        }
                        .disabled(!email.contains("@") || busy)
                        if resetSent {
                            Text("If that email has an account, a reset link is on its way.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Your bookshelf syncs privately to your account. Signing in is optional — without it everything stays on this device.\n\nBy creating an account you agree to the [Terms & Community Rules](https://qelik.github.io/enkelas-bookshelf/terms.html).")
                        .font(.footnote)
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(mode == .signIn ? "Sign in" : "Create") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            switch mode {
            case .signIn:
                try await sync.signIn(email: email, password: password)
            case .register:
                try await sync.register(email: email, fullName: fullName, password: password)
            }
            // Clear before dismissing: SwiftUI can keep this view alive behind
            // the sheet animation, and a password has no business sitting in a
            // detached view's state.
            password = ""
            confirmPassword = ""
            dismiss()
        } catch {
            // The Worker's own wording ("That password isn't right", "Too many
            // sign-in attempts") is more useful than anything invented here.
            errorMessage = error.localizedDescription
        }
    }

    private func sendReset() async {
        busy = true
        defer { busy = false }
        try? await sync.requestPasswordReset(email: email)
        // Always the same answer, whether or not the address has an account —
        // otherwise this becomes a free membership lookup.
        resetSent = true
    }
}
