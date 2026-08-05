import Foundation

/// Shapes returned by the Worker's `/api/recs` and `/api/clubs` routes.
///
/// Field names mirror the D1 columns verbatim — the Worker hands back rows
/// largely as the database produced them, and renaming here would mean a
/// mapping layer that has to be kept in step with a schema it can't see.

public struct Recommendation: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var category: String
    public var book_title: String
    public var book_author: String?
    public var book_isbn: String?
    public var cover_url: String?
    public var note: String?
    public var created_by: String?
    public var created_name: String?
    public var created_at: String?
    public var up: Int?
    public var down: Int?
    /// 1 / -1 / 0 — this account's vote.
    public var myVote: Int?
    /// True when the signed-in user posted it. The Worker sends a bool; older
    /// rows can arrive as 0/1, which is why this decodes leniently.
    public var mine: Bool?

    public var score: Int { (up ?? 0) - (down ?? 0) }
    public var author: String { book_author ?? "" }
    public var title: String { book_title }

    private enum CodingKeys: String, CodingKey {
        case id, category, book_title, book_author, book_isbn, cover_url, note
        case created_by, created_name, created_at, up, down, myVote, mine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = (try? c.decode(String.self, forKey: .category)) ?? "General"
        book_title = (try? c.decode(String.self, forKey: .book_title)) ?? "Untitled"
        book_author = try? c.decode(String.self, forKey: .book_author)
        book_isbn = try? c.decode(String.self, forKey: .book_isbn)
        cover_url = try? c.decode(String.self, forKey: .cover_url)
        note = try? c.decode(String.self, forKey: .note)
        created_by = try? c.decode(String.self, forKey: .created_by)
        created_name = try? c.decode(String.self, forKey: .created_name)
        created_at = try? c.decode(String.self, forKey: .created_at)
        up = try? c.decode(Int.self, forKey: .up)
        down = try? c.decode(Int.self, forKey: .down)
        myVote = try? c.decode(Int.self, forKey: .myVote)
        // SQLite has no boolean, so `mine` arrives as a number from some paths
        // and a bool from others.
        if let b = try? c.decode(Bool.self, forKey: .mine) { mine = b }
        else if let n = try? c.decode(Int.self, forKey: .mine) { mine = n != 0 }
        else { mine = nil }
    }

    public init(id: String, category: String, title: String, author: String = "") {
        self.id = id
        self.category = category
        self.book_title = title
        self.book_author = author
    }
}

public struct ClubMember: Codable, Sendable, Identifiable, Hashable {
    public var uid: String
    public var display_name: String?
    public var role: String?
    public var progress_pct: Int

    public var id: String { uid }
    public var name: String { display_name ?? "Reader" }
    public var isHost: Bool { role == "host" }
}

public struct ClubComment: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var uid: String?
    public var display_name: String?
    public var body: String
    public var pos_pct: Int
    public var label: String?
    public var created_at: String?
    public var reactions: Reactions?

    public struct Reactions: Codable, Sendable, Hashable {
        public var counts: [String: Int]?
        public var mine: [String]?
    }

    public var name: String { display_name ?? "Reader" }
    public var date: Date? { created_at.flatMap(ISO8601.date(from:)) }
}

public struct Club: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var book_title: String?
    public var book_author: String?
    public var total_pages: Int?
    public var created_by: String?
    public var last_activity: String?
    public var members: [ClubMember]?
    public var me: ClubMember?

    public var title: String { book_title ?? "A book" }
    public var memberCount: Int { members?.count ?? 0 }
    public var myProgress: Int { me?.progress_pct ?? 0 }
}

/// A club with everything the detail screen needs, as the Worker returns it.
public struct ClubDetail: Sendable {
    public var club: Club
    public var me: ClubMember
    public var members: [ClubMember]
    public var joinCode: String?
    public var comments: [ClubComment]
    /// How many comments are written past your progress. Shown as a count, never
    /// as content — that number is the only thing about them the server will say.
    public var lockedAhead: Int
}

/// Why something was reported. The Worker validates against this exact set.
public enum ReportReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case spam, harassment, sexual, violence, hate, spoiler, other
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .spam: "Spam or advertising"
        case .harassment: "Harassment or abuse"
        case .sexual: "Sexual content"
        case .violence: "Violence or self-harm"
        case .hate: "Hate speech"
        case .spoiler: "Deliberate spoiler"
        case .other: "Something else"
        }
    }
}
