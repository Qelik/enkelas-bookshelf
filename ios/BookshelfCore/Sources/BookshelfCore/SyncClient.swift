import Foundation

/// The sync Worker's HTTP surface, ported from `apiFetch()` in `src/app.ts`.
///
/// Deliberately thin: it speaks HTTP and turns the interesting status codes into
/// typed cases. It holds no policy — what to do about a 409 is a decision with
/// someone's reading history on the line, and that belongs in `SyncEngine` where
/// it can be surfaced rather than guessed at.
public actor SyncClient {

    public static let defaultBaseURL = URL(string: "https://enkelas-bookshelf-sync.enkela.workers.dev")!

    /// Per-device override, mirroring the web app's `enkelas-sync-api`
    /// localStorage key. Lets a self-hosted Worker — or `wrangler dev` on a
    /// laptop — be pointed at without a rebuild.
    public static func configuredBaseURL(_ defaults: UserDefaults = .standard) -> URL {
        guard let raw = defaults.string(forKey: "enkelas-sync-api"),
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil
        else { return defaultBaseURL }
        return url
    }

    public enum Failure: LocalizedError {
        /// The token is gone or revoked — a password change on another device,
        /// or an account that no longer exists.
        case unauthorized
        /// The server has a different version than the base we sent. Carries the
        /// server's copy so the caller can offer a choice without a second round
        /// trip.
        case conflict(blob: JSONValue, updatedAt: String?)
        /// Over the Worker's blob ceiling. The message is the server's, which
        /// explains what to do about it.
        case tooLarge(String)
        case server(status: Int, message: String?)
        /// This device has no network at all.
        case offline
        /// There is a network, but the sync server didn't answer — it's down, or
        /// the configured address is wrong.
        ///
        /// Kept apart from `.offline` because the two need different actions and
        /// conflating them sends people to check their wifi when the truth is
        /// that the server isn't running. That is exactly what happened: a
        /// `wrangler dev` that wasn't up reported itself as "you're offline".
        case unreachable
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .unauthorized: "Your session expired. Please sign in again."
            case .conflict: "Your bookshelf was changed on another device."
            case .tooLarge(let m): m
            case .server(_, let m): m ?? "The server had a problem. Please try again."
            case .offline: "You're offline. Changes are saved on this device and will sync later."
            case .unreachable: "Can't reach the sync server. Changes are saved on this device."
            case .decoding(let m): "Unexpected response from the server. (\(m))"
            }
        }
    }

    public struct AuthResponse: Sendable {
        public let token: String
        public let user: AuthUser
    }

    public struct RemoteShelf: Sendable {
        public let blob: JSONValue?
        public let updatedAt: String?
    }

    public struct Capabilities: Decodable, Sendable {
        public var clubs: Bool?
        public var recs: Bool?
        public var realtime: Bool?
        public var passwordReset: Bool?
        public var accountDelete: Bool?
        public var moderation: Bool?
    }

    let baseURL: URL
    private let session: URLSession
    /// Read fresh on every request rather than held as actor state.
    ///
    /// It used to be a `var` set through an `async` method, which meant a cold
    /// launch could fire its first request before the token had been handed over
    /// — the request went out unauthenticated, came back 401, and the app
    /// promptly signed the user out on its own. Reading from the token store
    /// per request removes the window instead of narrowing it.
    private let tokenProvider: @Sendable () -> String?

    public init(
        baseURL: URL = SyncClient.defaultBaseURL,
        session: URLSession? = nil,
        tokenProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // A sync that hangs for a minute is worse than one that fails: the
            // shelf is already safe on disk, and a retry costs nothing.
            config.timeoutIntervalForRequest = 20
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Auth

    public func register(email: String, fullName: String, password: String) async throws -> AuthResponse {
        try await authCall("/api/register", ["email": email, "fullName": fullName, "password": password])
    }

    public func login(email: String, password: String) async throws -> AuthResponse {
        try await authCall("/api/login", ["email": email, "password": password])
    }

    public func changePassword(current: String, new: String) async throws -> AuthResponse {
        try await authCall("/api/password/change", ["currentPassword": current, "newPassword": new])
    }

    public func requestPasswordReset(email: String) async throws {
        _ = try await send(method: "POST", path: "/api/password/forgot", body: ["email": email])
    }

    /// Permanently deletes the account and everything on it. The password is
    /// required by the server, not by us: a token lifted off a borrowed laptop
    /// must not be enough to erase somebody's library.
    public func deleteAccount(password: String) async throws {
        _ = try await send(method: "DELETE", path: "/api/account", body: ["password": password])
    }

    private func authCall(_ path: String, _ body: [String: String]) async throws -> AuthResponse {
        let data = try await send(method: "POST", path: path, body: body)
        struct Payload: Decodable {
            var token: String?
            var user: User?
            struct User: Decodable { var id: String?; var email: String?; var fullName: String? }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let token = payload.token, let user = payload.user
        else { throw Failure.decoding("no token in response") }
        return AuthResponse(
            token: token,
            user: AuthUser(id: user.id ?? "", email: user.email ?? "", fullName: user.fullName ?? "")
        )
    }

    // MARK: - Data

    public func fetchShelf() async throws -> RemoteShelf {
        let data = try await send(method: "GET", path: "/api/data", body: nil)
        guard let value = try? JSONValue.parse(data) else { throw Failure.decoding("bad shelf payload") }
        let blob = value["blob"]
        return RemoteShelf(blob: blob.isNull ? nil : blob, updatedAt: value["updatedAt"].stringValue)
    }

    /// Push the shelf.
    ///
    /// `baseUpdatedAt` is the optimistic-concurrency token: the server only
    /// accepts the write if its stored `updatedAt` still matches what this device
    /// last saw. `force` skips that check and is only correct when the user has
    /// explicitly chosen to overwrite.
    @discardableResult
    public func pushShelf(_ state: WireState, baseUpdatedAt: String?, force: Bool = false) async throws -> String? {
        var body: [String: JSONValue] = [
            "blob": try JSONValue.from(state),
            "updatedAt": .string(state.updatedAt),
        ]
        if force {
            body["force"] = .bool(true)
        } else if let baseUpdatedAt {
            body["baseUpdatedAt"] = .string(baseUpdatedAt)
        }
        let data = try await send(method: "PUT", path: "/api/data", jsonBody: try JSONValue.object(body).encoded())
        return (try? JSONValue.parse(data))?["updatedAt"].stringValue
    }

    public func capabilities() async throws -> Capabilities {
        let data = try await send(method: "GET", path: "/api", body: nil)
        return (try? JSONDecoder().decode(Capabilities.self, from: data)) ?? Capabilities()
    }

    // MARK: - Transport

    private func send(method: String, path: String, body: [String: String]?) async throws -> Data {
        var encoded: Data?
        if let body {
            encoded = try JSONValue.object(body.mapValues { JSONValue.string($0) }).encoded()
        }
        return try await send(method: method, path: path, jsonBody: encoded)
    }

    func get(_ path: String) async throws -> Data {
        try await send(method: "GET", path: path, jsonBody: nil)
    }

    func post(_ path: String, _ body: [String: JSONValue]) async throws -> Data {
        try await send(method: "POST", path: path, jsonBody: try JSONValue.object(body).encoded())
    }

    func send(method: String, path: String, jsonBody: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = tokenProvider() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = jsonBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw Failure.offline
        } catch let error as URLError where Self.unreachableCodes.contains(error.code) {
            throw Failure.unreachable
        } catch {
            throw Failure.server(status: 0, message: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            return data
        case 401:
            throw Failure.unauthorized
        case 409:
            // The body carries the server's copy — hand it back rather than
            // making the caller fetch again, which would race another write.
            let value = try? JSONValue.parse(data)
            throw Failure.conflict(blob: value?["blob"] ?? .null, updatedAt: value?["updatedAt"].stringValue)
        case 413:
            throw Failure.tooLarge(Self.message(from: data) ?? "This bookshelf is too large to sync.")
        default:
            throw Failure.server(status: status, message: Self.message(from: data))
        }
    }

    /// The device genuinely has no network.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost,
        .dataNotAllowed, .internationalRoamingOff,
    ]

    /// There is a network, but this particular server didn't answer. A stopped
    /// `wrangler dev`, a typo'd `enkelas-sync-api` override, or a Worker that is
    /// down all land here — and none of them are the user's connection.
    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .timedOut,
        .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted,
    ]

    /// The Worker puts a human-readable sentence in `error` on every failure —
    /// "That password isn't right", "Too many sign-in attempts". Showing that
    /// beats inventing our own copy for a status code.
    private static func message(from data: Data) -> String? {
        (try? JSONValue.parse(data))?["error"].stringValue
    }
}
