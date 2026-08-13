import Foundation

/// What your own shelf has to say about a book you're holding in a shop.
///
/// Ported and widened from `checkScannedBook()` / `seriesInsight()` in
/// `src/app.ts`. Every other tracker is backward-looking — it tells you what you
/// read. This answers the question you have with the book in your hand and your
/// card in the machine: *do I already have this, and should I be buying it?*
///
/// It's a pure function of the shelf so it can be tested without a camera, a
/// network or a simulator, which is the same reason the rest of `BookshelfCore`
/// exists.
public struct ShelfVerdict: Sendable, Hashable {

    public enum Outcome: Sendable, Hashable {
        /// You have a copy at home.
        case owned
        /// The book is on your shelves in some form, but you don't own a copy.
        case onShelf(BookStatus)
        /// Nothing on your shelves matches.
        case new

        /// Whether this is a "put it back" answer. Drives the colour of the card
        /// and nothing else — the notes below are where the actual advice is.
        public var isDuplicate: Bool {
            if case .owned = self { return true }
            return false
        }
    }

    /// One line of context under the headline.
    ///
    /// Kept as data rather than a formatted paragraph so the view decides how
    /// many fit on screen, and so each one can be tested for on its own.
    public struct Note: Sendable, Hashable, Identifiable {
        public enum Tone: Sendable, Hashable {
            case neutral
            /// Something in this book's favour.
            case good
            /// Something to think about before paying.
            case warning
        }

        public let id: String
        /// An SF Symbol name — the view draws it, Core just names it.
        public let symbol: String
        public let text: String
        public let tone: Tone

        public init(id: String, symbol: String, text: String, tone: Tone = .neutral) {
            self.id = id
            self.symbol = symbol
            self.text = text
            self.tone = tone
        }
    }

    public let outcome: Outcome
    /// The book on your shelf this matched, when it matched one.
    public let matchedBookID: String?
    public let title: String
    public let author: String
    public let isbn: String
    /// The series this turned out to belong to, whichever source knew. Carried
    /// so that adding the book keeps it — which is what lets the *next* scan in
    /// this series warn about reading order.
    public let seriesName: String
    public let seriesNumber: Double?
    public let headline: String
    public let detail: String
    public let notes: [Note]

    // MARK: - Building one

    /// - Parameters:
    ///   - isbn: the scanned code, already validated.
    ///   - catalogue: what Open Library says it is, when the lookup got through.
    ///     Optional on purpose — bookshops have poor signal, and an ISBN alone
    ///     still answers "do I own this", which is the question that matters most.
    ///   - series: the edition's series string, "The Mistborn Saga #3". Separate
    ///     from `catalogue` because it comes from a different endpoint — the
    ///     search index has no series field at all.
    public static func make(
        isbn: String,
        catalogue: OpenLibrary.Doc?,
        series: String? = nil,
        state: WireState
    ) -> ShelfVerdict {
        let digits = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        let scanned = canonicalISBN(isbn)
        let catalogueTitle = catalogue?.title ?? ""
        let catalogueAuthor = catalogue?.authorLine ?? ""

        // ISBN first — it's exact. Only then by title, because a shelf imported
        // from Goodreads is mostly ISBN-less and would otherwise never match.
        var hit = state.books.first { !scanned.isEmpty && canonicalISBN($0.isbn) == scanned }
        if hit == nil, !catalogueTitle.isEmpty {
            let wanted = compareTitle(catalogueTitle)
            hit = state.books.first { book in
                let mine = compareTitle(book.title)
                guard !mine.isEmpty, !wanted.isEmpty else { return false }
                return mine == wanted || mine.contains(wanted) || wanted.contains(mine)
            }
        }

        let title = hit?.title ?? (catalogueTitle.isEmpty ? "ISBN \(ISBN.formatted(digits))" : catalogueTitle)
        let author = hit.map(\.author).flatMap { $0.isEmpty ? nil : $0 } ?? catalogueAuthor

        // Series identity, best source first: your own record, then the
        // "(Series, #3)" tail Goodreads-style titles carry, then the edition's
        // own series string. All three exist because none of them is reliably
        // present — and without one of them the most useful thing this screen
        // says never gets said.
        let parsed = parseSeries(fromTitle: catalogueTitle) ?? parseSeries(fromSeriesString: series ?? "")
        let seriesName = hit.map(\.seriesName).flatMap { $0.isEmpty ? nil : $0 } ?? parsed?.name ?? ""
        let seriesNumber = hit?.seriesNumber ?? parsed?.number

        var notes: [Note] = []
        let outcome: Outcome
        let headline: String
        let detail: String

        if let hit, hit.owned {
            outcome = .owned
            headline = "You own this"
            detail = hit.location.isEmpty
                ? "“\(hit.title)” is already on your shelf at home."
                : "“\(hit.title)” is at home — \(hit.location)."
            if !hit.location.isEmpty {
                notes.append(Note(id: "location", symbol: "mappin.and.ellipse", text: hit.location))
            }
            // A copy in another format is a real reason to buy the paper one, so
            // say which format you have rather than a flat "you own this".
            if hit.format != .physical {
                notes.append(Note(
                    id: "format",
                    symbol: hit.format == .audio ? "headphones" : "ipad",
                    text: "Your copy is \(articled(hit.format)) — this one isn't a duplicate if you want it on paper.",
                    tone: .neutral
                ))
            }
            if hit.isLentOut {
                notes.append(Note(
                    id: "lent",
                    symbol: "person.crop.circle.badge.clock",
                    text: "It's with \(hit.lentTo) right now.",
                    tone: .warning
                ))
            }
        } else if let hit {
            outcome = .onShelf(hit.status)
            headline = shelfHeadline(hit.status)
            detail = shelfDetail(hit)
            notes.append(Note(
                id: "not-owned",
                symbol: "house",
                text: "You don't have a copy at home.",
                tone: .neutral
            ))
        } else {
            outcome = .new
            headline = "Not on your shelves"
            detail = catalogueTitle.isEmpty
                ? "Nothing in your library matches \(ISBN.formatted(digits))."
                : "“\(catalogueTitle)”\(catalogueAuthor.isEmpty ? "" : " by \(catalogueAuthor)") isn't in your library."
        }

        notes.append(contentsOf: seriesNotes(
            seriesName: seriesName, number: seriesNumber, matched: hit, state: state
        ))
        notes.append(contentsOf: authorNotes(
            author: author, matched: hit, state: state
        ))
        if case .new = outcome {
            notes.append(contentsOf: pileNotes(state: state))
        }

        return ShelfVerdict(
            outcome: outcome,
            matchedBookID: hit?.id,
            title: title,
            author: author,
            isbn: digits,
            seriesName: seriesName,
            seriesNumber: seriesNumber,
            headline: headline,
            detail: detail,
            notes: notes
        )
    }

    // MARK: - Series

    /// "The Well of Ascension (Mistborn, #2)" → ("Mistborn", 2).
    ///
    /// Ported from `parseSeriesFromTitle()`, tail-anchored so a title with a
    /// parenthetical of its own ("(Illustrated Edition)") isn't read as a series.
    public static func parseSeries(fromTitle title: String) -> (name: String, number: Double)? {
        let pattern = #"\(([^,(#]+?)[,]?\s*#\s*(\d+(?:\.\d+)?)\)\s*$"#
        guard let match = title.range(of: pattern, options: .regularExpression) else { return nil }
        let inner = title[match].dropFirst().dropLast()          // strip the brackets
        let parts = inner.split(separator: "#", maxSplits: 1)
        guard parts.count == 2,
              let number = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let name = parts[0]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, number)
    }

    /// "The Mistborn Saga #3" → ("The Mistborn Saga", 3), and a bare
    /// "The Kingkiller Chronicle" → (that, nil).
    ///
    /// Deliberately *not* used on titles. A series string is already declared to
    /// be one, so a bare trailing number can be read as an instalment; a title
    /// can't, or "Fahrenheit 451" becomes book 451 of Fahrenheit.
    public static func parseSeries(fromSeriesString raw: String) -> (name: String, number: Double?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Bracketed form first — some records use the title convention here too.
        if let bracketed = parseSeries(fromTitle: trimmed) { return (bracketed.name, bracketed.number) }

        if let hash = trimmed.lastIndex(of: "#") {
            let name = trimmed[trimmed.startIndex..<hash]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                .trimmingCharacters(in: .whitespaces)
            let number = Double(trimmed[trimmed.index(after: hash)...].trimmingCharacters(in: .whitespaces))
            if !name.isEmpty { return (name, number) }
        }
        return (trimmed, nil)
    }

    /// Whether two series names are the same series.
    ///
    /// Not string equality: catalogues and readers disagree about what a series
    /// is called — "The Mistborn Saga" on the edition, "Mistborn" on the shelf —
    /// and an exact match would mean the series note almost never appears on the
    /// books it matters most for.
    static func seriesMatches(_ a: String, _ b: String) -> Bool {
        let x = normalizeSeries(a), y = normalizeSeries(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    private static func normalizeSeries(_ raw: String) -> String {
        var s = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        // The words publishers add and readers drop.
        for suffix in [" saga", " series", " sequence", " cycle", " trilogy", " chronicles", " chronicle", " novels", " books"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                break
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Where this book sits in a series you're already collecting — the answer
    /// no backward-looking tracker gives you, and the one that stops you buying
    /// book three when book two is still unread.
    private static func seriesNotes(
        seriesName: String,
        number: Double?,
        matched: WireBook?,
        state: WireState
    ) -> [Note] {
        guard !seriesName.isEmpty else { return [] }
        let inSeries = state.books.filter { seriesMatches($0.seriesName, seriesName) }
        guard !inSeries.isEmpty else { return [] }

        // Your name for it, not the catalogue's — you filed these books under
        // "Mistborn", and being told about "The Mistborn Saga" reads like a
        // different shelf.
        let seriesName = inSeries.first { !$0.seriesName.isEmpty }?.seriesName ?? seriesName
        var notes: [Note] = []
        let ownedNumbers = inSeries
            .filter { $0.owned && $0.seriesNumber != nil }
            .compactMap(\.seriesNumber)
            .sorted()
        let haveList = ownedNumbers.isEmpty
            ? ""
            : " — you own \(ownedNumbers.map { "#\(JS.numberToString($0))" }.joined(separator: ", "))"
        notes.append(Note(
            id: "series",
            symbol: "books.vertical",
            text: "You have \(inSeries.count) from \(seriesName)\(haveList).",
            tone: .neutral
        ))

        guard let number else { return notes }

        // Already own this exact instalment — the single most useful thing to be
        // told while holding it.
        if matched?.owned != true, inSeries.contains(where: { $0.seriesNumber == number && $0.owned }) {
            notes.append(Note(
                id: "series-duplicate",
                symbol: "exclamationmark.triangle",
                text: "You already own #\(JS.numberToString(number)) of this series.",
                tone: .warning
            ))
        }

        // The out-of-order warning. Only fires when the previous instalment is
        // actually on your shelves and unfinished — a series you started in the
        // middle deliberately shouldn't nag.
        let previous = number - 1
        if previous >= 1, let before = inSeries.first(where: { $0.seriesNumber == previous }), before.status != .finished {
            notes.append(Note(
                id: "series-gap",
                symbol: "arrow.uturn.backward",
                text: "This is #\(JS.numberToString(number)) and you haven't read #\(JS.numberToString(previous)) yet.",
                tone: .warning
            ))
        } else if !inSeries.contains(where: { $0.seriesNumber == number }) {
            notes.append(Note(
                id: "series-next",
                symbol: "number",
                text: "This is #\(JS.numberToString(number)), which you don't have.",
                tone: .good
            ))
        }
        return notes
    }

    // MARK: - Author

    /// Your history with whoever wrote it. Two books of theirs abandoned is worth
    /// knowing before the third goes in the basket.
    private static func authorNotes(author: String, matched: WireBook?, state: WireState) -> [Note] {
        let name = author.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return [] }

        // Surname matching, because Open Library and Goodreads rarely spell an
        // author the same way. The book itself is excluded — "you've read this
        // author once" about the very book in your hand is not a fact.
        let theirs = state.books.filter { book in
            book.id != matched?.id
                && !book.author.isEmpty
                && OpenLibrary.authorMatches(name, [book.author])
        }
        guard !theirs.isEmpty else { return [] }

        var notes: [Note] = []
        let abandoned = theirs.filter { $0.status == .dnf }
        let finished = theirs.filter { $0.status == .finished }

        if abandoned.count >= 2 {
            notes.append(Note(
                id: "author-dnf",
                symbol: "hand.raised",
                text: "You've set aside \(abandoned.count) of their books unfinished.",
                tone: .warning
            ))
        } else if let one = abandoned.first {
            notes.append(Note(
                id: "author-dnf",
                symbol: "hand.raised",
                text: "You gave up on their “\(one.title)”.",
                tone: .warning
            ))
        }

        if !finished.isEmpty {
            let ratings = finished.compactMap(\.rating)
            var text = "You've finished \(finished.count) by them"
            if !ratings.isEmpty {
                let average = (ratings.reduce(0, +) / Double(ratings.count) * 10).rounded() / 10
                text += ", \(JS.numberToString(average))★ on average"
            }
            notes.append(Note(id: "author-read", symbol: "checkmark.seal", text: text + ".", tone: .good))
        }

        let waiting = theirs.filter { $0.status == .want }
        if waiting.count >= 1 {
            notes.append(Note(
                id: "author-want",
                symbol: "bookmark",
                text: "\(waiting.count) more by them \(waiting.count == 1 ? "is" : "are") already on your want list.",
                tone: .neutral
            ))
        }
        return notes
    }

    // MARK: - The pile

    /// Said only about a book you don't have: how much unread paper is already at
    /// home. Left off every other outcome, where it would be scolding rather than
    /// useful.
    private static func pileNotes(state: WireState) -> [Note] {
        let unread = state.books.filter { $0.owned && ($0.status == .want || $0.status == .reading) }
        guard unread.count >= 5 else { return [] }
        return [Note(
            id: "pile",
            symbol: "tray.full",
            text: "\(unread.count) books you own are still unread.",
            tone: .neutral
        )]
    }

    // MARK: - Wording

    private static func shelfHeadline(_ status: BookStatus) -> String {
        switch status {
        case .want: "Already on your want list"
        case .reading: "You're reading this right now"
        case .finished: "You've already read this"
        case .dnf: "You set this one aside"
        }
    }

    private static func shelfDetail(_ book: WireBook) -> String {
        switch book.status {
        case .want:
            "“\(book.title)” is on your list — you just don't have a copy."
        case .reading:
            book.progress.map { "You're \(Int($0 * 100))% through “\(book.title)” already." }
                ?? "“\(book.title)” is on the go."
        case .finished:
            book.rating.map { "You finished “\(book.title)” and gave it \(JS.numberToString($0))★." }
                ?? "You've finished “\(book.title)”."
        case .dnf:
            book.dnfReason.isEmpty
                ? "You stopped reading “\(book.title)”."
                : "You stopped reading “\(book.title)” — you noted: “\(book.dnfReason)”."
        }
    }

    private static func articled(_ format: BookFormat) -> String {
        switch format {
        case .physical: "a physical copy"
        case .ebook: "an e-book"
        case .audio: "an audiobook"
        }
    }

    // MARK: - Matching helpers

    /// Both sides of an ISBN comparison put into the same form.
    ///
    /// A barcode is always an ISBN-13, but a shelf is full of ISBN-10s — that's
    /// what Goodreads exports and what's printed inside older books. Comparing
    /// the digits as they happen to be stored means the same book never matches
    /// itself, and the scanner cheerfully tells you to buy a book you own.
    /// Anything that isn't a valid ISBN falls back to its bare digits, so a
    /// hand-typed or malformed number can still match an identical one.
    private static func canonicalISBN(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
        return ISBN.normalize(digits) ?? digits
    }

    /// Ported from `normT()`: drop a trailing parenthetical and anything after a
    /// colon, so "Dune (Dune, #1): 50th Anniversary" and "Dune" are the same book.
    private static func compareTitle(_ raw: String) -> String {
        var s = OpenLibrary.bareTitle(raw)
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        return s.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
