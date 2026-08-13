import CoreGraphics
import Foundation

/// Reading a whole shelf out of one photograph.
///
/// **Why this is the flagship.** Nobody types in two hundred books, which is the
/// single biggest reason people abandon a reading tracker. Goodreads offers
/// nothing here; the cataloguing apps do one barcode at a time, and a spine has
/// no barcode. Pointing a camera at a shelf is the only import that matches how
/// a physical library actually exists.
///
/// **The review step is the feature, not an afterthought.** OCR on a worn spine
/// is wrong often enough that silently adding what it guessed would poison a
/// library that took years to build. Everything here is therefore built to
/// produce *candidates with their evidence attached* — the cropped spine, the
/// text read off it, the catalogue match — so a person can confirm a screenful
/// in a few seconds and reject the rest.
public enum ShelfieDetection {

    /// Deliberately looser than `SpineDetection`, which is tuned for one book
    /// held up to the lens. A shelf photographed from a metre away puts thirty
    /// spines in frame, each a fraction of the height a single held book fills —
    /// the single-book thresholds reject essentially all of them.
    public static let minLongSide = 0.12
    public static let maxAspect = 0.55
    public static let minAspect = 0.015
    /// Books lean. A shelf that isn't full has spines at a real angle, and they
    /// are still books.
    public static let maxTilt = 38.0

    /// Two detections of the same spine overlap almost entirely; two neighbouring
    /// books barely touch. Above this they're treated as one.
    public static let maxOverlap = 0.45

    public static func isPlausible(_ quad: SpineQuad) -> Bool {
        let aspect = quad.aspect
        guard aspect.isFinite else { return false }
        return aspect <= maxAspect
            && aspect >= minAspect
            && quad.longSide >= minLongSide
            && abs(quad.tilt) <= maxTilt
    }

    /// Every spine in the frame, left to right.
    ///
    /// Reading order matters more than it looks: the review list is compared
    /// against the actual shelf by eye, and a list in detector order — which is
    /// confidence order — makes that impossible.
    public static func spines(from candidates: [SpineQuad], limit: Int = 60) -> [SpineQuad] {
        let plausible = candidates.filter(isPlausible)
        // Tallest first, so when two detections of one book overlap, the survivor
        // is the one that found the whole spine rather than half of it.
        let ranked = plausible.sorted { $0.longSide > $1.longSide }

        var kept: [SpineQuad] = []
        for quad in ranked {
            guard kept.count < limit else { break }
            if kept.contains(where: { overlap($0, quad) > maxOverlap }) { continue }
            kept.append(quad)
        }
        return kept.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
    }

    /// Intersection over the *smaller* box, not over the union.
    ///
    /// A half-detection sitting entirely inside a full one scores ~1 here and
    /// only ~0.5 by IoU — and it's exactly the case that has to be caught, or
    /// every book is offered twice.
    static func overlap(_ a: SpineQuad, _ b: SpineQuad) -> Double {
        let ra = a.boundingBox, rb = b.boundingBox
        let inter = ra.intersection(rb)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let smaller = min(ra.width * ra.height, rb.width * rb.height)
        guard smaller > 0 else { return 0 }
        return (inter.width * inter.height) / smaller
    }
}

/// What was printed on one spine, once the noise is gone.
public struct SpineText: Sendable, Hashable {
    /// Everything OCR read, in the order it appeared. Kept so a person can see
    /// what the guess was made from.
    public let lines: [String]
    /// The lines left after imprints, prices and blurb were dropped.
    public let usefulLines: [String]
    /// The best guess at the title.
    public let title: String
    /// The best guess at the author, or empty when nothing was clearly a name.
    public let author: String

    public init(lines: [String], usefulLines: [String] = [], title: String, author: String) {
        self.lines = lines
        self.usefulLines = usefulLines.isEmpty ? [title, author].filter { !$0.isEmpty } : usefulLines
        self.title = title
        self.author = author
    }

    /// What to send to the catalogue.
    ///
    /// When the title/author split is confident, both go. When it isn't, the
    /// useful lines go as they were read — Open Library's free-text search copes
    /// with either order, and a *wrong* split ("author: Wolf Hall") searches for
    /// something that doesn't exist. Getting the split exactly right matters for
    /// the label on a row, not for finding the book.
    public var query: String {
        if !author.isEmpty, !title.isEmpty { return "\(title) \(author)" }
        return usefulLines.prefix(3).joined(separator: " ")
    }

    /// Nothing usable was read — a blank spine, a shadow, or a crop that missed.
    public var isEmpty: Bool { usefulLines.isEmpty }
}

/// Turning the fragments OCR returns into a title and an author.
///
/// A spine is not a page: it carries the publisher's name, an imprint colophon,
/// a series number, "A NOVEL", and an award sticker, in three typefaces and two
/// directions. Sending all of that to a catalogue search returns nothing. This
/// is the part worth testing, because every rule here comes from a real spine
/// that failed to match.
public enum SpineTextParser {

    /// Imprints that appear on spines and are never part of a title. Matched as
    /// whole lines only — "Penguin" alone is a publisher, but *The Penguin Book
    /// of English Verse* is a book.
    static let publishers: Set<String> = [
        "penguin", "penguin books", "penguin classics", "puffin", "vintage", "vintage classics",
        "faber", "faber & faber", "faber and faber", "picador", "bloomsbury", "harper", "harpercollins",
        "harper perennial", "harper voyager", "fourth estate", "4th estate", "jonathan cape", "chatto & windus",
        "secker & warburg", "granta", "verso", "virago", "serpent's tail", "canongate", "profile",
        "oxford", "oxford university press", "oup", "cambridge university press", "everyman", "everyman's library",
        "norton", "w w norton", "knopf", "doubleday", "bantam", "corgi", "arrow", "pan", "pan books",
        "macmillan", "simon & schuster", "scribner", "little brown", "hodder", "hodder & stoughton",
        "headline", "orbit", "gollancz", "tor", "del rey", "voyager", "anchor", "riverhead", "picador usa",
        "vintage international", "modern library", "black swan", "sceptre", "abacus", "phoenix", "orion",
        "harvill secker", "fitzcarraldo", "pushkin press", "peirene", "and other stories", "dover",
    ]

    /// Blurb and award furniture. Substring-matched, since these arrive glued to
    /// whatever was next to them.
    static let noisePhrases = [
        "a novel", "bestseller", "best seller", "bestselling", "winner of", "shortlisted",
        "longlisted", "as seen on", "now a major", "international", "million copies",
        "prize", "award", "book club", "unabridged", "illustrated edition", "new edition",
    ]

    public static func parse(_ rawLines: [String]) -> SpineText {
        let cleaned = rawLines
            .map(tidy)
            .filter { !$0.isEmpty }

        let useful = cleaned.filter { isUseful($0) }
        guard !useful.isEmpty else {
            return SpineText(lines: cleaned, usefulLines: [], title: "", author: "")
        }

        let authorLine = author(among: useful)
        let titleCandidates = useful.filter { $0 != authorLine }
        // The longest remaining line. Not the first: spines are printed with the
        // author above the title as often as below, and there is no reliable
        // order — but a title is nearly always the longest thing on the spine.
        let title = titleCandidates.max { score($0) < score($1) } ?? ""

        return SpineText(
            lines: cleaned,
            usefulLines: useful,
            title: title,
            author: title.isEmpty ? "" : (authorLine ?? "")
        )
    }

    /// The line that is the author's name, when one can be told apart.
    ///
    /// Taken before the title so the title picker can't claim it: on a spine the
    /// author is very often the longest line, which is exactly the wrong
    /// tiebreak.
    ///
    /// The hard case is a title shaped like a name — *Wolf Hall*, *Dark Matter*.
    /// Where two lines both read as names, the caps-set one is taken as the
    /// author, since a title-case line beside it is nearly always the title; and
    /// where that doesn't separate them, **no author is claimed at all**. An
    /// empty author costs a slightly worse row label; a confidently wrong one
    /// sends the catalogue looking for a book by nobody.
    static func author(among useful: [String]) -> String? {
        let nameish = useful.filter { looksLikeName($0) && !looksLikeTitle($0) }
        guard useful.count > 1 else { return nil }
        if nameish.count == 1 { return nameish[0] }
        guard nameish.count > 1 else { return nil }

        let caps = nameish.filter(isAllCaps)
        let mixed = nameish.filter { !isAllCaps($0) }
        return caps.count == 1 && !mixed.isEmpty ? caps[0] : nil
    }

    /// No lowercase letters at all — how a great many spines set the author.
    static func isAllCaps(_ line: String) -> Bool {
        line.contains(where: \.isUppercase) && !line.contains(where: \.isLowercase)
    }

    // MARK: - Rules

    /// Normalise one OCR line. `ALL CAPS` is left alone — a great many spines are
    /// set in caps, and title-casing them would guess wrong on names like McEwan.
    static func tidy(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // OCR leaves stray marks at the ends of a narrow crop.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "|/\\_-–—·•.,:;\"'`~^*"))
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isUseful(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Two characters can't identify a book and is what a colophon or a series
        // number reads as.
        guard line.count >= 3 else { return false }
        guard publishers.contains(lower) == false else { return false }
        guard !noisePhrases.contains(where: { lower.contains($0) }) else { return false }
        // Needs real letters. Prices, ISBNs and "978" fragments read as lines.
        let letters = line.filter(\.isLetter).count
        guard letters >= 3, Double(letters) / Double(line.count) > 0.5 else { return false }
        return true
    }

    /// Two to four capitalised words, no connective tissue — how a name looks and
    /// how a title mostly doesn't.
    static func looksLikeName(_ line: String) -> Bool {
        let words = line.split(separator: " ").map(String.init)
        guard (2...4).contains(words.count) else { return false }
        // A title's giveaway is the small words a name never has.
        let stopwords: Set<String> = ["the", "of", "and", "a", "an", "in", "on", "to", "for", "with", "at", "from"]
        guard !words.contains(where: { stopwords.contains($0.lowercased()) }) else { return false }
        return words.allSatisfy { word in
            guard let first = word.first else { return false }
            // Caps-set spines make every letter uppercase, which tells us nothing
            // either way — so accept it rather than rejecting every such spine.
            return first.isUppercase && word.count >= 2
        }
    }

    /// Something only a title does. Guards the author pick, which would otherwise
    /// claim "Wolf Hall" or "Dark Matter".
    static func looksLikeTitle(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("the ") || lower.hasPrefix("a ") || lower.hasPrefix("an ") { return true }
        return line.contains(":") || line.contains("?") || line.contains("!")
    }

    /// Longer is more likely to be the title, but not without limit — a whole
    /// blurb read as one line shouldn't beat the actual title.
    static func score(_ line: String) -> Int {
        let n = line.count
        return n <= 45 ? n : max(0, 90 - n)
    }
}

/// One book the shelfie thinks it found, with everything needed to judge it.
///
/// Carries its evidence deliberately: a row offering "Wolf Hall — Hilary Mantel"
/// with no way to see what it read off the spine is a row you can only accept on
/// faith, and faith is what makes a bulk import destroy a library.
public struct ShelfieCandidate: Sendable, Identifiable {
    public enum Decision: Sendable, Hashable {
        /// Waiting on the reader.
        case undecided
        case keep
        case skip
    }

    public let id: String
    /// Where on the photo it came from, for showing the crop.
    public let quad: SpineQuad
    public let text: SpineText
    /// What the catalogue matched, if anything did.
    public var match: OpenLibrary.Doc?
    public var decision: Decision
    /// Set when this spine turned out to be a book already on the shelf.
    public var duplicateOfID: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        quad: SpineQuad,
        text: SpineText,
        match: OpenLibrary.Doc? = nil,
        decision: Decision = .undecided,
        duplicateOfID: String? = nil
    ) {
        self.id = id
        self.quad = quad
        self.text = text
        self.match = match
        self.decision = decision
        self.duplicateOfID = duplicateOfID
    }

    /// What to show as the book's name — the catalogue's title once matched, and
    /// the raw OCR before that, so a row is never blank while it resolves.
    public var displayTitle: String {
        match?.title ?? (text.title.isEmpty ? "Couldn't read this one" : text.title)
    }

    public var displayAuthor: String {
        match?.authorLine ?? text.author
    }

    /// Whether this is worth offering at all.
    public var isUsable: Bool { !text.isEmpty }
}

public extension WireState {
    /// A book already on the shelf that this candidate is probably the same as.
    ///
    /// Checked before the import, not after: a shelfie of a bookcase you've
    /// already catalogued should offer to skip the ones you have rather than
    /// silently double every title.
    func existingBook(matching candidate: ShelfieCandidate) -> WireBook? {
        // The catalogue's title where there is one, and otherwise *any* line read
        // off the spine — before a match resolves the title/author split is a
        // guess, and checking only the guessed title misses the duplicate whenever
        // the guess landed on the author.
        var attempts: [String] = []
        if let matched = candidate.match?.title { attempts.append(matched) }
        attempts.append(contentsOf: candidate.text.usefulLines)

        for attempt in attempts {
            let key = ShelfieMatching.titleKey(attempt)
            // Under four characters a key matches half the shelf by accident.
            guard key.count >= 4 else { continue }
            if let hit = books.first(where: { ShelfieMatching.titleKey($0.title) == key }) { return hit }
            // A spine reading "HOBBIT" against a shelf holding "The Hobbit": one
            // is a word inside the other, which a whole-key comparison misses.
            if let hit = books.first(where: { book in
                let mine = ShelfieMatching.titleKey(book.title)
                return mine.count >= 4 && (mine == key || mine.hasPrefix(key + " ") || key.hasPrefix(mine + " "))
            }) { return hit }
        }
        return nil
    }
}

public enum ShelfieMatching {
    /// Titles compared the way a person would: ignoring case, accents, articles
    /// and punctuation, so "The Hobbit" and "HOBBIT," are one book.
    public static func titleKey(_ raw: String) -> String {
        var s = OpenLibrary.bareTitle(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        s = s.map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
        var words = s.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
