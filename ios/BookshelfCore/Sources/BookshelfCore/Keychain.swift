import Foundation
import Security

/// Where the session token lives.
///
/// The web app keeps its token in `localStorage`. The iOS equivalent would be
/// `UserDefaults`, which is a plist inside the app container — included in
/// device backups, readable from a restored backup, and trivially dumped from a
/// jailbroken device. A 30-day bearer token that reads and writes someone's
/// whole library belongs in the Keychain instead.
public struct TokenStore: Sendable {
    public var read: @Sendable () -> String?
    public var write: @Sendable (String) -> Void
    public var delete: @Sendable () -> Void

    public init(
        read: @escaping @Sendable () -> String?,
        write: @escaping @Sendable (String) -> Void,
        delete: @escaping @Sendable () -> Void
    ) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public init(service: String = "com.enkela.bookshelf.sync", account: String = "session-token") {
        let keychain = Keychain(service: service, account: account)
        self.read = { keychain.read() }
        self.write = { keychain.write($0) }
        self.delete = { keychain.delete() }
    }

    /// For tests and previews. Never touches the Keychain, so a test run leaves
    /// nothing behind in the developer's login keychain.
    public static func inMemory() -> TokenStore {
        let box = Box()
        return TokenStore(
            read: { box.value },
            write: { box.value = $0 },
            delete: { box.value = nil }
        )
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
}

private struct Keychain: Sendable {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    func write(_ token: String) {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // AfterFirstUnlock, not WhenUnlocked: a background refresh has to be able
        // to sync while the phone is in a pocket. ThisDeviceOnly so the token is
        // left out of encrypted backups — restoring someone's backup onto a new
        // phone should not hand it a live session; signing in again is cheap.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// The signed-in account, as the server describes it. Never holds a password.
public struct AuthUser: Codable, Sendable, Hashable {
    public var id: String
    public var email: String
    public var fullName: String

    public init(id: String, email: String, fullName: String) {
        self.id = id
        self.email = email
        self.fullName = fullName
    }

    public var firstName: String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }
}
