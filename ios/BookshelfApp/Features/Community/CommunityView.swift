import BookshelfCore
import SwiftUI

/// The shared recommendation board and reading clubs.
///
/// Public, user-generated content — so report and block are first-class here,
/// not buried. That's both an App Store requirement (guideline 1.2) and the
/// minimum for a board strangers can post to.
struct CommunityView: View {
    @Environment(CommunityEngine.self) private var community
    @Environment(\.themeBackground) private var background
    @Environment(BookshelfStore.self) private var store
    @Environment(SyncEngine.self) private var sync

    enum Section: String, CaseIterable, Identifiable {
        case board = "Board", clubs = "Clubs"
        var id: String { rawValue }
    }

    @State private var section: Section = .board
    @State private var hideRead = true
    @State private var category: String?
    @State private var recommending = false
    @State private var reporting: Recommendation?
    @State private var showingAuth = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .board: boardList
                case .clubs: ClubsListView(showingAuth: $showingAuth)
                }
            }
            // spacing: 0 — the default leaves an unpainted gap in the safe area
            // under the picker. See the note in ShelfView.
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                // `.bar` is the system's material, which stays grey whatever the
                // theme — a strip of white between the nav bar and the board.
                .background(background)
            }
            .themedPage()
            .navigationTitle("Community")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if section == .board {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                            Toggle("Hide books I've read", isOn: $hideRead)
                            if !community.categories.isEmpty {
                                Picker("Category", selection: $category) {
                                    Text("All").tag(String?.none)
                                    ForEach(community.categories, id: \.self) {
                                        Text($0).tag(String?.some($0))
                                    }
                                }
                            }
                            if !community.blockedUIDs.isEmpty {
                                NavigationLink("Blocked readers (\(community.blockedUIDs.count))") {
                                    BlockedListView()
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Recommend a book", systemImage: "plus") {
                            if community.isSignedIn { recommending = true } else { showingAuth = true }
                        }
                    }
                }
            }
            .task { await community.loadBoard() }
            .refreshable { await community.loadBoard() }
            .sheet(isPresented: $recommending) { RecommendView() }
            .sheet(isPresented: $showingAuth) { AuthView() }
            .sheet(item: $reporting) { rec in
                ReportView(what: "recommendation") { reason, detail in
                    let hidden = await community.report(rec, reason: reason, detail: detail)
                    notice = hidden
                        ? "Thanks — enough people reported this that it's been hidden while we review it."
                        : "Thanks. We review reports within 24 hours."
                }
            }
            .alert("Reported", isPresented: .constant(notice != nil), presenting: notice) { _ in
                Button("OK") { notice = nil }
            } message: { Text($0) }
        }
    }

    // MARK: - Board

    private var visible: [Recommendation] {
        community.visibleRecommendations(hidingRead: hideRead, shelf: store.state, category: category)
    }

    @ViewBuilder
    private var boardList: some View {
        if community.isLoading && community.recommendations.isEmpty {
            ProgressView().themedState()
        } else if let error = community.errorMessage, community.recommendations.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load the board", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await community.loadBoard() } }
            }
                .themedState()
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "star")
            } description: {
                Text(hideRead && !community.recommendations.isEmpty
                     ? "Everything recommended so far is already on your shelf. Turn off “Hide books I've read” to see them."
                     : "Be the first to recommend something.")
            } actions: {
                Button("Recommend a book") {
                    if community.isSignedIn { recommending = true } else { showingAuth = true }
                }
                .buttonStyle(.borderedProminent)
            }
                .themedState()
        } else {
            List {
                ForEach(visible) { rec in
                    RecommendationRow(rec: rec, onReport: { reporting = rec })
                        .themedPlainRows()
                }
                if community.boardIsCapped {
                    // Say so rather than implying the board is this small.
                    Text("Showing the most recent recommendations.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }
}

struct RecommendationRow: View {
    @Environment(CommunityEngine.self) private var community
    let rec: Recommendation
    var onReport: () -> Void

    @State private var confirmingBlock = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: rec.cover_url.flatMap(URL.init(string:))) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: 44, height: 66)
            .clipShape(.rect(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title).font(.headline).lineLimit(2)
                if !rec.author.isEmpty {
                    Text(rec.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let note = rec.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(rec.category)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                    if let name = rec.created_name, !name.isEmpty {
                        Text("by \(name)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                voteButton(1, "hand.thumbsup", count: rec.up ?? 0)
                voteButton(-1, "hand.thumbsdown", count: rec.down ?? 0)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if rec.mine == true {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    Task { await community.deleteRecommendation(rec) }
                }
            } else {
                Button("Report", systemImage: "flag", action: onReport).tint(.orange)
                Button("Block", systemImage: "hand.raised") { confirmingBlock = true }.tint(.red)
            }
        }
        .contextMenu {
            if rec.mine != true {
                Button("Report…", systemImage: "flag", action: onReport)
                Button("Block this reader", systemImage: "hand.raised", role: .destructive) {
                    confirmingBlock = true
                }
            }
        }
        .confirmationDialog(
            "Block \(rec.created_name ?? "this reader")?",
            isPresented: $confirmingBlock, titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let uid = rec.created_by { Task { await community.block(uid: uid) } }
            }
        } message: {
            // Say exactly what it does: silent and one-directional is the part
            // people worry about.
            Text("You won't see anything they post. They aren't told, and nothing they've written is deleted.")
        }
    }

    private func voteButton(_ value: Int, _ symbol: String, count: Int) -> some View {
        Button {
            Task { await community.vote(rec, value) }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: rec.myVote == value ? "\(symbol).fill" : symbol)
                Text("\(count)").font(.caption2.monospacedDigit())
            }
            .foregroundStyle(rec.myVote == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!community.isSignedIn)
    }
}

/// The report sheet. Deliberately plain: a reason, an optional detail, and a
/// clear statement of what happens next.
struct ReportView: View {
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss
    let what: String
    var onSubmit: (ReportReason, String) async -> Void

    @State private var reason: ReportReason = .spam
    @State private var detail = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What's wrong with this \(what)?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("Anything else we should know? (optional)", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Reports are reviewed within 24 hours. Content reported by several readers is hidden straight away.")
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Report")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Send") {
                            busy = true
                            Task {
                                await onSubmit(reason, detail)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Everyone this reader has blocked, so it can be undone.
struct BlockedListView: View {
    @Environment(\.themeBackground) private var background
    @Environment(CommunityEngine.self) private var community

    var body: some View {
        List {
            if community.blockedUIDs.isEmpty {
                ContentUnavailableView("Nobody blocked", systemImage: "hand.raised")
                    .themedState()
            } else {
                Section {
                    ForEach(Array(community.blockedUIDs).sorted(), id: \.self) { uid in
                        HStack {
                            // The server never sends a blocked person's name, so
                            // there's nothing to show but the id they were
                            // blocked by.
                            Text(uid.prefix(8) + "…").font(.callout.monospaced())
                            Spacer()
                            Button("Unblock") { Task { await community.unblock(uid: uid) } }
                                .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    Text("Unblocking makes their posts visible to you again.")
                }
            }
        }
        .themedPage()
        .navigationTitle("Blocked")
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Post a recommendation to the shared board.
struct RecommendView: View {
    @Environment(\.themeBackground) private var background
    @Environment(CommunityEngine.self) private var community
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var category = "General"
    @State private var note = ""
    @State private var isbn = ""
    @State private var coverUrl = ""
    @State private var busy = false
    @State private var errorMessage: String?

    /// Books already finished, offered as a starting point — most
    /// recommendations are for something the reader just enjoyed.
    private var finished: [WireBook] {
        store.state.books.filter { $0.status == .finished }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !finished.isEmpty, title.isEmpty {
                    Section("From your shelf") {
                        ForEach(finished.prefix(5), id: \.id) { book in
                            Button {
                                title = book.title
                                author = book.author
                                isbn = book.isbn
                                coverUrl = book.coverUrl
                                category = book.tags.first ?? "General"
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(book.title).foregroundStyle(.primary)
                                    if !book.author.isEmpty {
                                        Text(book.author).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("Category", text: $category)
                }

                Section {
                    TextField("Why should someone read it?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    // Say it before the server refuses it.
                    Text("Please leave out web links — just tell people about the book.")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.footnote)
                }
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Recommend")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Post") { Task { await submit() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        let ok = await community.recommend(
            title: title.trimmingCharacters(in: .whitespaces),
            author: author.trimmingCharacters(in: .whitespaces),
            category: category.trimmingCharacters(in: .whitespaces),
            note: note, isbn: isbn, coverUrl: coverUrl
        )
        if ok { dismiss() } else { errorMessage = community.errorMessage }
    }
}
