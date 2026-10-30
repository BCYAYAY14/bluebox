import DesignSystem
import Domain
import SkipSegments
import SwiftUI

/// Settings › Player › Always Skipping: the current profile's shows that skip
/// their intro, recap or credits without asking ("Always for this show" in
/// the player). Each part can be turned off here, or the whole show removed.
struct AlwaysSkipListPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @State private var names: [String: String] = [:]

    var body: some View {
        @Bindable var settings = app.settings
        let shows = settings.showSkipRules.always.keys.sorted {
            (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending
        }
        List {
            Section {
                if shows.isEmpty {
                    Text("None").foregroundStyle(Palette.textSecondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(shows, id: \.self) { show in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text(names[show] ?? "…").font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Button("Remove") { withAnimation(Motion.snappy(reduceMotion)) { settings.showSkipRules.removeShow(show) } }
                                .buttonStyle(TextActionStyle())
                                .accessibilityLabel("Stop always skipping for \(names[show] ?? "this show")")
                        }
                        HStack(spacing: Spacing.s) {
                            ForEach(ShowSkipRules.Part.allCases) { part in
                                PartChip(title: part.title, isOn: settings.showSkipRules.alwaysSkips(part, show: show)) {
                                    let on = !settings.showSkipRules.alwaysSkips(part, show: show)
                                    withAnimation(Motion.snappy(reduceMotion)) { settings.showSkipRules.setAlways(on, part, show: show) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(SettingsMetrics.hairline)
                    .swipeActions { Button("Remove", role: .destructive) { settings.showSkipRules.removeShow(show) } }
                }
            } footer: {
                Text("These skip without asking for this profile. Credits move on to the next episode only when Autoplay is on. Add a show from the player: the first time a skip button appears for a show, it offers \u{201C}Always for this show\u{201D}.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Always Skipping")
        .task(id: shows) {
            for key in shows where names[key] == nil {
                names[key] = await app.title(for: MediaKey(rawValue: key))?.name ?? key
            }
        }
    }
}

/// Intro / Recap / Credits: a filled chip when that part is always skipped.
private struct PartChip: View {
    let title: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.caption2.weight(.heavy)) }
                Text(ui: title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(isOn ? Palette.elevated : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Palette.brand.opacity(0.7) : Palette.edge))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Always skip \(title.lowercased())")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
