import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Settings › <profile> › Hidden Titles: what this profile marked "Not
/// Interested", newest first, each with Show Again. The profile is the
/// current one (`AppModel.currentProfile`).
public struct HiddenTitlesSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        let hidden = app.hiddenTitleList()
        SettingsForm(title: "Hidden Titles") {
            Section {
                if hidden.isEmpty {
                    Text("Nothing hidden. Choose Not Interested on a poster to keep it off Home.")
                        .foregroundStyle(Palette.textSecondary)
                        .settingsRow("No Hidden Titles")
                } else {
                    ForEach(hidden) { item in
                        HiddenTitleRow(item: item) {
                            withAnimation(Motion.standard(reduceMotion)) { app.unhideTitle(item.title.key) }
                        }
                        .settingsRow("Hidden \(item.title.key.rawValue)")
                    }
                }
            } header: {
                Text("Not Interested")
            } footer: {
                Text("Hidden titles stay out of Home's rows. They still appear in Search and My List.")
            }
        }
        .accessibilityIdentifier("hiddenTitlesPage")
    }
}

private struct HiddenTitleRow: View {
    @Environment(AppModel.self) private var app
    let item: HiddenTitle
    let unhide: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            ArtworkView(url: app.imageURL(item.title.poster, width: 32), fallbackTitle: item.title.name, kind: .poster,
                        pixelWidth: 64, showsFallbackTitle: false)
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.name).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Spacing.s)
            Button("Show Again", action: unhide)
                .buttonStyle(TextActionStyle())
                .accessibilityLabel("Show \(item.title.name) Again")
        }
    }

    private var detail: String {
        let kind = item.title.kind == .movie ? "Film" : "Series"
        return [item.title.year.map(String.init), kind].compactMap { $0 }.joined(separator: " · ")
            + " · Hidden " + item.hiddenAt.formatted(.relative(presentation: .named))
    }
}
