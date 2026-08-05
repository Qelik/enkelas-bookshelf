import BookshelfCore
import SwiftUI

/// Pick the app's colour.
///
/// Swatches rather than a `Picker` of names: this is a choice about how something
/// looks, and a menu reading "Blush" tells you nothing about what you'd get. The
/// row shows every option at once so the decision is one glance, not six taps.
struct ThemeSection: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        Section {
            // Horizontal scroll rather than a wrapped grid: six swatches fit on
            // every size this ships to, and a grid would reflow into a ragged
            // second row at large Dynamic Type.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        swatch(theme)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            // The list's own insets would clip the selection ring.
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            LabeledContent("Colour", value: themes.theme.label)
        } header: {
            Text("Appearance")
        } footer: {
            Text(footer)
        }
    }

    private func swatch(_ theme: AppTheme) -> some View {
        let selected = theme == themes.theme
        return Button {
            themes.select(theme)
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(theme.color)
                    .frame(width: 42, height: 42)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.bold())
                                // Against the swatch, not the page: the tick has
                                // to stay legible on Graphite and on Blush.
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
                            .padding(-4)
                    }
                Text(theme.label)
                    .font(.caption2)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.label)
        .accessibilityValue(theme.blurb)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Says where the choice is kept, because "does my wife's phone go pink too?"
    /// is the first question anyone asks.
    private var footer: String {
        sync.isSignedIn
            ? "Saved for \(sync.account?.fullName ?? "this account") on this device — it doesn't sync, so everyone keeps their own colour."
            : "Saved on this device. Sign in and it follows your account instead."
    }
}
