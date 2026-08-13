import Foundation

/// Reading a book *with* one other person.
///
/// **Built on the club API rather than beside it, deliberately.** The hard and
/// valuable part — a spoiler gate the server enforces, so a comment written at
/// 80% cannot reach someone at 30% however the client asks — already exists and
/// is already deployed. A 1:1 read is a club with two people in it, so this adds
/// the framing and the one thing clubs don't have (how far apart you are)
/// without a second gate to keep in sync, a schema migration, or a deploy.
///
/// Fable and StoryGraph have buddy reads and gate nothing; the gate is the whole
/// point, and it's the part that was already finished.
public struct BuddyRead: Sendable, Identifiable {
    public let club: Club
    public let me: ClubMember
    /// The other reader, once someone has joined.
    public let partner: ClubMember?

    public var id: String { club.id }
    public var title: String { club.title }
    public var totalPages: Int? { club.total_pages }

    public init(club: Club, me: ClubMember, partner: ClubMember?) {
        self.club = club
        self.me = me
        self.partner = partner
    }

    /// Build one from a club, if it looks like a pair.
    ///
    /// Two members or fewer: one means the invitation hasn't been taken up yet,
    /// which is still a buddy read — it's just waiting.
    public static func from(club: Club, members: [ClubMember], myUID: String) -> BuddyRead? {
        guard members.count <= 2, let me = members.first(where: { $0.uid == myUID }) else { return nil }
        return BuddyRead(club: club, me: me, partner: members.first { $0.uid != myUID })
    }

    /// Waiting for the other person to accept.
    public var isWaiting: Bool { partner == nil }

    /// Percentage points between you. Positive means they're ahead.
    public var gapPercent: Int? {
        guard let partner else { return nil }
        return partner.progress_pct - me.progress_pct
    }

    /// The gap in pages, when the book has a length to measure against.
    public var gapPages: Int? {
        guard let gap = gapPercent, let pages = totalPages, pages > 0 else { return nil }
        return Int((Double(abs(gap)) / 100 * Double(pages)).rounded())
    }

    /// "Ana is 20 pages ahead of you", "You're 3% ahead", "You're both in the
    /// same place" — the line clubs don't have and the reason to read together.
    ///
    /// Pages where the book has a page count, percent where it doesn't: "20
    /// pages" is a distance you can picture and "7%" isn't.
    public var gapDescription: String? {
        guard let partner, let gap = gapPercent else { return nil }
        // Under two points apart is the same place to any reader, and a line
        // that changes every time either of you logs a session is noise.
        guard abs(gap) >= 2 else { return "You're both at about the same place." }

        let distance: String
        if let pages = gapPages, pages > 0 {
            distance = "\(pages) page\(pages == 1 ? "" : "s")"
        } else {
            distance = "\(abs(gap))%"
        }
        return gap > 0
            ? "\(partner.name) is \(distance) ahead of you."
            : "You're \(distance) ahead of \(partner.name)."
    }

    /// Whether anything they say next is going to be locked to you.
    public var partnerIsAhead: Bool { (gapPercent ?? 0) >= 2 }
}

public extension ClubDetail {
    /// This club as a 1:1 read, when that's what it is.
    var buddyRead: BuddyRead? {
        BuddyRead.from(club: club, members: members, myUID: me.uid)
    }
}
