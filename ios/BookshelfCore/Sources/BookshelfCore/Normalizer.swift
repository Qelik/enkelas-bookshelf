import Foundation

/// Port of `normalize()` in `src/app.ts`.
///
/// This is the single most important function in the iOS app. It is the contract
/// between the phone and the browser: both clients read and write the same blob
/// through the same sync endpoint, so if this disagrees with the JavaScript by
/// even one field, a user loses data the moment they switch devices.
///
/// It is therefore a *deliberate transliteration*, not a rewrite. Where the
/// JavaScript does something a Swift developer wouldn't — folding a rating of 0
/// to nil, turning a `readCount` of 0 into 1, keeping a `seriesNumber` of 0 but
/// discarding a `rating` of 0 — this matches it and says why. Correctness here
/// means "identical to the web app", not "sensible in isolation".
///
/// Verified against the real thing by `NormalizerGoldenTests`, which runs the
/// live `window.__test.normalize` over a shared corpus and diffs the output.
public struct Normalizer: Sendable {

    /// The web app's `SCHEMA_VERSION`. `normalize()` always stamps this and never
    /// reads `data.version`.
    public static let schemaVersion = 1

    /// Injected so tests are deterministic. In the app these are the real clock
    /// and a real UUID, matching `new Date().toISOString()` and `crypto.randomUUID()`.
    public var now: @Sendable () -> Date
    public var makeID: @Sendable () -> String

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.now = now
        self.makeID = makeID
    }

    // MARK: - Entry point

    public func normalize(_ data: JSONValue) -> WireState {
        var base = defaultState()
        // `if (!data || typeof data !== "object") return base` — note that an
        // array passes this test in JS (arrays are objects), and then every
        // property read on it yields undefined, so the result is the default
        // state either way.
        guard case .object = data else {
            if case .array = data {} else { return base }
            return base
        }

        // `if (data.updatedAt) base.updatedAt = data.updatedAt`
        //
        // Known, accepted deviation: the JavaScript assigns the raw value, so a
        // numeric `updatedAt` would stay a number over there and becomes a string
        // here. Only the app itself ever writes this field, always as an ISO
        // string, so the divergence is unreachable in practice — but it is real,
        // and the golden corpus stays away from it rather than pretending
        // otherwise.
        if JS.truthy(data["updatedAt"]) {
            base.updatedAt = JS.string(data["updatedAt"])
        }

        // `Object.assign(base.settings.goal, data.settings?.goal || {})` — a
        // shallow merge, not a rebuild. Unknown keys survive and known ones are
        // not coerced, which is why goal is a dictionary rather than a struct.
        if let incoming = data["settings"]["goal"].objectValue {
            for (k, v) in incoming { base.settings.goal[k] = v }
        }

        base.shelfOrder = data["shelfOrder"].arrayValue.map { $0.map(JS.string) } ?? []
        base.books = data["books"].arrayValue.map { $0.map(normalizeBook) } ?? []
        healPhantomGoodreadsFinishes(&base.books)
        return base
    }

    /// Convenience for the common case of a raw export or sync payload.
    public func normalize(data: Data) throws -> WireState {
        normalize(try JSONValue.parse(data))
    }

    // MARK: - Defaults

    public func defaultState() -> WireState {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: now())
        return WireState(
            version: Self.schemaVersion,
            updatedAt: ISO8601.string(from: now()),
            settings: WireSettings(goal: [
                "year": .number(Double(year)),
                "target": .number(12),
                "pagesTarget": .number(0),
                "dailyPages": .number(0),
            ]),
            shelfOrder: [],
            books: []
        )
    }

    // MARK: - Books

    private func normalizeBook(_ b: JSONValue) -> WireBook {
        WireBook(
            id: JS.stringOr(b["id"], makeID()),
            title: JS.stringOr(b["title"], "Untitled"),
            author: JS.stringOr(b["author"], ""),
            totalPages: JS.numberOrZero(b["totalPages"]),
            coverUrl: JS.stringOr(b["coverUrl"], ""),
            isbn: JS.stringOr(b["isbn"], ""),
            review: JS.stringOr(b["review"], ""),
            description: JS.stringOr(b["description"], ""),
            // Goodreads "bookshelves" are folders, not genres. They are filtered
            // out on every load, so old junk heals itself rather than needing a
            // migration.
            tags: (b["tags"].arrayValue ?? [])
                .map { JS.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !Self.isJunkTag($0) },
            collections: (b["collections"].arrayValue ?? [])
                .map { JS.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            format: BookFormat(rawValue: b["format"].stringValue ?? "") ?? .physical,
            seriesName: JS.stringOr(b["seriesName"], ""),
            // Kept when 0 — book #0 of a series is meaningless, but the source
            // guards on `!= null && !== ""`, not truthiness, and matching it is
            // the job.
            seriesNumber: JS.numberIfNotNullOrEmpty(b["seriesNumber"]),
            publishedYear: JS.numberIfTruthy(b["publishedYear"]),
            quotes: (b["quotes"].arrayValue ?? []).map { q in
                WireQuote(
                    id: JS.stringOr(q["id"], makeID()),
                    text: JS.stringOr(q["text"], ""),
                    // Quotes guard on `!= null` alone, so an empty-string page
                    // lands on 0 here where journal and vocab give nil. Not a
                    // typo in the source — or if it is, it is one both clients
                    // have to make.
                    page: JS.numberIfNotNull(q["page"]),
                    at: JS.stringOrNil(q["at"])
                )
            },
            // `Number(b.readCount) || 1` — a stored 0 becomes 1. Every book has
            // been read at least once by the time it has a read count.
            readCount: JS.numberOr(b["readCount"], 1),
            finishHistory: (b["finishHistory"].arrayValue ?? []).map { f in
                // Early versions stored a bare date string per finish.
                if case .string(let s) = f {
                    return WireFinishRecord(date: s, rating: nil)
                }
                return WireFinishRecord(
                    date: JS.stringOrNil(f["date"]),
                    rating: JS.numberIfTruthy(f["rating"])
                )
            },
            journal: (b["journal"].arrayValue ?? []).map { j in
                WireJournalEntry(
                    id: JS.stringOr(j["id"], makeID()),
                    date: JS.stringOr(j["date"], ISO8601.string(from: now())),
                    page: JS.numberIfNotNullOrEmpty(j["page"]),
                    text: JS.stringOr(j["text"], "")
                )
            },
            characters: (b["characters"].arrayValue ?? []).map { c in
                WireCharacter(
                    id: JS.stringOr(c["id"], makeID()),
                    name: JS.stringOr(c["name"], ""),
                    desc: JS.stringOr(c["desc"], "")
                )
            },
            vocab: (b["vocab"].arrayValue ?? []).map { v in
                WireVocabEntry(
                    id: JS.stringOr(v["id"], makeID()),
                    word: JS.stringOr(v["word"], ""),
                    def: JS.stringOr(v["def"], ""),
                    page: JS.numberIfNotNullOrEmpty(v["page"])
                )
            },
            // A bookmark exists only if it says something: a note, or a page.
            // An empty `{}` is dropped rather than stored as a blank bookmark.
            bookmark: {
                let bm = b["bookmark"]
                guard JS.truthy(bm), JS.truthy(bm["note"]) || !bm["page"].isNull else { return nil }
                return WireBookmark(
                    page: JS.numberIfNotNullOrEmpty(bm["page"]),
                    note: JS.truthy(bm["note"]) ? JS.string(bm["note"]) : "",
                    date: JS.stringOrNil(bm["date"])
                )
            }(),
            dnfReason: JS.stringOr(b["dnfReason"], ""),
            pickReason: JS.stringOr(b["pickReason"], ""),
            expectation: JS.numberIfTruthy(b["expectation"]),
            loanDue: JS.stringOr(b["loanDue"], ""),
            owned: JS.truthy(b["owned"]),
            location: JS.stringOr(b["location"], ""),
            coverTriedAt: JS.stringOrNil(b["coverTriedAt"]),
            lentTo: JS.stringOr(b["lentTo"], ""),
            lentAt: JS.stringOrNil(b["lentAt"]),
            // An unrecognised status becomes "reading", not "want": a book already
            // on the shelf with a corrupt status is more likely in progress than
            // unstarted, and the web app has always chosen this way.
            status: BookStatus(rawValue: b["status"].stringValue ?? "") ?? .reading,
            // Truthiness, so 0 stars means unrated rather than a zero rating.
            rating: JS.numberIfTruthy(b["rating"]),
            startedAt: JS.stringOrNil(b["startedAt"]),
            finishedAt: JS.stringOrNil(b["finishedAt"]),
            addedAt: JS.stringOr(b["addedAt"], ISO8601.string(from: now())),
            logs: (b["logs"].arrayValue ?? []).map { l in
                WireReadingLog(
                    id: JS.stringOr(l["id"], makeID()),
                    date: JS.stringOr(l["date"], ISO8601.string(from: now())),
                    pages: JS.numberOrZero(l["pages"]),
                    minutes: JS.numberOrZero(l["minutes"]),
                    mood: JS.stringOr(l["mood"], ""),
                    note: JS.stringOr(l["note"], "")
                )
            }
        )
    }

    // MARK: - Goodreads phantom-finish healing

    /// Heals an old import quirk: "read" books with no Goodreads *Date Read* were
    /// stamped finished-on-import-day plus a same-moment log, which inflated that
    /// year's reading goal with books actually finished years earlier.
    ///
    /// Signature: `finishedAt` within a minute of `addedAt`, plus exactly one log
    /// noted "Imported from Goodreads" at that same moment. All three must match,
    /// so a book genuinely finished on the day it was added survives.
    private func healPhantomGoodreadsFinishes(_ books: inout [WireBook]) {
        for i in books.indices {
            guard books[i].status == .finished,
                  let finishedAt = books[i].finishedAt, !finishedAt.isEmpty,
                  !books[i].addedAt.isEmpty,
                  let finished = ISO8601.date(from: finishedAt),
                  let added = ISO8601.date(from: books[i].addedAt),
                  abs(finished.timeIntervalSince(added)) <= 60,
                  books[i].logs.count == 1
            else { continue }
            let log = books[i].logs[0]
            guard log.note == "Imported from Goodreads",
                  let logDate = ISO8601.date(from: log.date),
                  abs(logDate.timeIntervalSince(finished)) <= 60
            else { continue }
            books[i].finishedAt = nil
            books[i].logs = []
        }
    }

    // MARK: - Tag filtering

    // Mirrors JUNK_TAG and SERIES_TAG in src/app.ts. Case-insensitive, anchored.
    private static let junkTag = try! NSRegularExpression(
        pattern: #"^(to-read|currently-reading|read|did-not-finish|dnf|abandoned|why-did-i(-.*)?)$"#,
        options: [.caseInsensitive]
    )
    private static let seriesTag = try! NSRegularExpression(
        pattern: #"^series?[-_: ]+(.+)$"#,
        options: [.caseInsensitive]
    )

    public static func isJunkTag(_ tag: String) -> Bool {
        let range = NSRange(tag.startIndex..., in: tag)
        return junkTag.firstMatch(in: tag, range: range) != nil
            || seriesTag.firstMatch(in: tag, range: range) != nil
    }
}
