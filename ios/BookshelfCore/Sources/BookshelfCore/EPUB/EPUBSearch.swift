import Foundation

/// Full-book search, ported from `searchBook()` in `src/reader.ts`.
///
/// Searches the *stripped text* of each chapter, not its markup — otherwise
/// every hit for "class" would land inside an HTML attribute, and a phrase
/// spanning a `<em>` would never match at all.
public struct EPUBSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(chapter)-\(offset)" }
    /// Spine index.
    public let chapter: Int
    public let chapterTitle: String?
    /// Character offset into the chapter's stripped text — the same coordinate
    /// space highlights use, so a result can be jumped to precisely.
    public let offset: Int
    /// The matched text, in its original casing.
    public let match: String
    /// A window of surrounding words for the results list.
    public let snippet: String
    /// 0…1 through the chapter, for showing roughly where a hit sits.
    public let fraction: Double
}

public extension EPUBPackage {

    /// Cap the results. A one-letter query in a novel matches tens of thousands
    /// of times; nobody scrolls that, and building the list would stall the app.
    static let searchLimit = 80

    /// Case- and diacritic-insensitive search across the whole book.
    ///
    /// `cachedText` lets the caller pass chapter text it already has (the reader
    /// computes it for the progress estimate), so searching a long book doesn't
    /// decompress and strip every chapter a second time.
    func search(
        _ query: String,
        cachedText: [String]? = nil
    ) -> (results: [EPUBSearchResult], truncated: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // One or two characters matches essentially everything; the results are
        // noise and the work is wasted.
        guard needle.count >= 2 else { return ([], false) }

        var out: [EPUBSearchResult] = []
        for index in spine.indices {
            let text = cachedText?[safe: index] ?? (try? plainText(forChapter: index)) ?? ""
            guard !text.isEmpty else { continue }

            var searchStart = text.startIndex
            while let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
            ) {
                if out.count >= Self.searchLimit { return (out, true) }

                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                out.append(EPUBSearchResult(
                    chapter: index,
                    chapterTitle: spine[index].title,
                    offset: offset,
                    match: String(text[range]),
                    snippet: Self.snippet(in: text, around: range),
                    fraction: Double(offset) / Double(max(1, text.count))
                ))

                // Advance past this match, never by zero — a needle that somehow
                // matched an empty range would spin forever.
                searchStart = text.index(range.lowerBound, offsetBy: max(1, needle.count), limitedBy: text.endIndex)
                    ?? text.endIndex
                if searchStart >= text.endIndex { break }
            }
        }
        return (out, false)
    }

    /// Roughly 40 characters before and 60 after, trimmed to whole words so a
    /// snippet doesn't start mid-syllable.
    static func snippet(in text: String, around range: Range<String.Index>) -> String {
        let before = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let after = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex

        var slice = String(text[before..<after])
        if before > text.startIndex, let space = slice.firstIndex(of: " ") {
            slice = String(slice[slice.index(after: space)...])
        }
        if after < text.endIndex, let space = slice.lastIndex(of: " ") {
            slice = String(slice[..<space])
        }
        slice = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        return (before > text.startIndex ? "…" : "") + slice + (after < text.endIndex ? "…" : "")
    }
}

// MARK: - Annotations

@MainActor
public extension EPUBLibrary {

    /// Bookmark the current spot. Toggles: bookmarking the same place twice
    /// removes it, which is what a bookmark ribbon does.
    @discardableResult
    func toggleBookmark(
        recordID: String, chapter: Int, progress: Double,
        label: String, snippet: String, now: Date = Date()
    ) -> Bool {
        guard var record = self.record(id: recordID) else { return false }
        // "Same place" is generous on purpose — a bookmark is a page, and the
        // exact fraction shifts with font size.
        if let existing = record.bookmarks.firstIndex(where: {
            $0.chapter == chapter && abs($0.progress - progress) < 0.02
        }) {
            record.bookmarks.remove(at: existing)
            update(record)
            return false
        }
        record.bookmarks.append(EPUBRecord.Bookmark(
            id: UUID().uuidString.lowercased(),
            chapter: chapter,
            progress: progress,
            label: label,
            snippet: snippet,
            addedAt: ISO8601.string(from: now)
        ))
        // Reading order, so the list matches the book.
        record.bookmarks.sort { $0.chapter == $1.chapter ? $0.progress < $1.progress : $0.chapter < $1.chapter }
        update(record)
        return true
    }

    func isBookmarked(recordID: String, chapter: Int, progress: Double) -> Bool {
        record(id: recordID)?.bookmarks.contains {
            $0.chapter == chapter && abs($0.progress - progress) < 0.02
        } ?? false
    }

    func removeBookmark(recordID: String, bookmarkID: String) {
        guard var record = self.record(id: recordID) else { return }
        record.bookmarks.removeAll { $0.id == bookmarkID }
        update(record)
    }

    /// Highlights are stored as **character offsets into the chapter's text**,
    /// not pixels or DOM paths. That is what makes them survive a font-size
    /// change, a theme switch, or a different screen — the text doesn't move in
    /// that coordinate space even though every pixel does.
    @discardableResult
    func addHighlight(
        recordID: String, chapter: Int, start: Int, end: Int, text: String, now: Date = Date()
    ) -> EPUBRecord.Highlight? {
        guard var record = self.record(id: recordID), end > start else { return nil }
        let highlight = EPUBRecord.Highlight(
            id: UUID().uuidString.lowercased(),
            chapter: chapter,
            start: start,
            end: end,
            text: text,
            addedAt: ISO8601.string(from: now)
        )
        record.highlights.append(highlight)
        record.highlights.sort { $0.chapter == $1.chapter ? $0.start < $1.start : $0.chapter < $1.chapter }
        update(record)
        return highlight
    }

    func removeHighlight(recordID: String, highlightID: String) {
        guard var record = self.record(id: recordID) else { return }
        record.highlights.removeAll { $0.id == highlightID }
        update(record)
    }

    func highlights(recordID: String, chapter: Int) -> [EPUBRecord.Highlight] {
        record(id: recordID)?.highlights.filter { $0.chapter == chapter } ?? []
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
