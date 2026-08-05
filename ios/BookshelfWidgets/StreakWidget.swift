import BookshelfCore
import SwiftUI
import WidgetKit

/// Days in a row, and whether today is still open.
///
/// The point of this one on a Lock Screen is the *gap*: a streak you've already
/// kept today is a fact, a streak you haven't is a nudge, and they should not
/// look the same.
struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Streak", provider: SnapshotProvider()) { entry in
            StreakView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Reading Streak")
        .description("Days in a row, and whether you've read today.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct StreakView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var streak: Int { entry.snapshot.streakCurrent }
    private var readToday: Bool { entry.snapshot.readToday }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: readToday ? "flame.fill" : "flame")
                .font(.title2)
                .foregroundStyle(readToday ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            Text(streak == 1 ? "1 day" : "\(streak) days")
                .font(.title2.weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetLink.progress)
    }

    private var circular: some View {
        // Against the day's own target where there is one, so the ring means
        // "today", matching what the number below it says.
        Gauge(value: ringValue) {
            Image(systemName: readToday ? "flame.fill" : "flame")
        } currentValueLabel: {
            Text("\(streak)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetLink.progress)
    }

    private var inline: some View {
        Label(
            readToday ? "\(streak)-day streak" : "\(streak)-day streak · not yet today",
            systemImage: readToday ? "flame.fill" : "flame"
        )
    }

    private var ringValue: Double {
        guard let target = entry.snapshot.pagesTargetToday, target > 0 else {
            return readToday ? 1 : 0
        }
        return min(1, Double(entry.snapshot.pagesToday) / Double(target))
    }

    private var caption: String {
        if streak == 0 { return "Read something to start one." }
        if readToday { return "Kept today. Longest: \(entry.snapshot.streakLongest)." }
        return "Read today to keep it."
    }
}
