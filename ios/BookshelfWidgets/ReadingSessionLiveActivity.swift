import ActivityKit
import BookshelfCore
import SwiftUI
import WidgetKit

/// The running reading session, on the Lock Screen and in the Dynamic Island.
struct ReadingSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReadingActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(gradient(context.attributes.hue))
                        .frame(width: 32, height: 46)
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // The system runs this clock; nothing has to push updates.
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.title2.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 88)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).font(.caption.weight(.semibold)).lineLimit(1)
                        if !context.attributes.author.isEmpty {
                            Text(context.attributes.author)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let progress = context.state.progress {
                        ProgressView(value: progress).tint(.white)
                    }
                }
            } compactLeading: {
                Image(systemName: "book.fill").foregroundStyle(.tint)
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
                     countsDown: false)
                    .font(.caption2.monospacedDigit())
                    // Without a width the compact region sizes to the widest
                    // string the clock will ever be and the layout jumps at
                    // 1:00:00. Fixed, so it doesn't.
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "book.fill").foregroundStyle(.tint)
            }
            .widgetURL(WidgetLink.book(context.attributes.bookID))
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<ReadingActivityAttributes>
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(gradient(context.attributes.hue))
                .frame(width: 36, height: 54)
                .overlay {
                    Image(systemName: "book.closed.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.title).font(.headline).lineLimit(1)
                if !context.attributes.author.isEmpty {
                    Text(context.attributes.author)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress = context.state.progress {
                    ProgressView(value: progress).tint(.white)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
                     countsDown: false)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 92, alignment: .trailing)
                Text("reading").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func gradient(_ hue: Int) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: Double(hue) / 360, saturation: 0.35, brightness: 0.55),
                Color(hue: Double(hue) / 360, saturation: 0.45, brightness: 0.38),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
