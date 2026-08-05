import Foundation

/// The community board, reading clubs, and the moderation routes added in MW.
public extension SyncClient {

    // MARK: - Community board

    /// The board is publicly readable; posting and voting need an account.
    /// Blocked authors are filtered out server-side, per viewer — nothing is
    /// deleted and the blocked person is never told.
    func recommendations() async throws -> (recs: [Recommendation], signedIn: Bool, capped: Bool) {
        let data = try await get("/api/recs")
        struct Payload: Decodable {
            var recs: [Recommendation]?
            var signedIn: Bool?
            var capped: Bool?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.recs ?? [], payload.signedIn ?? false, payload.capped ?? false)
    }

    @discardableResult
    func recommend(
        title: String, author: String, category: String,
        note: String, isbn: String, coverUrl: String, displayName: String
    ) async throws -> (id: String, duplicate: Bool) {
        let data = try await post("/api/recs", [
            "bookTitle": .string(title),
            "bookAuthor": .string(author),
            "category": .string(category),
            "note": .string(note),
            "bookIsbn": .string(isbn),
            "coverUrl": .string(coverUrl),
            "displayName": .string(displayName),
        ])
        let value = try? JSONValue.parse(data)
        return (value?["id"].stringValue ?? "", value?["duplicate"].boolValue ?? false)
    }

    /// Returns the vote now held: casting the same vote again clears it.
    func vote(recID: String, vote: Int) async throws -> Int {
        let data = try await post("/api/recs/\(recID)/vote", ["vote": .number(Double(vote))])
        return Int((try? JSONValue.parse(data))?["myVote"].numberValue ?? 0)
    }

    func deleteRecommendation(id: String) async throws {
        _ = try await post("/api/recs/\(id)/delete", [:])
    }

    // MARK: - Moderation

    /// Report a recommendation. `hidden` is true when this report was the one
    /// that crossed the auto-hide threshold.
    @discardableResult
    func report(recID: String, reason: ReportReason, detail: String = "") async throws -> Bool {
        let data = try await post("/api/recs/\(recID)/report", [
            "reason": .string(reason.rawValue),
            "detail": .string(detail),
        ])
        return (try? JSONValue.parse(data))?["hidden"].boolValue ?? false
    }

    @discardableResult
    func report(clubID: String, commentID: String, reason: ReportReason, detail: String = "") async throws -> Bool {
        let data = try await post("/api/clubs/\(clubID)/comments/\(commentID)/report", [
            "reason": .string(reason.rawValue),
            "detail": .string(detail),
        ])
        return (try? JSONValue.parse(data))?["hidden"].boolValue ?? false
    }

    func blockedUsers() async throws -> [String] {
        let data = try await get("/api/blocks")
        struct Row: Decodable { var blocked_uid: String }
        struct Payload: Decodable { var blocks: [Row]? }
        return (try JSONDecoder().decode(Payload.self, from: data).blocks ?? []).map(\.blocked_uid)
    }

    func block(uid: String) async throws {
        _ = try await post("/api/blocks", ["uid": .string(uid)])
    }

    func unblock(uid: String) async throws {
        _ = try await send(method: "DELETE", path: "/api/blocks/\(uid)", jsonBody: nil)
    }

    // MARK: - Clubs

    func clubs() async throws -> [Club] {
        let data = try await get("/api/clubs")
        struct Payload: Decodable { var clubs: [Club]? }
        return try JSONDecoder().decode(Payload.self, from: data).clubs ?? []
    }

    func createClub(title: String, author: String, totalPages: Int?, displayName: String) async throws -> (clubID: String, joinCode: String) {
        var body: [String: JSONValue] = [
            "bookTitle": .string(title),
            "bookAuthor": .string(author),
            "displayName": .string(displayName),
        ]
        if let totalPages { body["totalPages"] = .number(Double(totalPages)) }
        let data = try await post("/api/clubs", body)
        let value = try? JSONValue.parse(data)
        return (value?["clubId"].stringValue ?? "", value?["joinCode"].stringValue ?? "")
    }

    func joinClub(code: String, displayName: String) async throws -> String {
        let data = try await post("/api/clubs/join", [
            "joinCode": .string(code.uppercased()),
            "displayName": .string(displayName),
        ])
        return (try? JSONValue.parse(data))?["clubId"].stringValue ?? ""
    }

    /// Detail plus the comments this member is allowed to see.
    ///
    /// Two calls because the Worker exposes them separately, and the spoiler gate
    /// lives on the comments one — the client never filters, it only renders what
    /// arrives.
    func clubDetail(id: String) async throws -> ClubDetail {
        struct DetailPayload: Decodable {
            var club: Club
            var me: ClubMember
            var members: [ClubMember]?
            var joinCode: String?
        }
        struct CommentsPayload: Decodable {
            var comments: [ClubComment]?
            var lockedAhead: Int?
            var myProgress: Int?
        }
        let detail = try JSONDecoder().decode(DetailPayload.self, from: try await get("/api/clubs/\(id)"))
        let comments = try JSONDecoder().decode(CommentsPayload.self, from: try await get("/api/clubs/\(id)/comments"))
        return ClubDetail(
            club: detail.club,
            me: detail.me,
            members: detail.members ?? [],
            joinCode: detail.joinCode,
            comments: comments.comments ?? [],
            lockedAhead: comments.lockedAhead ?? 0
        )
    }

    func postComment(clubID: String, body: String, atPercent: Int, label: String? = nil) async throws {
        var payload: [String: JSONValue] = [
            "body": .string(body),
            "posPct": .number(Double(atPercent)),
        ]
        if let label, !label.isEmpty { payload["label"] = .string(label) }
        _ = try await post("/api/clubs/\(clubID)/comments", payload)
    }

    /// Progress is forward-only on the server: it takes the maximum of what it
    /// has and what you send, so a sync hiccup can never un-reveal a spoiler.
    func setProgress(clubID: String, percent: Int) async throws {
        _ = try await send(
            method: "PUT", path: "/api/clubs/\(clubID)/progress",
            jsonBody: try JSONValue.object(["progressPct": .number(Double(percent))]).encoded()
        )
    }

    @discardableResult
    func react(clubID: String, commentID: String, emoji: String) async throws -> Bool {
        let data = try await post("/api/clubs/\(clubID)/reactions", [
            "commentId": .string(commentID),
            "emoji": .string(emoji),
        ])
        return (try? JSONValue.parse(data))?["reacted"].boolValue ?? false
    }

    func leaveClub(id: String) async throws {
        _ = try await post("/api/clubs/\(id)/leave", [:])
    }

    /// A short-lived, club-scoped ticket for the live socket.
    ///
    /// A WebSocket handshake can't carry an Authorization header, so whatever it
    /// does carry ends up in proxy and access logs. That is why this is a
    /// 60-second ticket for one room rather than the 30-day session token — the
    /// REST API rejects it outright.
    func webSocketTicket(clubID: String) async throws -> String {
        let data = try await post("/api/clubs/\(clubID)/ws-ticket", [:])
        guard let ticket = (try? JSONValue.parse(data))?["ticket"].stringValue, !ticket.isEmpty else {
            throw Failure.decoding("no realtime ticket")
        }
        return ticket
    }

    func webSocketURL(clubID: String, ticket: String) -> URL? {
        var comps = URLComponents(url: baseURL.appending(path: "/api/clubs/\(clubID)/ws"), resolvingAgainstBaseURL: false)
        comps?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        comps?.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return comps?.url
    }
}
