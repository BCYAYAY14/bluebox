import DesignSystem
import Domain
import SwiftUI

/// Cast and crew for a title page: a "Directed by" / "Created by" line, a row
/// of round cast photos with names and characters, and "See All" for the
/// full list by department. People open `PersonView` when the catalog has
/// person pages (TMDB); with Cinemeta only names are shown. Must sit inside a
/// NavigationStack.
///
///     CastCrewSection(key: title.key, inset: inset)
public struct CastCrewSection: View {
    @Environment(AppModel.self) private var app
    let key: MediaKey
    let inset: CGFloat
    @State private var credits: TitleCredits?

    public init(key: MediaKey, inset: CGFloat = 16) { self.key = key; self.inset = inset }

    public var body: some View {
        // A stack, not a Group: an empty Group has nothing to run `.task` on, so it never loaded.
        VStack(alignment: .leading, spacing: 0) {
            if let credits, !credits.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let line = Self.leadLine(credits) {
                        Text(line)
                            .font(Typography.meta).foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .padding(.horizontal, inset)
                    }
                    if !credits.cast.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Cast").font(Typography.rowTitle).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            NavigationLink(value: Route.castCrew(credits)) {
                                // The tab is already "Cast & Crew"; the link just says where it goes.
                                HStack(spacing: 4) {
                                    Text("See All")
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                }
                                .font(Typography.meta.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("See All Cast and Crew")
                        }
                        .padding(.horizontal, inset)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: Spacing.l) {
                                ForEach(credits.cast.prefix(20)) { person in
                                    PersonLink(person: person, hasPages: credits.hasPersonPages) {
                                        CastCircle(person: person, url: app.imageURL(person.profile, width: 88))
                                    }
                                }
                            }
                            .padding(.horizontal, inset)
                        }
                    }
                }
            }
        }
        .task(id: key) { credits = await app.credits(for: key) }
    }

    /// "Directed by A and B" for films, "Created by C" for shows.
    static func leadLine(_ c: TitleCredits) -> String? {
        func names(_ people: [CreditPerson]) -> String {
            let n = people.prefix(3).map(\.name)
            return n.count <= 1 ? (n.first ?? "") : n.dropLast().joined(separator: ", ") + " and " + n.last!
        }
        if !c.directors.isEmpty { return "Directed by \(names(c.directors))" }
        if !c.creators.isEmpty { return "Created by \(names(c.creators))" }
        return nil
    }
}

/// Everyone, grouped by department.
public struct CastCrewListView: View {
    @Environment(AppModel.self) private var app
    let credits: TitleCredits

    public init(credits: TitleCredits) { self.credits = credits }

    public var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl, pinnedViews: []) {
                    ForEach(credits.departments, id: \.name) { dept in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(dept.name)
                                .font(Typography.meta.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                                .textCase(.uppercase)
                                .padding(.bottom, Spacing.s)
                            ForEach(dept.people) { person in
                                PersonLink(person: person, hasPages: credits.hasPersonPages) {
                                    PersonRow(person: person, url: app.imageURL(person.profile, width: 48))
                                }
                                Divider().overlay(Palette.separator)
                            }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, Spacing.l)
            }
            .reportsHeaderScroll()
        }
        .background(Palette.background)
        .navigationTitle("Cast & Crew")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Opens `PersonView` when people have pages; otherwise just shows the content.
private struct PersonLink<Label: View>: View {
    let person: CreditPerson
    let hasPages: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        if hasPages && person.id > 0 {
            // A value link, so it joins the tab's path (the top bar's back button follows it).
            NavigationLink(value: Route.person(person.id)) { label() }
                .buttonStyle(PressableStyle())
        } else {
            label()
        }
    }
}

private struct CastCircle: View {
    let person: CreditPerson
    let url: URL?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Palette.surface)
                if url != nil {
                    ArtworkView(url: url, fallbackTitle: person.name, kind: .profile, pixelWidth: 176, showsFallbackTitle: false)
                } else {
                    Text(Self.initials(person.name))
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(hovering ? Palette.textPrimary.opacity(0.7) : Palette.edge, lineWidth: hovering ? 2 : 1))
            Text(person.name)
                .font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                .lineLimit(2).multilineTextAlignment(.center)
            if !person.role.isEmpty {
                Text(person.role)
                    .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(width: 96)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.role.isEmpty ? person.name : "\(person.name) as \(person.role)")
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

private struct PersonRow: View {
    let person: CreditPerson
    let url: URL?

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                Circle().fill(Palette.surface)
                if url != nil {
                    ArtworkView(url: url, fallbackTitle: person.name, kind: .profile, pixelWidth: 96, showsFallbackTitle: false)
                } else {
                    Text(CastCircle.initials(person.name)).font(.callout.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                if !person.role.isEmpty {
                    Text(person.role).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
