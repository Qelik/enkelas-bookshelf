import Foundation
import Observation

/// The community board and reading clubs.
///
/// Everything social lives behind an account, and everything moderation-related
/// is enforced on the server — the spoiler gate, the block filter and the
/// auto-hide threshold are all server-side, so no client bug can leak a spoiler
/// or resurrect blocked content. This type is the UI's view of that.
@Observable
@MainActor
public final class CommunityEngine {

    public private(set) var recommendations: [Recommendation] = []
    public private(set) var clubs: [Club] = []
    public private(set) var blockedUIDs: Set<String> = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// True when the board returned a full page — the client should say it is
    /// showing a page rather than implying the board is this small.
    public private(set) var boardIsCapped = false

    private let client: SyncClient
    private let sync: SyncEngine

    /// The last board this device saw.
    ///
    /// The board is public, re-fetchable and slow to change, and it was showing a
    /// spinner on every cold launch while a network round-trip finished. Cached, it
    /// is on screen in the first frame and refreshed behind the reader.
    ///
    /// Scoped to the account: `mine` and `myVote` are per-reader, so replaying one
    /// person's cached board for another would show the wrong thumbs.
    private struct CachedBoard: Codable, Sendable {
        var uid: String?
        var recs: [Recommendation]
        var capped: Bool
    }

    private let boardCache = DiskCache<CachedBoard>(filename: "community-board.json")

    public init(client: SyncClient, sync: SyncEngine) {
        self.client = client
        self.sync = sync
        if let cached = boardCache.read()?.value, cached.uid == sync.account?.id {
            recommendations = cached.recs
            boardIsCapped = cached.capped
        }
    }

    public var isSignedIn: Bool { sync.isSignedIn }
    public var displayName: String { sync.account?.fullName ?? "Reader" }
    public var myUID: String? { sync.account?.id }

    // MARK: - Board

    public func loadBoard() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.recommendations()
            // Filtered again here even though the server already does it: a
            // block should feel instant, and the next refresh shouldn't briefly
            // show what the user just blocked.
            recommendations = result.recs.filter { rec in
                guard let author = rec.created_by else { return true }
                return !blockedUIDs.contains(author)
            }
            boardIsCapped = result.capped
            if isSignedIn { await loadBlocks() }
            // Cached after the block filter, so the next launch doesn't flash
            // something the reader has already blocked.
            boardCache.write(CachedBoard(
                uid: sync.account?.id, recs: recommendations, capped: boardIsCapped
            ))
        } catch {
            record(error)
        }
    }

    /// Surface a failure, and hand a rejected session back to `SyncEngine`.
    ///
    /// Without the 401 branch the app keeps believing it is signed in, so every
    /// list comes back empty and reads as "you have nothing" rather than "your
    /// session is dead" — the difference between a puzzle and an instruction.
    private func record(_ error: Error) {
        if case SyncClient.Failure.unauthorized = error {
            sync.sessionExpired()
            clubs = []
        }
        errorMessage = error.localizedDescription
    }

    private func loadBlocks() async {
        guard let list = try? await client.blockedUsers() else { return }
        blockedUIDs = Set(list)
        recommendations.removeAll { rec in
            rec.created_by.map { blockedUIDs.contains($0) } ?? false
        }
    }

    /// Books already finished are hidden by default — a recommendation for
    /// something you've read is noise on a board meant to suggest what's next.
    public func visibleRecommendations(hidingRead: Bool, shelf: WireState, category: String?) -> [Recommendation] {
        var out = recommendations
        if let category, !category.isEmpty {
            out = out.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
        }
        if hidingRead {
            let read = Self.readMatchers(shelf)
            out = out.filter { !Self.hasRead($0, read) }
        }
        return out.sorted { $0.score == $1.score ? ($0.created_at ?? "") > ($1.created_at ?? "") : $0.score > $1.score }
    }

    public var categories: [String] {
        Array(Set(recommendations.map(\.category))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func recommend(title: String, author: String, category: String, note: String, isbn: String, coverUrl: String) async -> Bool {
        do {
            _ = try await client.recommend(
                title: title, author: author, category: category,
                note: note, isbn: isbn, coverUrl: coverUrl, displayName: displayName
            )
            await loadBoard()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Returns false when the vote didn't land, so the caller can say so. A vote
    /// that silently does nothing is indistinguishable from a broken button.
    @discardableResult
    public func vote(_ rec: Recommendation, _ value: Int) async -> Bool {
        do {
            let now = try await client.vote(recID: rec.id, vote: value)
            guard let i = recommendations.firstIndex(where: { $0.id == rec.id }) else { return true }
            // Adjust locally rather than refetching the whole board: a vote
            // should feel immediate, and the tallies are simple enough to keep
            // in step.
            let was = recommendations[i].myVote ?? 0
            var up = recommendations[i].up ?? 0
            var down = recommendations[i].down ?? 0
            if was == 1 { up -= 1 }
            if was == -1 { down -= 1 }
            if now == 1 { up += 1 }
            if now == -1 { down += 1 }
            recommendations[i].up = max(0, up)
            recommendations[i].down = max(0, down)
            recommendations[i].myVote = now
            return true
        } catch {
            record(error)
            return false
        }
    }

    public func deleteRecommendation(_ rec: Recommendation) async {
        do {
            try await client.deleteRecommendation(id: rec.id)
            recommendations.removeAll { $0.id == rec.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Moderation

    /// Returns true when this report pushed the item over the auto-hide
    /// threshold, so the UI can say it's already gone.
    public func report(_ rec: Recommendation, reason: ReportReason, detail: String) async -> Bool {
        do {
            let hidden = try await client.report(recID: rec.id, reason: reason, detail: detail)
            if hidden { recommendations.removeAll { $0.id == rec.id } }
            return hidden
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func report(clubID: String, comment: ClubComment, reason: ReportReason, detail: String) async -> Bool {
        (try? await client.report(clubID: clubID, commentID: comment.id, reason: reason, detail: detail)) ?? false
    }

    /// Blocking is one-directional and silent. Nothing they posted is deleted —
    /// it just stops being sent to this reader.
    public func block(uid: String) async {
        guard uid != myUID else { return }
        do {
            try await client.block(uid: uid)
            blockedUIDs.insert(uid)
            recommendations.removeAll { $0.created_by == uid }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func unblock(uid: String) async {
        do {
            try await client.unblock(uid: uid)
            blockedUIDs.remove(uid)
            await loadBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Clubs

    public func loadClubs() async {
        guard isSignedIn else { clubs = []; return }
        errorMessage = nil
        do { clubs = try await client.clubs() }
        catch { record(error) }
    }

    public func createClub(title: String, author: String, totalPages: Int?) async -> String? {
        do {
            let result = try await client.createClub(
                title: title, author: author, totalPages: totalPages, displayName: displayName
            )
            await loadClubs()
            return result.clubID
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func joinClub(code: String) async -> String? {
        do {
            let id = try await client.joinClub(code: code, displayName: displayName)
            await loadClubs()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func detail(clubID: String) async throws -> ClubDetail {
        try await client.clubDetail(id: clubID)
    }

    public func post(clubID: String, body: String, atPercent: Int) async throws {
        try await client.postComment(clubID: clubID, body: body, atPercent: atPercent)
    }

    public func setProgress(clubID: String, percent: Int) async throws {
        try await client.setProgress(clubID: clubID, percent: percent)
    }

    public func react(clubID: String, commentID: String, emoji: String) async {
        _ = try? await client.react(clubID: clubID, commentID: commentID, emoji: emoji)
    }

    public func leave(clubID: String) async {
        try? await client.leaveClub(id: clubID)
        await loadClubs()
    }

    public func liveUpdates(clubID: String) -> ClubSocket {
        ClubSocket(client: client, clubID: clubID)
    }

    // MARK: - "Have I read this?"

    struct ReadMatchers {
        var titles: Set<String>
        var pairs: Set<String>
        var isbns: Set<String>
    }

    static func readMatchers(_ shelf: WireState) -> ReadMatchers {
        var titles: Set<String> = []
        var pairs: Set<String> = []
        var isbns: Set<String> = []
        for book in shelf.books where book.status == .finished || book.status == .dnf {
            let title = normalise(book.title)
            if !title.isEmpty {
                titles.insert(title)
                pairs.insert(title + "|" + normalise(book.author))
            }
            let digits = book.isbn.filter(\.isNumber)
            if !digits.isEmpty { isbns.insert(digits) }
        }
        return ReadMatchers(titles: titles, pairs: pairs, isbns: isbns)
    }

    static func hasRead(_ rec: Recommendation, _ m: ReadMatchers) -> Bool {
        let digits = (rec.book_isbn ?? "").filter(\.isNumber)
        if !digits.isEmpty, m.isbns.contains(digits) { return true }
        let title = normalise(rec.book_title)
        guard !title.isEmpty else { return false }
        if m.pairs.contains(title + "|" + normalise(rec.author)) { return true }
        // Title alone only counts when the recommendation names no author —
        // otherwise two different books sharing a title would hide each other.
        return rec.author.isEmpty && m.titles.contains(title)
    }

    private static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Live updates for one club.
///
/// The socket carries no book content — only a nudge saying something changed,
/// which the client answers by re-fetching through the spoiler gate. That is
/// deliberate: if comment text travelled over the socket, the gate would have to
/// be enforced twice, and the second one would eventually be wrong.
@Observable
@MainActor
public final class ClubSocket {
    public private(set) var isConnected = false
    /// Bumped whenever the room says something changed.
    public private(set) var revision = 0

    private let client: SyncClient
    private let clubID: String
    private var task: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var retries = 0

    init(client: SyncClient, clubID: String) {
        self.client = client
        self.clubID = clubID
    }

    public func connect() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            await self?.run()
        }
    }

    public func disconnect() {
        listener?.cancel()
        listener = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let ticket = try await client.webSocketTicket(clubID: clubID)
                guard let url = await client.webSocketURL(clubID: clubID, ticket: ticket) else { return }
                let socket = URLSession.shared.webSocketTask(with: url)
                socket.resume()
                task = socket
                isConnected = true
                retries = 0

                while !Task.isCancelled {
                    _ = try await socket.receive()
                    // The message body doesn't matter — any nudge means refetch.
                    revision &+= 1
                }
            } catch {
                isConnected = false
                guard !Task.isCancelled else { return }
                // Back off rather than hammering: a club that is unreachable is
                // usually unreachable for a while, and the screen still polls.
                retries = min(retries + 1, 5)
                try? await Task.sleep(for: .seconds(Double(1 << retries)))
            }
        }
    }
}
