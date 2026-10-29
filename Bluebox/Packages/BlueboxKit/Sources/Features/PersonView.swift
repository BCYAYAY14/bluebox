import DesignSystem
import Domain
import SwiftUI

/// A person's page: portrait, name, department, birthday and place, a
/// biography with More, Known For, then Movies and TV Shows by year with the
/// role. "In Your Library" narrows the lists to titles you have (My List,
/// progress, downloads, your own sources). Titles open through `Route.title`,
/// so this must sit inside a NavigationStack.
public struct PersonView: View {
    @Environment(AppModel.self) private var app
    let personID: Int
    /// Shown while loading (from the credit that was tapped).
    let fallbackName: String
    let fallbackProfile: Artwork?

    @State private var person: Person?
    @State private var filmography: Filmography?
    @State private var libraryKeys: Set<MediaKey>?
    @State private var scope: Scope = .all
    @State private var bioExpanded = false
    @State private var error: String?
    @State private var failedOffline = false

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", library = "In Your Library"
        var id: String { rawValue }
    }

    public init(personID: Int, name: String = "", profile: Artwork? = nil) {
        self.personID = personID; self.fallbackName = name; self.fallbackProfile = profile
    }

    /// Opens the page for someone from a title's credits.
    public init(_ credit: CreditPerson) { self.init(personID: credit.id, name: credit.name, profile: credit.profile) }

    public var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            let wide = geo.size.width >= 700
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    header(wide: wide, inset: inset)
                    if let error, person == nil {
                        if failedOffline {
                            OfflineMessage(reason: "People's pages need the internet.") { Task { await load() } }
                        } else {
                            StateMessage(.failed, systemImage: "person.crop.circle.badge.exclamationmark", title: "Couldn't load this page",
                                         message: error, actionTitle: "Try Again") { Task { await load() } }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if let filmography {
                        if !filmography.knownFor.isEmpty { knownFor(filmography.knownFor, inset: inset) }
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                        .padding(.horizontal, inset)
                        credits("Movies", filter(filmography.movies), inset: inset)
                        credits("TV Shows", filter(filmography.shows), inset: inset)
                        if scope == .library, filter(filmography.movies).isEmpty, filter(filmography.shows).isEmpty, libraryKeys != nil {
                            StateMessage(systemImage: "rectangle.stack", title: "Nothing in your library yet",
                                         message: "Nothing with \(person?.name ?? fallbackName) is on My List, in progress, downloaded or in your sources.",
                                         actionTitle: "Show All") { scope = .all }
                        }
                    } else if error == nil {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            ForEach(0..<6, id: \.self) { _ in SkeletonBlock(height: 18) }
                        }
                        .padding(.horizontal, inset)
                    }
                }
                .padding(.vertical, Spacing.xl)
            }
            .reportsHeaderScroll()
        }
        .background(Palette.background)
        .navigationTitle(person?.name ?? fallbackName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: personID) { await load() }
        .reloadsWhenBackOnline(error != nil && person == nil) { await load() }
        .task(id: scope) { if scope == .library, libraryKeys == nil { libraryKeys = await app.libraryKeys() } }
    }

    // MARK: Header

    @ViewBuilder private func header(wide: Bool, inset: CGFloat) -> some View {
        let portrait = ArtworkView(url: app.imageURL(person?.profile ?? fallbackProfile, width: 300),
                                   fallbackTitle: person?.name ?? fallbackName, kind: .profile, pixelWidth: 600)
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: wide ? 220 : 140, height: wide ? 330 : 210)
            .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        let info = VStack(alignment: .leading, spacing: Spacing.s) {
            Text(person?.name ?? fallbackName)
                .font(Typography.display(compact: !wide)).foregroundStyle(Palette.textPrimary)
                .lineLimit(3).minimumScaleFactor(0.7)
            if let dept = person?.department {
                Text(dept).font(Typography.meta).foregroundStyle(Palette.textSecondary)
            }
            if let line = birthLine { Text(line).font(Typography.meta).foregroundStyle(Palette.textSecondary) }
            if let bio = person?.biography, !bio.isEmpty {
                Text(bio)
                    .font(Typography.body).foregroundStyle(Palette.textPrimary.opacity(0.88))
                    .lineLimit(bioExpanded ? nil : 4)
                    .padding(.top, Spacing.xs)
                    .textSelection(.enabled)
                Button(bioExpanded ? "Less" : "More") { withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() } }
                    .buttonStyle(PressableStyle())
                    .font(Typography.meta.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        Group {
            if wide {
                HStack(alignment: .top, spacing: Spacing.xl) { portrait; info.frame(maxWidth: 640, alignment: .leading) }
            } else {
                VStack(alignment: .leading, spacing: Spacing.l) { portrait; info }
            }
        }
        .padding(.horizontal, inset)
    }

    /// "Born March 2, 1962 (age 64) in Beirut, Lebanon" / "1962 – 2020".
    private var birthLine: String? {
        guard let p = person, let born = p.birthday else { return nil }
        let date = born.formatted(.dateTime.month(.wide).day().year())
        if let died = p.deathday {
            return "\(born.formatted(.dateTime.year())) – \(died.formatted(.dateTime.year()))"
                + (p.placeOfBirth.map { " · Born in \($0)" } ?? "")
        }
        let age = p.age().map { " (age \($0))" } ?? ""
        return "Born \(date)\(age)" + (p.placeOfBirth.map { " in \($0)" } ?? "")
    }

    // MARK: Known For

    private func knownFor(_ credits: [Credit], inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Known For").font(Typography.rowTitle).foregroundStyle(Palette.textPrimary).padding(.horizontal, inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.cardGap) {
                    ForEach(credits) { c in
                        TitleCardLink(c.title) {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterCard(title: c.title.name, url: app.imageURL(c.title.poster, width: 130), width: 130)
                                Text(c.roleText).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1).frame(width: 130, alignment: .leading)
                            }
                        }
                        .accessibilityLabel("\(c.title.name), \(c.roleText)")
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    // MARK: Lists

    private func filter(_ list: [Credit]) -> [Credit] {
        guard scope == .library else { return list }
        guard let keys = libraryKeys else { return [] }
        return list.filter { keys.contains($0.title.key) }
    }

    @ViewBuilder private func credits(_ heading: String, _ list: [Credit], inset: CGFloat) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(heading).font(Typography.rowTitle).foregroundStyle(Palette.textPrimary).padding(.bottom, Spacing.s)
                ForEach(list) { c in
                    NavigationLink(value: Route.title(c.title)) { CreditRow(credit: c) }
                        .buttonStyle(PressableStyle())
                    Divider().overlay(Palette.separator)
                }
            }
            .padding(.horizontal, inset)
        }
    }

    private func load() async {
        guard app.hasPersonPages, personID > 0 else {
            error = "Pages for people need a TMDB key (Settings › Catalog)."
            return
        }
        do {
            async let p = app.person(id: personID)
            async let f = app.filmography(personID: personID)
            (person, filmography) = try await (p, f)
            error = nil
        } catch is CancellationError {
        } catch {
            failedOffline = app.settings.isOffline || UserFacingError.isOffline(error)
            self.error = UserFacingError.message(for: error, context: .catalog)
        }
    }
}

private struct CreditRow: View {
    let credit: Credit
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Text(credit.title.year.map(String.init) ?? "—")
                .font(Typography.meta.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.title.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                if !credit.roleText.isEmpty {
                    Text(credit.roleText).font(Typography.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, Spacing.m)
        .padding(.horizontal, Spacing.s)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(hovering ? Palette.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}
