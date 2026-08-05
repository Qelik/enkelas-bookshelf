import Foundation
import Observation

/// Sync policy, ported from `pushData` / `pullData` / `adoptServer` in `src/app.ts`.
///
/// The rule worth stating plainly, because it is the whole design:
///
/// - A **pull** resolves itself. Whichever side has the newer `updatedAt` wins,
///   because one of them is simply behind.
/// - A **409 on push** does *not*. It means both devices edited from the same
///   base, so neither copy contains the other's changes and picking silently
///   throws someone's reading away. The user chooses, and the choice is recorded
///   in the conflict log so "where did that session go?" has an answer.
///
/// Everything is offline-first. The shelf on disk is the source of truth; the
/// server is a copy that catches up. A failed sync is never allowed to lose a
/// local change.
@Observable
@MainActor
public final class SyncEngine {

    public enum Status: Equatable, Sendable {
        case signedOut
        case idle
        case syncing
        case offline
        case needsLogin
        case error(String)
    }

    /// A divergence waiting on the user. Held rather than resolved so the UI can
    /// show what each side contains before anything is overwritten.
    public struct Conflict: Identifiable, Sendable {
        public let id = UUID()
        public enum Origin: String, Sendable { case push = "sync push", signIn = "sign-in" }
        public let origin: Origin
        public let serverState: WireState
        public let serverUpdatedAt: String?
        public let localBookCount: Int
        public var serverBookCount: Int { serverState.books.count }
    }

    public struct ConflictEntry: Codable, Identifiable, Sendable {
        public var id = UUID()
        public var at: String
        public var origin: String
        public var choice: String
        public var books: Int
    }

    // MARK: - Observable state

    public private(set) var status: Status = .signedOut
    public private(set) var account: AuthUser?
    public private(set) var lastSyncedAt: Date?
    public private(set) var conflictLog: [ConflictEntry] = []
    /// Non-nil while a divergence is waiting on the user. The UI presents it and
    /// calls `resolve(useServer:)`.
    public var pendingConflict: Conflict?

    public var isSignedIn: Bool { account != nil }

    /// "Çelik's Bookshelf" for whoever is signed in, falling back to the app's
    /// own name when nobody is. Ported from `renderTitle()` in `src/app.ts` so a
    /// household sharing the app sees the same thing on the phone as in the
    /// browser.
    ///
    /// This is the title *inside* the app. iOS gives an app no way to rename its
    /// own home-screen icon at runtime — `CFBundleDisplayName` is fixed at build
    /// time — so the icon stays "Bookshelf" whoever is signed in.
    public var displayTitle: String {
        let first = (account?.fullName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        return first.isEmpty ? "Enkela's Bookshelf" : "\(first)'s Bookshelf"
    }

    // MARK: - Dependencies

    private let client: SyncClient
    private let store: BookshelfStore
    private let tokens: TokenStore
    private let defaults: UserDefaults
    private let normalizer: Normalizer

    private var pushTask: Task<Void, Never>?
    private var lastPushAt: Date?
    private var lastPullAt: Date?

    /// The free Workers KV tier allows roughly a thousand writes a day. Without
    /// coalescing, a reading session logged every minute would spend the whole
    /// budget before lunch and take everyone's sync down with it.
    private let pushInterval: TimeInterval = 120
    private let pullInterval: TimeInterval = 60

    public convenience init(store: BookshelfStore, defaults: UserDefaults = .standard) {
        let tokens = TokenStore()
        self.init(
            store: store,
            // The client reads the token straight from the store on each request,
            // so there is no window in which it is unset.
            client: SyncClient(baseURL: SyncClient.configuredBaseURL(defaults), tokenProvider: tokens.read),
            tokens: tokens,
            defaults: defaults
        )
    }

    public init(
        store: BookshelfStore,
        client: SyncClient = SyncClient(),
        tokens: TokenStore = TokenStore(),
        defaults: UserDefaults = .standard,
        normalizer: Normalizer = Normalizer()
    ) {
        self.store = store
        self.client = client
        self.tokens = tokens
        self.defaults = defaults
        self.normalizer = normalizer

        self.account = defaults.data(forKey: Keys.account).flatMap { try? JSONDecoder().decode(AuthUser.self, from: $0) }
        self.conflictLog = defaults.data(forKey: Keys.conflictLog).flatMap { try? JSONDecoder().decode([ConflictEntry].self, from: $0) } ?? []
        self.lastSyncedAt = defaults.object(forKey: Keys.lastSync) as? Date

        // The token is the credential; the account record is just a display name.
        // If the Keychain has no token we are signed out no matter what the
        // defaults say — that is the state after a restore onto a new device.
        if tokens.read() != nil, account != nil {
            status = .idle
        } else {
            account = nil
            status = .signedOut
        }
    }

    // MARK: - Sign in / out

    public func signIn(email: String, password: String) async throws {
        let response = try await client.login(email: email, password: password)
        try await adoptSession(response, mode: .signIn)
    }

    public func register(email: String, fullName: String, password: String) async throws {
        let response = try await client.register(email: email, fullName: fullName, password: password)
        try await adoptSession(response, mode: .register)
    }

    private enum SignInMode { case signIn, register }

    private func adoptSession(_ response: SyncClient.AuthResponse, mode: SignInMode) async throws {
        tokens.write(response.token)
        account = response.user
        defaults.set(try? JSONEncoder().encode(response.user), forKey: Keys.account)
        status = .idle
        await reconcileAfterSignIn(mode: mode)
    }

    /// Ported from `afterSignIn()`. Four cases, and the fourth is the one that
    /// matters: a device with books signing into an account that also has books
    /// is a genuine conflict, not something to resolve by timestamp — neither
    /// copy is "behind", they are just different.
    private func reconcileAfterSignIn(mode: SignInMode) async {
        do {
            let remote = try await client.fetchShelf()
            let localHasBooks = !store.state.books.isEmpty

            switch (mode, remote.blob, localHasBooks) {
            case (.register, _, _):
                // A brand-new account has nothing to lose; this device's shelf
                // becomes the account's.
                try await push(force: true)
            case (_, .some(let blob), false):
                adopt(blob: blob, updatedAt: remote.updatedAt)
            case (_, .some(let blob), true):
                pendingConflict = Conflict(
                    origin: .signIn,
                    serverState: normalizer.normalize(blob),
                    serverUpdatedAt: remote.updatedAt,
                    localBookCount: store.state.books.count
                )
            case (_, .none, _):
                try await push(force: true)
            }
        } catch {
            // Offline at sign-in is fine — the next change or foreground pulls.
            apply(error)
        }
    }

    /// Signing out is a privacy boundary: this device must not keep the previous
    /// account's library sitting on it. Anything unsynced is pushed first, and if
    /// that push fails the caller is told, so "sign out" can never be the thing
    /// that loses a day's reading.
    @discardableResult
    public func signOut(clearLocalShelf: Bool = true) async -> Bool {
        var pushed = true
        if isSignedIn, isDirty {
            pushed = (try? await push(force: false)) ?? false
        }
        tokens.delete()
        account = nil
        defaults.removeObject(forKey: Keys.account)
        defaults.removeObject(forKey: Keys.syncBase)
        status = .signedOut
        if clearLocalShelf {
            store.replace(with: normalizer.defaultState())
        }
        return pushed
    }

    /// The token stopped working — a password change elsewhere, or a deleted
    /// account. The local shelf is deliberately left alone: it is still the
    /// user's data, and wiping it because a session expired would be theft.
    /// Drop a session the server has rejected.
    ///
    /// Public because community requests hit 401 too, and until this runs the app
    /// still believes it is signed in — so it renders empty lists instead of a
    /// sign-in prompt, and the user is told they have no clubs when the truth is
    /// that their token is dead.
    public func sessionExpired() { handleAuthExpired() }

    private func handleAuthExpired() {
        tokens.delete()
        account = nil
        defaults.removeObject(forKey: Keys.account)
        defaults.removeObject(forKey: Keys.syncBase)
        status = .needsLogin
    }

    public func changePassword(current: String, new: String) async throws {
        let response = try await client.changePassword(current: current, new: new)
        // The server revokes every other session and issues a fresh token; without
        // storing it this device would sign itself out on the next request.
        tokens.write(response.token)
        account = response.user
        defaults.set(try? JSONEncoder().encode(response.user), forKey: Keys.account)
    }

    public func requestPasswordReset(email: String) async throws {
        try await client.requestPasswordReset(email: email)
    }

    /// Delete the account on the server, then leave this device blank.
    public func deleteAccount(password: String) async throws {
        try await client.deleteAccount(password: password)
        tokens.delete()
        account = nil
        defaults.removeObject(forKey: Keys.account)
        defaults.removeObject(forKey: Keys.syncBase)
        defaults.removeObject(forKey: Keys.lastSync)
        status = .signedOut
        store.replace(with: normalizer.defaultState())
    }

    // MARK: - Push / pull

    /// True when this device holds changes the server hasn't seen.
    public var isDirty: Bool {
        store.state.updatedAt > (syncBase ?? "")
    }

    /// Debounced push, called after every change. Coalesced so a burst of edits
    /// costs one cloud write rather than one per keystroke.
    public func schedulePush() {
        guard isSignedIn else { return }
        pushTask?.cancel()
        let elapsed = lastPushAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = elapsed >= pushInterval ? 1.2 : (pushInterval - elapsed)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self?.push(force: false)
        }
    }

    /// Flush anything pending. Call when the app backgrounds — a debounced push
    /// that hasn't fired yet dies with the process.
    public func flush() async {
        pushTask?.cancel()
        guard isSignedIn, isDirty else { return }
        try? await push(force: false)
    }

    @discardableResult
    public func push(force: Bool) async throws -> Bool {
        guard isSignedIn else { return false }
        status = .syncing
        lastPushAt = Date()
        do {
            let updatedAt = try await client.pushShelf(store.state, baseUpdatedAt: syncBase, force: force)
            syncBase = updatedAt
            markSynced()
            return true
        } catch SyncClient.Failure.unauthorized {
            handleAuthExpired()
            return false
        } catch SyncClient.Failure.conflict(let blob, let updatedAt) {
            // Both sides moved from the same base. Ask — do not guess.
            pendingConflict = Conflict(
                origin: .push,
                serverState: normalizer.normalize(blob),
                serverUpdatedAt: updatedAt,
                localBookCount: store.state.books.count
            )
            status = .idle
            return false
        } catch {
            apply(error)
            throw error
        }
    }

    public func pull() async {
        guard isSignedIn else { return }
        status = .syncing
        lastPullAt = Date()
        do {
            let remote = try await client.fetchShelf()
            guard let blob = remote.blob else {
                // Account exists but has no shelf yet — this device seeds it.
                if !store.state.books.isEmpty { try await push(force: true) } else { markSynced() }
                return
            }
            let serverUpdatedAt = remote.updatedAt ?? ""
            let localUpdatedAt = store.state.updatedAt

            // A newer server copy is only safe to take when this device has
            // nothing of its own outstanding. If it does, both sides have moved
            // and adopting would silently discard local reading — the same
            // divergence a 409 catches on the way out, caught here on the way in.
            //
            // The web app resolves this case by timestamp, which is survivable
            // there because its prompt is a blocking `confirm()`. A sheet can be
            // dismissed by the app being killed, so the check has to be here.
            if serverUpdatedAt > localUpdatedAt, isDirty, syncBase != serverUpdatedAt {
                pendingConflict = Conflict(
                    origin: .push,
                    serverState: normalizer.normalize(blob),
                    serverUpdatedAt: remote.updatedAt,
                    localBookCount: store.state.books.count
                )
                status = .idle
            } else if serverUpdatedAt > localUpdatedAt {
                adopt(blob: blob, updatedAt: remote.updatedAt)
                markSynced()
            } else if localUpdatedAt > serverUpdatedAt {
                // We're ahead — push instead. Not a conflict: the server simply
                // hasn't caught up.
                try await push(force: false)
            } else {
                syncBase = serverUpdatedAt
                markSynced()
            }
        } catch SyncClient.Failure.unauthorized {
            handleAuthExpired()
        } catch {
            apply(error)
        }
    }

    /// Pull, but not more often than once a minute.
    public func pullIfStale() async {
        guard isSignedIn else { return }
        if let last = lastPullAt, Date().timeIntervalSince(last) < pullInterval { return }
        await pull()
    }

    // MARK: - Conflict resolution

    /// The user has chosen. `useServer` takes the other device's copy; otherwise
    /// this device's copy overwrites it.
    public func resolve(useServer: Bool) async {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        record(conflict, useServer: useServer)

        if useServer {
            adopt(state: conflict.serverState, updatedAt: conflict.serverUpdatedAt)
            markSynced()
        } else {
            // Force, because the whole point is to overwrite what the server has.
            try? await push(force: true)
        }
    }

    private func record(_ conflict: Conflict, useServer: Bool) {
        let entry = ConflictEntry(
            at: ISO8601.string(from: Date()),
            origin: conflict.origin.rawValue,
            choice: useServer ? "kept the other device's copy" : "kept this device's copy",
            books: useServer ? conflict.serverBookCount : conflict.localBookCount
        )
        // Newest first, capped — a log nobody can read is not a log.
        conflictLog = Array(([entry] + conflictLog).prefix(20))
        defaults.set(try? JSONEncoder().encode(conflictLog), forKey: Keys.conflictLog)
    }

    // MARK: - Adoption

    private func adopt(blob: JSONValue, updatedAt: String?) {
        adopt(state: normalizer.normalize(blob), updatedAt: updatedAt)
    }

    private func adopt(state incoming: WireState, updatedAt: String?) {
        var next = incoming
        // Keep the server's timestamp rather than stamping now: `updatedAt` is
        // the concurrency token, and inventing a newer one here would make this
        // device look ahead of the server it just copied.
        if let updatedAt { next.updatedAt = updatedAt }
        store.adopt(next)
        syncBase = updatedAt
    }

    // MARK: - Status and storage

    private func apply(_ error: Error) {
        if case SyncClient.Failure.offline = error {
            status = .offline
        } else {
            status = .error(error.localizedDescription)
        }
    }

    private func markSynced() {
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Keys.lastSync)
        status = .idle
    }

    /// The server's `updatedAt` as of the last successful exchange — the base for
    /// the next optimistic write.
    private var syncBase: String? {
        get { defaults.string(forKey: Keys.syncBase) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.syncBase) }
            else { defaults.removeObject(forKey: Keys.syncBase) }
        }
    }

    private enum Keys {
        static let account = "enkelas-sync-account"
        static let syncBase = "enkelas-sync-base"
        static let lastSync = "enkelas-sync-last"
        static let conflictLog = "enkelas-sync-conflicts"
    }
}
