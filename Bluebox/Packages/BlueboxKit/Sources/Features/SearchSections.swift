import DesignSystem
import Domain
import SwiftUI

/// Search results as the Apple TV app lays them out (GAPS S1, decision Q6 A):
/// the best match first, then people, then a row of films and a row of shows.
struct SearchSections: Equatable {
    enum Top: Equatable {
        case title(Title)
        case person(Person)
    }

    var top: Top?
    var people: [Person]
    var films: [Title]
    var shows: [Title]

    var isEmpty: Bool { top == nil && people.isEmpty && films.isEmpty && shows.isEmpty }

    /// - Parameters:
    ///   - titles: the search's titles in relevance order (already de-duplicated).
    ///   - people: people matching the query, most popular first.
    /// The first title leads, unless a person's name is the query and the
    /// first title's isn't (searching "Cillian Murphy" means him). Whoever
    /// leads isn't repeated below.
    static func build(query: String, titles: [Title], people: [Person]) -> SearchSections {
        let q = normalized(query)
        let firstTitle = titles.first
        let exactPerson = people.first { normalized($0.name) == q }
        let titleIsExact = firstTitle.map { normalized($0.name) == q } ?? false

        let top: Top?
        if let exactPerson, !titleIsExact {
            top = .person(exactPerson)
        } else if let firstTitle {
            top = .title(firstTitle)
        } else if let person = people.first {
            top = .person(person)
        } else {
            top = nil
        }

        var rest = titles
        var others = people
        switch top {
        case .title(let t)?: rest.removeAll { $0.key == t.key }
        case .person(let p)?: others.removeAll { $0.id == p.id }
        case nil: break
        }
        return SearchSections(top: top, people: Array(others.prefix(12)),
                              films: rest.filter { $0.kind == .movie }, shows: rest.filter { $0.kind == .series })
    }

    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The sectioned results under the search field.
struct SearchResultsSections: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isDownloaded) private var isDownloaded
    let sections: SearchSections
    let results: PagedTitles
    let width: CGFloat
    /// The people search hasn't answered: its row holds its place as a skeleton.
    var peopleLoading = false
    var onOpen: () -> Void = {}

    /// Search's poster width: bigger than the home rows' on a phone.
    static func posterWidth(for width: CGFloat) -> CGFloat {
        width < 500 ? 112 : CardMetrics(containerWidth: width).posterWidth
    }

    var body: some View {
        let inset = Spacing.pageInset(for: width)
        let posterWidth = Self.posterWidth(for: width)
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if let top = sections.top {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    header("Top Result", inset: inset)
                    topResult(top).padding(.horizontal, inset)
                }
            }
            if sections.people.isEmpty && peopleLoading {
                SearchResultsSkeleton.peopleRow(inset: inset).shimmering()
            } else if !sections.people.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    header("People", inset: inset)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Spacing.l) {
                            ForEach(sections.people) { p in PersonTile(person: p, onOpen: onOpen) }
                        }
                        .padding(.horizontal, inset)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
                .accessibilityIdentifier("search.people")
            }
            if !sections.films.isEmpty {
                shelf("Films", sections.films, posterWidth: posterWidth, inset: inset)
                    .accessibilityIdentifier("search.films")
            }
            if !sections.shows.isEmpty {
                shelf("TV Shows", sections.shows, posterWidth: posterWidth, inset: inset)
                    .accessibilityIdentifier("search.shows")
            }
            if results.isLoading && !results.isStale && !results.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func header(_ text: String, inset: CGFloat) -> some View {
        Text(text).font(Typography.rowTitle).accessibilityAddTraits(.isHeader).padding(.horizontal, inset)
    }

    @ViewBuilder private func topResult(_ top: SearchSections.Top) -> some View {
        switch top {
        case .title(let t):
            TitleCardLink(t, onOpen: onOpen) {
                HStack(spacing: Spacing.m) {
                    PosterCard(title: t.name, url: app.imageURL(t.poster, width: 84), width: 84, isDownloaded: isDownloaded(t.key))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.name).font(.title3.weight(.bold)).foregroundStyle(Palette.textPrimary).lineLimit(2)
                        Text(TitleGrid.meta(t)).font(.subheadline).foregroundStyle(Palette.textSecondary)
                        if !t.overview.isEmpty {
                            Text(t.overview).font(.caption).foregroundStyle(Palette.textTertiary).lineLimit(2)
                                .frame(maxWidth: 460, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Top result: \(t.name)")
            .accessibilityValue(TitleGrid.meta(t).replacingOccurrences(of: " · ", with: ", "))
            .accessibilityIdentifier("search.topResult")
        case .person(let p):
            NavigationLink(value: Route.person(p.id)) {
                HStack(spacing: Spacing.m) {
                    PersonPortrait(person: p, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).font(.title3.weight(.bold)).foregroundStyle(Palette.textPrimary)
                        if let dept = p.department {
                            Text(dept == "Acting" ? "Actor" : dept).font(.subheadline).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .simultaneousGesture(TapGesture().onEnded { onOpen() })
            .accessibilityLabel("Top result: \(p.name)")
            .accessibilityIdentifier("search.topResult")
        }
    }

    private func shelf(_ title: String, _ titles: [Title], posterWidth: CGFloat, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            header(title, inset: inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.cardGap) {
                    ForEach(titles) { t in
                        TitleCardLink(t, onOpen: onOpen) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                PosterCard(title: t.name, url: app.imageURL(t.poster, width: posterWidth), width: posterWidth,
                                           isDownloaded: isDownloaded(t.key))
                                Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(t.year.map(String.init) ?? " ").font(.caption2).foregroundStyle(Palette.textSecondary)
                            }
                            .frame(width: posterWidth, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(t.name)
                            .accessibilityValue(TitleGrid.meta(t).replacingOccurrences(of: " · ", with: ", "))
                        }
                        .onAppear {
                            // Near the end of either row, the next page of results.
                            if t.key == titles.last?.key { Task { await results.loadMore() } }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, Spacing.s)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// The sections' shape while the first answer loads, drawn at once and at
/// the real sections' sizes so nothing moves when they arrive: the top
/// result, people (with TMDB), then the films and TV rows. One shimmer
/// sweeps the lot (`Shimmer`: blocks inside it don't add their own).
struct SearchResultsSkeleton: View {
    let width: CGFloat
    var showsTitles = true
    var showsPeople = true

    var body: some View {
        let inset = Spacing.pageInset(for: width)
        let posterWidth = SearchResultsSections.posterWidth(for: width)
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Top Result").font(Typography.rowTitle).padding(.horizontal, inset)
                HStack(spacing: Spacing.m) {
                    SkeletonBlock(width: 84, height: 126)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 180, height: 18, radius: 4)
                        SkeletonBlock(width: 110, height: 13, radius: 4)
                        SkeletonBlock(width: 240, height: 11, radius: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, inset)
            }
            if showsPeople { Self.peopleRow(inset: inset) }
            if showsTitles {
                shelf("Films", posterWidth: posterWidth, inset: inset)
                shelf("TV Shows", posterWidth: posterWidth, inset: inset)
            }
        }
        .foregroundStyle(Palette.textTertiary)
        .shimmering()
        .accessibilityElement()
        .accessibilityLabel("Searching")
    }

    /// Also stands in for the People row alone while only people are loading.
    static func peopleRow(inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("People").font(Typography.rowTitle).foregroundStyle(Palette.textTertiary).padding(.horizontal, inset)
            HStack(alignment: .top, spacing: Spacing.l) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(spacing: Spacing.xs) {
                        SkeletonBlock(width: 76, height: 76, radius: 38)
                        SkeletonBlock(width: 60, height: 11, radius: 4)
                    }
                    .frame(width: 88)
                }
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private func shelf(_ title: String, posterWidth: CGFloat, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(Typography.rowTitle).padding(.horizontal, inset)
            HStack(alignment: .top, spacing: Spacing.cardGap) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SkeletonBlock(width: posterWidth, height: posterWidth * 1.5)
                        SkeletonBlock(width: posterWidth * 0.7, height: 11, radius: 4)
                        SkeletonBlock(width: 32, height: 9, radius: 3)
                    }
                }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }
}

/// A round portrait with the name under it; opens the person's page.
private struct PersonTile: View {
    let person: Person
    var onOpen: () -> Void = {}

    var body: some View {
        NavigationLink(value: Route.person(person.id)) {
            VStack(spacing: Spacing.xs) {
                PersonPortrait(person: person, size: 76)
                Text(person.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 88)
            }
        }
        .buttonStyle(PressableStyle())
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
        .accessibilityLabel(person.name)
        .accessibilityValue(person.department ?? "")
    }
}

private struct PersonPortrait: View {
    @Environment(AppModel.self) private var app
    let person: Person
    let size: CGFloat

    var body: some View {
        ArtworkView(url: app.imageURL(person.profile, width: size), fallbackTitle: person.name, kind: .profile,
                    pixelWidth: Int(size * 2), showsFallbackTitle: false)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if person.profile == nil {
                    Text(Self.initials(person.name)).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(Palette.textSecondary)
                }
            }
            .overlay(Circle().strokeBorder(Palette.edge))
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
