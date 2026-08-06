import BookshelfCore
import SwiftUI

/// Reading clubs: a handful of friends reading one book, where comments are
/// locked until you've read that far.
///
/// The spoiler gate is enforced **on the server** — you are only ever sent
/// comments at or below your own progress. Nothing here filters anything; it
/// renders what arrived and shows the count of what didn't.
struct ClubsListView: View {
    @Environment(CommunityEngine.self) private var community
    @Environment(\.themeBackground) private var background
    @Environment(\.themeAccent) private var accent
    @Binding var showingAuth: Bool

    @State private var creating = false
    @State private var joining = false

    var body: some View {
        Group {
            if !community.isSignedIn {
                ContentUnavailableView {
                    Label("Reading clubs need an account", systemImage: "person.2")
                } description: {
                    Text("Clubs are shared with a few friends, so they live on your account rather than this device.")
                } actions: {
                    Button("Sign in") { showingAuth = true }.buttonStyle(.borderedProminent)
                }
            } else if let error = community.errorMessage, community.clubs.isEmpty {
                // Checked *before* the empty state: a request that failed also
                // leaves the list empty, and "No clubs yet" then quietly claims
                // the server answered when it never did. That is how a dead
                // session and a server that isn't running both came to look
                // like someone simply having no clubs.
                ContentUnavailableView {
                    Label("Couldn't load your clubs", systemImage: "person.2.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await community.loadClubs() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if community.clubs.isEmpty {
                ContentUnavailableView {
                    Label("No clubs yet", systemImage: "person.2")
                } description: {
                    Text("Read a book alongside up to five friends. Comments stay hidden until everyone reaches that point.")
                } actions: {
                    VStack(spacing: 10) {
                        Button("Start a club") { creating = true }.buttonStyle(.borderedProminent)
                        Button("Join with a code") { joining = true }
                    }
                }
            } else {
                List {
                    ForEach(community.clubs) { club in
                        NavigationLink {
                            ClubDetailView(clubID: club.id)
                        } label: {
                            row(club)
                        }
                        .themedPlainRows()
                    }
                    Section {
                        Button("Start a club", systemImage: "plus") { creating = true }
                        Button("Join with a code", systemImage: "person.badge.plus") { joining = true }
                    }
                }
            }
        }
        .task { await community.loadClubs() }
        .refreshable { await community.loadClubs() }
        .sheet(isPresented: $creating) { CreateClubView() }
        .sheet(isPresented: $joining) { JoinClubView() }
    }

    private func row(_ club: Club) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(club.title).font(.headline)
            if let author = club.book_author, !author.isEmpty {
                Text(author).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label("\(club.memberCount)", systemImage: "person.2")
                Label("\(club.myProgress)%", systemImage: "book")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if club.memberCount > 0 {
                // Everyone's position at a glance — the thing that makes a club
                // feel like reading together rather than alone.
                HStack(spacing: 4) {
                    ForEach(club.members ?? []) { member in
                        ProgressView(value: Double(member.progress_pct) / 100)
                            .frame(maxWidth: 40)
                            .tint(member.uid == community.myUID ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ClubDetailView: View {
    @Environment(\.themeBackground) private var background
    @Environment(CommunityEngine.self) private var community
    @Environment(\.dismiss) private var dismiss

    let clubID: String

    @State private var detail: ClubDetail?
    @State private var loadError: String?
    @State private var draft = ""
    @State private var progress: Double = 0
    @State private var socket: ClubSocket?
    @State private var reporting: ClubComment?
    @State private var showingMembers = false
    @State private var confirmingLeave = false
    @State private var notice: String?

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView("Couldn't open this club", systemImage: "person.2.slash",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .themedPage()
        .navigationTitle(detail?.club.title ?? "Club")
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Members", systemImage: "person.2") { showingMembers = true }
                    if let code = detail?.joinCode {
                        ShareLink(item: "Join my reading club with the code \(code)") {
                            Label("Share invite code", systemImage: "square.and.arrow.up")
                        }
                    }
                    Divider()
                    Button("Leave club", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmingLeave = true
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { socket?.disconnect() }
        .onChange(of: socket?.revision) { _, _ in Task { await load(quiet: true) } }
        .sheet(isPresented: $showingMembers) {
            if let detail { MembersView(members: detail.members, myUID: community.myUID) }
        }
        .sheet(item: $reporting) { comment in
            ReportView(what: "comment") { reason, detail in
                let hidden = await community.report(clubID: clubID, comment: comment, reason: reason, detail: detail)
                notice = hidden
                    ? "Thanks — that comment has been hidden while we review it."
                    : "Thanks. We review reports within 24 hours."
            }
        }
        .confirmationDialog("Leave this club?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task { await community.leave(clubID: clubID); dismiss() }
            }
        } message: {
            // Say what survives, because it isn't obvious.
            Text("You'll stop seeing new comments. What you've already written stays for the others.")
        }
        .alert("Reported", isPresented: .constant(notice != nil), presenting: notice) { _ in
            Button("OK") { notice = nil }
        } message: { Text($0) }
    }

    @ViewBuilder
    private func content(_ detail: ClubDetail) -> some View {
        VStack(spacing: 0) {
            progressBar(detail)
            Divider()
            commentList(detail)
            Divider()
            composer(detail)
        }
    }

    private func progressBar(_ detail: ClubDetail) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("You're \(Int(progress))% through")
                    .font(.subheadline)
                Spacer()
                if detail.lockedAhead > 0 {
                    // The count is the only thing the server will say about
                    // comments past your progress — never the content.
                    Label("\(detail.lockedAhead) ahead", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: $progress, in: 0...100, step: 1) { editing in
                if !editing { Task { await saveProgress() } }
            }
            Text("Comments unlock as you move this forward. It only ever goes up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func commentList(_ detail: ClubDetail) -> some View {
        if detail.comments.isEmpty {
            ContentUnavailableView {
                Label(detail.lockedAhead > 0 ? "Nothing unlocked yet" : "No comments yet",
                      systemImage: detail.lockedAhead > 0 ? "lock" : "bubble.left")
            } description: {
                Text(detail.lockedAhead > 0
                     ? "There are \(detail.lockedAhead) comments further into the book. Move your progress up as you read to unlock them."
                     : "Say something about where you've got to.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(detail.comments) { comment in
                    commentRow(comment)
                        .themedPlainRows()
                }
            }
            .listStyle(.plain)
            .themedPage()
        }
    }

    private func commentRow(_ comment: ClubComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.name).font(.subheadline.weight(.semibold))
                Text("at \(comment.pos_pct)%").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let date = comment.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(comment.body)

            HStack(spacing: 10) {
                ForEach(["❤️", "🤯", "😂", "😢", "👀"], id: \.self) { emoji in
                    let count = comment.reactions?.counts?[emoji] ?? 0
                    let mine = comment.reactions?.mine?.contains(emoji) ?? false
                    Button {
                        Task {
                            await community.react(clubID: clubID, commentID: comment.id, emoji: emoji)
                            await load(quiet: true)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(emoji).font(.caption)
                            if count > 0 { Text("\(count)").font(.caption2) }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(mine ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary),
                                    in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing) {
            if comment.uid != community.myUID {
                Button("Report", systemImage: "flag") { reporting = comment }.tint(.orange)
            }
        }
    }

    private func composer(_ detail: ClubDetail) -> some View {
        HStack(spacing: 10) {
            TextField("Say something at \(Int(progress))%…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button("Post", systemImage: "arrow.up.circle.fill") {
                Task { await post() }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func load(quiet: Bool = false) async {
        do {
            let fresh = try await community.detail(clubID: clubID)
            detail = fresh
            // Only adopt the server's progress on first load — otherwise a
            // refresh mid-drag would yank the slider back under the user.
            if !quiet { progress = Double(fresh.me.progress_pct) }
            if socket == nil {
                let s = community.liveUpdates(clubID: clubID)
                socket = s
                s.connect()
            }
        } catch {
            if !quiet { loadError = error.localizedDescription }
        }
    }

    private func saveProgress() async {
        try? await community.setProgress(clubID: clubID, percent: Int(progress))
        await load(quiet: true)
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            try await community.post(clubID: clubID, body: body, atPercent: Int(progress))
            draft = ""
            await load(quiet: true)
        } catch {
            notice = error.localizedDescription
        }
    }
}

struct MembersView: View {
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeAccent) private var accent
    let members: [ClubMember]
    let myUID: String?

    var body: some View {
        NavigationStack {
            List(members.sorted { $0.progress_pct > $1.progress_pct }) { member in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(member.uid == myUID ? "\(member.name) (you)" : member.name)
                            .font(.subheadline.weight(member.uid == myUID ? .semibold : .regular))
                        if member.isHost {
                            Text("host").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                        Spacer()
                        Text("\(member.progress_pct)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(member.progress_pct) / 100)
                        .tint(member.uid == myUID ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                }
                .padding(.vertical, 2)
            }
            .themedPage()
            .navigationTitle("Where everyone is")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct CreateClubView: View {
    @Environment(\.themeBackground) private var background
    @Environment(CommunityEngine.self) private var community
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var pages = ""
    @State private var busy = false
    @State private var code: String?

    var body: some View {
        NavigationStack {
            Form {
                if let code {
                    Section {
                        VStack(spacing: 10) {
                            Text("Share this code").font(.subheadline).foregroundStyle(.secondary)
                            Text(code)
                                .font(.title.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                            ShareLink(item: "Join my reading club with the code \(code)") {
                                Label("Share invite", systemImage: "square.and.arrow.up")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } footer: {
                        Text("Up to five friends can join with it.")
                    }
                } else {
                    Section("What are you reading together?") {
                        TextField("Title", text: $title)
                        TextField("Author", text: $author)
                        LabeledContent("Pages") {
                            TextField("Optional", text: $pages)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                    }
                    if !store.state.reading.isEmpty {
                        Section("From your shelf") {
                            ForEach(store.state.reading, id: \.id) { book in
                                Button {
                                    title = book.title
                                    author = book.author
                                    pages = book.totalPages > 0 ? String(Int(book.totalPages)) : ""
                                } label: {
                                    Text(book.title).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }
            .themedPage()
            .navigationTitle("Start a club")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(code == nil ? "Cancel" : "Done") { dismiss() }
                }
                if code == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() } else {
                            Button("Create") { Task { await create() } }
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        guard let clubID = await community.createClub(
            title: title.trimmingCharacters(in: .whitespaces),
            author: author.trimmingCharacters(in: .whitespaces),
            totalPages: Int(pages)
        ) else { return }
        // Show the code instead of dismissing: a club nobody can join isn't a
        // club, and this is the one moment the code is actually needed.
        code = try? await community.detail(clubID: clubID).joinCode
    }
}

struct JoinClubView: View {
    @Environment(\.themeBackground) private var background
    @Environment(CommunityEngine.self) private var community
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("8-letter code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                } footer: {
                    Text("Ask whoever started the club for their invite code.")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.footnote)
                }
            }
            .themedPage()
            .navigationTitle("Join a club")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Join") { Task { await join() } }
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                    }
                }
            }
        }
    }

    private func join() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        if await community.joinClub(code: code.trimmingCharacters(in: .whitespaces)) != nil {
            dismiss()
        } else {
            errorMessage = community.errorMessage ?? "That code didn't work."
        }
    }
}
