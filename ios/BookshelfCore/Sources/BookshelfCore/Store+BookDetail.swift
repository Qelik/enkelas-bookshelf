import Foundation

/// The per-book actions behind the detail screen — finishing, re-reading, giving
/// up, lending, and the four kinds of note a reader keeps.
///
/// Ported from `saveFinish` / `saveDnf` / `saveLend` / `saveBookmark` in
/// `src/app.ts`. These write fields the web app also writes, so the behaviour has
/// to match: a book finished on the phone must look identical to one finished in
/// the browser, or the next sync makes one of them look wrong.
@MainActor
public extension BookshelfStore {

    // MARK: - Finishing

    /// Mark a book finished.
    ///
    /// Two details are ported deliberately:
    ///
    /// - If the logged pages fall short of the total, a **top-up log** makes up
    ///   the difference. Otherwise finishing a 400-page book you only logged 120
    ///   pages of leaves 280 pages missing from every total and chart forever.
    /// - `finishHistory` and the bookmark are only touched on a *first* finish,
    ///   so re-saving a finished book doesn't stack duplicate history entries.
    func finish(bookID: String, rating: Double?, on date: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let wasFinished = state.books[i].status == .finished
            let stamp = ISO8601.string(from: date)

            state.books[i].status = .finished
            state.books[i].finishedAt = stamp
            if state.books[i].startedAt == nil { state.books[i].startedAt = stamp }
            state.books[i].rating = rating ?? state.books[i].rating

            let read = state.books[i].pagesRead
            let total = state.books[i].totalPages
            if total > 0, read < total {
                state.books[i].logs.append(WireReadingLog(
                    id: UUID().uuidString.lowercased(),
                    date: stamp,
                    pages: total - read,
                    minutes: 0,
                    mood: "",
                    note: "Finished the book"
                ))
            }

            if !wasFinished {
                state.books[i].finishHistory.append(
                    WireFinishRecord(date: stamp, rating: state.books[i].rating)
                )
                // The journey's over — no need to keep your place.
                state.books[i].bookmark = nil
            }
        }
    }

    /// Finish a re-read. Bumps `readCount` and appends to `finishHistory` without
    /// touching the page logs — a re-read isn't new pages on the same copy, and
    /// counting them again would double the year's totals.
    func finishReread(bookID: String, rating: Double?, on date: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let stamp = ISO8601.string(from: date)
            state.books[i].readCount = max(1, state.books[i].readCount) + 1
            state.books[i].status = .finished
            state.books[i].finishedAt = stamp
            state.books[i].finishHistory.append(WireFinishRecord(date: stamp, rating: rating))
            // Each read is rated on its own; only overwrite the headline rating
            // when this read was actually rated.
            if let rating { state.books[i].rating = rating }
        }
    }

    func markDidNotFinish(bookID: String, reason: String, on date: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].status = .dnf
            // Keep an existing date: giving up on a book you already shelved
            // shouldn't move when that happened.
            if state.books[i].finishedAt == nil {
                state.books[i].finishedAt = ISO8601.string(from: date)
            }
            state.books[i].dnfReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            state.books[i].bookmark = nil
        }
    }

    // MARK: - Bookmark

    /// Where you left off. A bookmark with neither a page nor a note is nothing,
    /// so saving one empty clears it instead of storing a blank.
    func setBookmark(bookID: String, page: Double?, note: String, on date: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard page != nil || !trimmed.isEmpty else {
                state.books[i].bookmark = nil
                return
            }
            state.books[i].bookmark = WireBookmark(
                page: page, note: trimmed, date: ISO8601.string(from: date)
            )
        }
    }

    func clearBookmark(bookID: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].bookmark = nil
        }
    }

    // MARK: - Lending

    /// `lentTo`/`lentAt` is a book *you* lent out. Distinct from `loanDue`, which
    /// is a library book you borrowed and have to give back.
    func lend(bookID: String, to person: String, on date: Date = Date()) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            state.books[i].lentTo = name
            state.books[i].lentAt = ISO8601.string(from: date)
        }
    }

    func markReturned(bookID: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].lentTo = ""
            state.books[i].lentAt = nil
        }
    }

    func setLoanDue(bookID: String, date: Date?) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].loanDue = date.map { ISO8601.string(from: $0).prefix(10).description } ?? ""
        }
    }

    // MARK: - Notes

    func addQuote(bookID: String, text: String, page: Double?, on date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].quotes.append(WireQuote(
                id: UUID().uuidString.lowercased(),
                text: trimmed,
                page: page,
                at: ISO8601.string(from: date)
            ))
        }
    }

    func addJournalEntry(bookID: String, text: String, page: Double?, on date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].journal.append(WireJournalEntry(
                id: UUID().uuidString.lowercased(),
                date: ISO8601.string(from: date),
                page: page,
                text: trimmed
            ))
        }
    }

    func addCharacter(bookID: String, name: String, description: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].characters.append(WireCharacter(
                id: UUID().uuidString.lowercased(),
                name: trimmed,
                desc: description.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }

    func addVocab(bookID: String, word: String, definition: String, page: Double?) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            state.books[i].vocab.append(WireVocabEntry(
                id: UUID().uuidString.lowercased(),
                word: trimmed,
                def: definition.trimmingCharacters(in: .whitespacesAndNewlines),
                page: page
            ))
        }
    }

    /// One remover for every note list, so the detail screen doesn't need four
    /// near-identical delete paths.
    enum NoteKind { case quote, journal, character, vocab }

    func deleteNote(_ kind: NoteKind, bookID: String, noteID: String) {
        commit { state in
            guard let i = state.books.firstIndex(where: { $0.id == bookID }) else { return }
            switch kind {
            case .quote: state.books[i].quotes.removeAll { $0.id == noteID }
            case .journal: state.books[i].journal.removeAll { $0.id == noteID }
            case .character: state.books[i].characters.removeAll { $0.id == noteID }
            case .vocab: state.books[i].vocab.removeAll { $0.id == noteID }
            }
        }
    }
}

public extension WireBook {
    var isLentOut: Bool { !lentTo.isEmpty }

    /// How long the book has been out. The web app pills this amber past 45 days.
    func daysLent(now: Date = Date()) -> Int? {
        guard isLentOut, let since = lentAt.flatMap(ISO8601.date(from:)) else { return nil }
        return max(0, Int(now.timeIntervalSince(since) / 86400))
    }

    var loanDueDate: Date? {
        guard !loanDue.isEmpty else { return nil }
        return ISO8601.date(from: loanDue) ?? ISO8601.date(from: loanDue + "T12:00:00.000Z")
    }

    /// Total notes of every kind, for the detail screen's section headers.
    var noteCount: Int { quotes.count + journal.count + characters.count + vocab.count }
}
