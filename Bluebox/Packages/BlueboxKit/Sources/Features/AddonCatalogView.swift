import Addons
import DesignSystem
import Domain
import SwiftUI

/// See All from an add-on catalog's Home row: the whole catalog, a page at a
/// time (by `skip`), with its genres to choose from when it has them. The
/// catalog's and genres' names are the add-on's, shown as they are.
struct AddonCatalogView: View {
    @Environment(AppModel.self) private var app
    let addonID: String
    let catalogID: String
    @State private var genre: String?
    @State private var results = PagedTitles()

    private var catalog: ResolvedCatalog? { app.resolvedCatalog(addonID: addonID, catalogID: catalogID) }

    var body: some View {
        let catalog = catalog
        let name = catalog?.catalog.name ?? ""
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Spacing.l) {
                    PageTitle(title: name, inset: Spacing.pageInset(for: geo.size.width))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let catalog {
                        if !catalog.catalog.genres.isEmpty { genrePicker(catalog.catalog) }
                        content(name: name, width: geo.size.width)
                    } else {
                        StateMessage(.empty, title: "This catalog isn't available",
                                     message: "Its add-on was removed or turned off, or the catalog was taken out of it.")
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .reportsHeaderScroll()
        }
        .blueboxScreen()
        .navigationTitle(name)
        .task(id: genre) { await reload() }
        .reloadsWhenBackOnline(results.error != nil) { await reload() }
    }

    @ViewBuilder private func content(name: String, width: CGFloat) -> some View {
        if let error = results.error {
            if app.settings.isOffline || UserFacingError.isOffline(error) {
                OfflineMessage(reason: "Add-on catalogs need the internet.") { Task { await reload() } }
            } else {
                StateMessage(.failed, title: "Couldn't load \(name)",
                             message: UserFacingError.message(for: error, context: .addons),
                             actionTitle: "Try Again") { Task { await reload() } }
            }
        } else if results.isEmptyResult {
            StateMessage(systemImage: "film", title: "Nothing here Bluebox can open",
                         message: "Bluebox shows titles with an IMDb or TMDB ID; this catalog has none right now.")
        } else {
            TitleGrid(results: results, width: width)
        }
    }

    /// The add-on's genres; "All" only when it answers without one.
    private func genrePicker(_ catalog: AddonCatalog) -> some View {
        BlueboxMenu(String(localized: "Genre")) {
            if !catalog.genreRequired {
                BlueboxMenuButton(String(localized: "All"), checked: genre == nil) { genre = nil }
            }
            for g in catalog.genres {
                BlueboxMenuButton(g, checked: genre == g) { genre = g }
            }
        } label: {
            HStack(spacing: 4) {
                if let shown = genre ?? (catalog.genreRequired ? catalog.genres.first : nil) {
                    Text(verbatim: shown)
                } else {
                    Text("All")
                }
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Palette.brandBright)
        }
        .accessibilityLabel("Genre")
    }

    private func reload() async {
        guard let c = catalog else { await results.reset(nil); return }
        let reader = app.addonCatalogs, g = genre
        await results.reset { try await reader.page(c, genre: g, page: $0) }
    }
}
