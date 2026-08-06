import BookshelfCore
import Charts
import SwiftUI

/// Goals, stats and achievements — the web app's "Progress" nav group.
///
/// One scrolling screen rather than sub-tabs: on a phone these are all short,
/// and three tabs would be three taps to see six numbers.
struct ProgressTabView: View {
    @Environment(BookshelfStore.self) private var store
    @Environment(\.themeAccent) private var accent
    @Environment(\.themeBackground) private var background
    @State private var editingGoal = false
    @State private var showingYearReview = false

    private var state: WireState { store.state }

    /// Derived once per change to the shelf, off the main actor.
    ///
    /// These statistics used to be read straight out of the bodies below.
    /// Each one walks every book and every session log, a body re-runs on any
    /// observed change, and there were eight calls per pass — ~200 ms on a
    /// 12,000-session shelf, on the main thread, every redraw.
    @State private var digest: ProgressDigest = .placeholder

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    goalCard
                    streakCard
                    if !digest.insights.isEmpty { insightsCard }
                    heatmapCard
                    dailyChart
                    monthlyChart
                    if !digest.genres.isEmpty { genreChart }
                    if digest.ratings.contains(where: { $0.value > 0 }) { ratingChart }
                    challengesCard
                    badgesCard
                    yearReviewCard
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .themedPage()
            .themedRows()
            .navigationTitle("Progress")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Off the main actor, and only when the shelf actually changed.
            // `updatedAt` moves on every commit, which is precisely the
            // identity this depends on.
            .task(id: store.state.updatedAt) { await refreshDigest() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit goal", systemImage: "target") { editingGoal = true }
                }
            }
            .sheet(isPresented: $editingGoal) { GoalEditorView() }
            .sheet(isPresented: $showingYearReview) {
                YearReviewView(year: Calendar.current.component(.year, from: Date()))
            }
        }
    }

    // MARK: - Goal

    /// Derive off the main actor.
    ///
    /// `WireState` is `Sendable` and every derivation is a pure function of it,
    /// so this can run at utility priority without touching the UI. Only the
    /// finished digest comes back to the main actor.
    private func refreshDigest() async {
        let state = store.state
        let fresh = await Task.detached(priority: .userInitiated) {
            ProgressDigest.make(from: state)
        }.value
        guard !Task.isCancelled else { return }
        digest = fresh
    }

    private var goalCard: some View {
        let pacing = digest.pacing
        return Card {
            HStack(spacing: 20) {
                Gauge(value: pacing.progress) {
                    EmptyView()
                } currentValueLabel: {
                    VStack(spacing: 0) {
                        Text("\(pacing.done)").font(.title2.bold())
                        if pacing.target > 0 {
                            Text("of \(pacing.target)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)

                .scaleEffect(1.15)
                .frame(width: 90, height: 90)

                VStack(alignment: .leading, spacing: 6) {
                    // String(_:), not interpolation: Text localizes an interpolated Int
                    // and renders 2026 as "2 026".
                    Text(verbatim: "\(String(pacing.year)) reading goal").font(.headline)
                    if let line = pacing.pacingDescription {
                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Button("Set a goal") { editingGoal = true }
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
            }

            if let pages = state.pagesGoal {
                meter(label: "Pages this year", done: pages.done, target: pages.target, unit: "pages")
            }
            if let daily = state.dailyGoal() {
                meter(label: "Today", done: daily.done, target: daily.target, unit: "pages")
            }
        }
    }

    private func meter(label: String, done: Int, target: Int, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(done.formatted()) / \(target.formatted()) \(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, Double(done) / Double(max(1, target))))
        }
        .padding(.top, 4)
    }

    // MARK: - Streak

    private var streakCard: some View {
        let streak = digest.streak
        return Card {
            HStack(spacing: 24) {
                stat("🔥", "\(streak.current)", "day streak")
                Divider().frame(height: 34)
                stat("🏔", "\(streak.longest)", "longest")
                Divider().frame(height: 34)
                stat("📄", Int(digest.totalPagesRead).formatted(), "pages read")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ emoji: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(emoji).font(.title3)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var insightsCard: some View {
        Card(title: "Your reading") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(digest.insights, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle").font(.caption).foregroundStyle(.tint)
                        Text(line).font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Calendar

    /// Half a year of reading at a glance. The web app's heatmap, same five
    /// shades and the same thresholds, so a day looks identical in both.
    private var heatmapCard: some View {
        let grid = digest.calendar
        let active = grid.flatMap { $0 }.compactMap { $0 }.filter { $0.pages > 0 }.count
        return Card(title: "Reading calendar", subtitle: "\(active) day\(active == 1 ? "" : "s")") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 3) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                if let day {
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(shade(day.level))
                                        .frame(width: 12, height: 12)
                                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(Int(day.pages)) pages")
                                } else {
                                    // A day in the future — kept as a spacer so
                                    // the last column doesn't shift upwards.
                                    Color.clear.frame(width: 12, height: 12)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)   // today, not six months ago
        }
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.12)
        case 1: accent.opacity(0.3)
        case 2: accent.opacity(0.5)
        case 3: accent.opacity(0.75)
        default: accent
        }
    }

    private var yearReviewCard: some View {
        Card {
            Button {
                showingYearReview = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your year in books").font(.headline).foregroundStyle(.primary)
                        Text("A card worth sharing").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Charts

    private var dailyChart: some View {
        let points = digest.pagesPerDay
        let total = Int(points.reduce(0) { $0 + $1.value })
        return Card(title: "Last 30 days", subtitle: "\(total.formatted()) pages") {
            Chart(points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Pages", point.value)
                )
                .foregroundStyle(.tint)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 140)
        }
    }

    private var monthlyChart: some View {
        let points = digest.pagesPerMonth
        return Card(title: "Last 12 months") {
            Chart(points) { point in
                BarMark(
                    x: .value("Month", point.date, unit: .month),
                    y: .value("Pages", point.value)
                )
                .foregroundStyle(.tint)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 140)
        }
    }

    private var genreChart: some View {
        let genres = digest.genres
        return Card(title: "What you read") {
            Chart(genres) { genre in
                BarMark(
                    x: .value("Books", genre.value),
                    y: .value("Genre", genre.label)
                )
                .foregroundStyle(.tint)
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text("\(genre.value)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(genres.count) * 26 + 10)
        }
    }

    private var ratingChart: some View {
        Card(title: "How you rate") {
            Chart(digest.ratings) { point in
                BarMark(
                    x: .value("Stars", point.label),
                    y: .value("Books", point.value)
                )
                .foregroundStyle(.orange)
                .cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
    }

    // MARK: - Challenges and badges

    private var challengesCard: some View {
        let challenges = digest.challenges
        return Card(title: "Challenges", subtitle: "\(challenges.filter(\.unlocked).count) of \(challenges.count)") {
            VStack(spacing: 10) {
                ForEach(challenges) { challenge in
                    HStack(spacing: 12) {
                        Text(challenge.emoji)
                            .font(.title3)
                            .opacity(challenge.unlocked ? 1 : 0.35)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(challenge.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(challenge.unlocked ? .primary : .secondary)
                            Text(challenge.detail).font(.caption).foregroundStyle(.secondary)
                            if !challenge.unlocked, challenge.target > 1 {
                                ProgressView(value: challenge.progress).tint(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if challenge.unlocked {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if challenge.target > 1 {
                            Text("\(challenge.value)/\(challenge.target)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var badgesCard: some View {
        let badges = digest.badges
        let earned = badges.filter(\.unlocked)
        return Card(title: "Badges", subtitle: "\(earned.count) of \(badges.count)") {
            NavigationLink {
                BadgesView(badges: digest.badges)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    if earned.isEmpty {
                        Text("Log some reading and they'll start unlocking.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        // The most recently reached ones, which is what someone
                        // wants to see at a glance.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(earned.suffix(10)) { badge in
                                Text(badge.emoji).font(.title2)
                            }
                        }
                    }
                    HStack {
                        Text("See all").font(.subheadline)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Every badge, earned or not — locked ones show what they'd take.
struct BadgesView: View {
    @Environment(\.themeBackground) private var background
    /// Passed in, not derived here. This used to call `badges()` *inside* the
    /// loop over groups, so a full walk of every book and session ran once per
    /// group, on every redraw.
    let badges: [Badge]

    var body: some View {
        List {
            ForEach(Badge.Group.allCases, id: \.self) { group in
                let badges = badges.filter { $0.group == group }
                if !badges.isEmpty {
                    Section(group.label) {
                        ForEach(badges) { badge in
                            HStack(spacing: 14) {
                                Text(badge.emoji)
                                    .font(.title)
                                    .opacity(badge.unlocked ? 1 : 0.3)
                                    .grayscale(badge.unlocked ? 0 : 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(badge.title).font(.subheadline.weight(.medium))
                                    Text(badge.detail).font(.caption).foregroundStyle(.secondary)
                                    if !badge.unlocked, badge.target != .max {
                                        ProgressView(value: badge.progress).tint(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if badge.unlocked {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Badges")
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Set the yearly, pages and daily goals.
struct GoalEditorView: View {
    @Environment(\.themeBackground) private var background
    @Environment(BookshelfStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var year = ""
    @State private var target = ""
    @State private var pages = ""
    @State private var daily = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Year") {
                        TextField("2026", text: $year)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Books") {
                        TextField("12", text: $target)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("How many books you'd like to finish this year.")
                }

                Section {
                    LabeledContent("Pages this year") {
                        TextField("Optional", text: $pages)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Pages a day") {
                        TextField("Optional", text: $daily)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Optional. Leave blank to hide them.")
                }
            }
            .navigationTitle("Reading goal")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let goal = store.state.settings
        year = goal.goalYear.map(String.init) ?? String(Calendar.current.component(.year, from: Date()))
        target = goal.goalTarget.map(String.init) ?? ""
        pages = (goal.goalPagesTarget ?? 0) > 0 ? String(goal.goalPagesTarget!) : ""
        daily = (goal.goalDailyPages ?? 0) > 0 ? String(goal.goalDailyPages!) : ""
    }

    private func save() {
        store.commit { state in
            // Written back as plain numbers into the same `settings.goal`
            // dictionary the web app merges — anything unknown in there is left
            // untouched.
            state.settings.goal["year"] = .number(Double(year) ?? Double(Calendar.current.component(.year, from: Date())))
            state.settings.goal["target"] = .number(Double(target) ?? 0)
            state.settings.goal["pagesTarget"] = .number(Double(pages) ?? 0)
            state.settings.goal["dailyPages"] = .number(Double(daily) ?? 0)
        }
        dismiss()
    }
}

/// The rounded container every section on this screen sits in.
struct Card<Content: View>: View {
    @Environment(\.themeSurface) private var surface
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: .rect(cornerRadius: 16))
    }
}
