import Foundation
import Testing
@testable import BookshelfCore

/// Reading with one other person. The gap line is the whole addition over a
/// club, so it has to be right and it has to stop moving when nothing
/// meaningful changed.
struct BuddyReadTests {

    static func member(_ uid: String, _ name: String, at percent: Int) -> ClubMember {
        ClubMember(uid: uid, display_name: name, role: uid == "me" ? "host" : "member", progress_pct: percent)
    }

    static func club(pages: Int? = 300) -> Club {
        Club(
            id: "c1", book_title: "Piranesi", book_author: "Susanna Clarke",
            total_pages: pages, created_by: "me", last_activity: nil, members: nil, me: nil
        )
    }

    @Test("a pair is a buddy read; a crowd is a club")
    func onlyPairs() {
        let two = [Self.member("me", "You", at: 10), Self.member("ana", "Ana", at: 30)]
        #expect(BuddyRead.from(club: Self.club(), members: two, myUID: "me") != nil)

        let three = two + [Self.member("sam", "Sam", at: 5)]
        #expect(BuddyRead.from(club: Self.club(), members: three, myUID: "me") == nil)
    }

    @Test("an unanswered invitation is a buddy read that's waiting")
    func waiting() throws {
        let alone = [Self.member("me", "You", at: 10)]
        let buddy = try #require(BuddyRead.from(club: Self.club(), members: alone, myUID: "me"))
        #expect(buddy.isWaiting)
        #expect(buddy.gapDescription == nil, "there's nobody to be ahead of yet")
    }

    @Test("the gap is given in pages, which is a distance you can picture")
    func gapInPages() throws {
        // 30% vs 10% of 300 pages. "20%" is arithmetic; "60 pages" is a place in
        // the book.
        let buddy = try #require(BuddyRead.from(
            club: Self.club(pages: 300),
            members: [Self.member("me", "You", at: 10), Self.member("ana", "Ana", at: 30)],
            myUID: "me"
        ))
        #expect(buddy.gapPages == 60)
        #expect(buddy.gapDescription == "Ana is 60 pages ahead of you.")
        #expect(buddy.partnerIsAhead)
    }

    @Test("being ahead reads the other way round")
    func aheadOfThem() throws {
        let buddy = try #require(BuddyRead.from(
            club: Self.club(pages: 300),
            members: [Self.member("me", "You", at: 50), Self.member("ana", "Ana", at: 20)],
            myUID: "me"
        ))
        #expect(buddy.gapDescription == "You're 90 pages ahead of Ana.")
        #expect(!buddy.partnerIsAhead)
    }

    @Test("without a page count the gap falls back to a percentage")
    func gapWithoutPages() throws {
        let buddy = try #require(BuddyRead.from(
            club: Self.club(pages: nil),
            members: [Self.member("me", "You", at: 10), Self.member("ana", "Ana", at: 40)],
            myUID: "me"
        ))
        #expect(buddy.gapPages == nil)
        #expect(buddy.gapDescription == "Ana is 30% ahead of you.")
    }

    @Test("a page apart is the same place, and stays the same place")
    func smallGapsDoNotTwitch() throws {
        // Otherwise the line rewrites itself every time either of you logs a
        // session, which reads as the two of you leapfrogging rather than
        // reading together.
        let buddy = try #require(BuddyRead.from(
            club: Self.club(pages: 300),
            members: [Self.member("me", "You", at: 31), Self.member("ana", "Ana", at: 32)],
            myUID: "me"
        ))
        #expect(buddy.gapDescription == "You're both at about the same place.")
        #expect(!buddy.partnerIsAhead)
    }
}
