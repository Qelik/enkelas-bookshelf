import BookshelfCore
import SwiftUI
import WidgetKit

/// The year's book goal, plus what today would have to look like to stay on it.
struct GoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Goal", provider: SnapshotProvider()) { entry in
            GoalView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Reading Goal")
        .description("This year's goal and whether you're on pace.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct GoalView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var hasGoal: Bool { snapshot.goalTarget > 0 }
    private var fraction: Double {
        guard snapshot.goalTarget > 0 else { return 0 }
        return min(1, Double(snapshot.goalDone) / Double(snapshot.goalTarget))
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: small
        }
    }

    @ViewBuilder
    private var small: some View {
        if hasGoal {
            VStack(alignment: .leading, spacing: 4) {
                // Text(verbatim:) — an interpolated Int gets localised, and a
                // year is not a quantity: "2 026" is not a year.
                Text(verbatim: "\(String(snapshot.goalYear)) goal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(snapshot.goalDone) of \(snapshot.goalTarget)")
                    .font(.title3.weight(.semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                ProgressView(value: fraction).tint(snapshot.accent)
                Text(pacing)
                    .font(.caption2)
                    .foregroundStyle(paceColor)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(WidgetLink.progress)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "target").font(.title3).foregroundStyle(.secondary)
                Text("No goal set").font(.caption.weight(.semibold))
                Text("Set one in Progress.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(WidgetLink.progress)
        }
    }

    private var circular: some View {
        Gauge(value: fraction) {
            Image(systemName: "target")
        } currentValueLabel: {
            Text("\(snapshot.goalDone)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetLink.progress)
    }

    private var inline: some View {
        Label(
            hasGoal ? "\(snapshot.goalDone)/\(snapshot.goalTarget) books" : "No reading goal",
            systemImage: "target"
        )
    }

    /// Books ahead or behind, rounded to whole books — "0.4 books behind" is a
    /// precision nobody acts on.
    private var pacing: String {
        guard hasGoal else { return "" }
        if snapshot.goalDone >= snapshot.goalTarget { return "Goal met 🎉" }
        let diff = snapshot.booksAhead
        let whole = Int(diff.rounded())
        if whole > 0 { return "\(whole) ahead of pace" }
        if whole < 0 { return "\(-whole) behind pace" }
        return "On pace"
    }

    private var paceColor: Color {
        guard hasGoal, snapshot.goalDone < snapshot.goalTarget else { return .secondary }
        return snapshot.booksAhead.rounded() < 0 ? .orange : .secondary
    }
}
