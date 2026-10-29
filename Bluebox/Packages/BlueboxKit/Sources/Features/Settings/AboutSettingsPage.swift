import DesignSystem
import MediaSources
import SwiftUI

/// Settings › About: version, privacy, and credits.
struct AboutSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsForm(.about) {
            Section {
                VStack(spacing: Spacing.s) {
                    BlueboxWordmark(size: 40)
                    Text("Version \(AppVersion.display)").font(.footnote).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .accessibilityElement(children: .combine)
                .settingsRow("Version")
            }

            UpdateSection()

            Section {
                Text(app.account.isConfigured
                     ? "Bluebox stores your library and watch progress on this device. If you sign in, My List, watch progress and profiles also sync to your Supabase project. Nothing else is collected or shared."
                     : "Bluebox stores your library and watch progress on this device. Nothing is collected or shared.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Spacing.xs)
                    .settingsRow("Privacy")
            } header: {
                Text("Privacy")
            }

            Section {
                Text("Bluebox is a player. It doesn't host or index anything; releases come from the add-ons and peers you choose. You're responsible for having the right to watch what you play.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Spacing.xs)
            } header: {
                Text("Your Responsibility")
            }

            Section {
                credit("TMDB", "This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .settingsRow("Acknowledgements")
                credit("libtorrent", "Torrents stream with libtorrent (rasterbar), used under its BSD licence, with Boost under the Boost Software License. See THIRD-PARTY-NOTICES.md.")
                credit("VLC", "Formats AVPlayer can't open play with libVLC through SwiftVLC, used under the GNU LGPL 2.1 or later.")
                credit("Stremio add-ons", "Releases are found through the Stremio add-on protocol. Bluebox isn't affiliated with Stremio or any add-on.")
                ForEach(PublicCatalogSource.defaultEntries, id: \.slug) { e in
                    credit("\(e.title) — \(e.license)", e.attribution)
                }
            } header: {
                Text("Acknowledgements")
            }
        }
    }

    private func credit(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.xs)
    }
}
