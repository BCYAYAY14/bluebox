import Charts
import DesignSystem
import Domain
import SwiftUI

/// My Bluebox: the current profile's viewing in numbers. Netflix-bold on
/// black, monochrome, with blue only on the figure or bar that matters.
/// Reached from the profile menu and Settings › Profiles; hidden while
/// Statistics is off in Privacy & Features.
struct StatisticsPage: View {
    @Environment(AppModel.self) private var app
    @State private var rhythm: Rhythm = .day

    enum Rhythm: String, CaseIterable, Identifiable {
        case day, hour
        var id: String { rawValue }
        var title: String { self == .day ? "By Day" : "By Hour" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header
                if !app.featureSwitches.statistics {
                    off
                } else if let stats = app.insights.statistics {
                    if stats.isEmpty { empty } else { content(stats) }
                } else {
                    ProgressView().tint(Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                footer
            }
            .frame(maxWidth: SettingsMetrics.maxWidth, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.textPrimary)
        .navigationTitle("My Bluebox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        #endif
        .task(id: "\(app.libraryRevision)|\(app.currentProfileID)|\(app.featureSwitches.statistics)") {
            await app.refreshStatistics()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("My Bluebox")
                .font(SettingsMetrics.titleFont)
                .accessibilityAddTraits(.isHeader)
            // Whole sentences, so each translates as one: "Me" (not yet renamed) reads as "Your".
            (HomeRowTitles.name(app.currentProfile) == app.currentProfile.name
                ? Text("What \(app.currentProfile.name) watches, in numbers.")
                : Text("Your viewing, in numbers."))
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder private func content(_ s: WatchStatistics) -> some View {
        YearCard(year: s.year)
        totals(s)
        if !s.topShows.isEmpty { RankedList(title: "Top Shows", items: s.topShows, unit: { $0.count == 1 ? String(localized: "1 episode") : String(localized: "\($0.count) episodes") }) }
        if !s.topFilms.isEmpty { RankedList(title: "Top Films", items: s.topFilms, unit: { _ in nil }) }
        if !s.topGenres.isEmpty { RankedList(title: "Top Genres", items: s.topGenres, unit: { $0.count == 1 ? String(localized: "1 title") : String(localized: "\($0.count) titles") }) }
        if let binge = s.longestBinge { bingeCard(binge) }
        rhythmChart(s)
    }

    private func totals(_ s: WatchStatistics) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SectionHeading("Hours Watched")
            HStack(alignment: .top, spacing: 0) {
                BigFigure(value: StatFormat.hours(s.secondsThisMonth), label: "This Month", highlighted: true)
                BigFigure(value: StatFormat.hours(s.secondsThisYear), label: "This Year")
                BigFigure(value: StatFormat.hours(s.secondsAllTime), label: "All Time")
            }
            Rectangle().fill(SettingsMetrics.hairline).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("\(s.titlesFinished)").font(.system(size: 34, weight: .heavy)).monospacedDigit()
                Text(s.titlesFinished == 1 ? "title finished" : "titles finished").font(.headline)
                Spacer(minLength: 0)
                Text(StatFormat.split(films: s.filmsFinished, episodes: s.episodesFinished))
                    .font(.subheadline).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func bingeCard(_ b: WatchStatistics.Binge) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeading("Longest Binge")
            HStack(alignment: .center, spacing: Spacing.l) {
                VStack(spacing: 0) {
                    Text("\(b.episodes)").font(.system(size: 44, weight: .heavy)).foregroundStyle(Palette.brandBright).monospacedDigit()
                    Text("episodes").font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                }
                .frame(minWidth: 84)
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.name).font(.title3.weight(.bold)).lineLimit(2)
                    Text("in one day, \(b.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))")
                        .font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.l)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func rhythmChart(_ s: WatchStatistics) -> some View {
        let values = rhythm == .day ? s.byWeekday : s.byHour
        let labels = rhythm == .day ? StatFormat.weekdays : (0..<24).map(StatFormat.hourLabel)
        let peak = values.indices.max { values[$0] < values[$1] }
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionHeading("When You Watch")
                Spacer()
                HStack(spacing: Spacing.xs) {
                    ForEach(Rhythm.allCases) { r in
                        CategoryChip(r.title, selected: rhythm == r) { rhythm = r }
                    }
                }
            }
            if let peak, values[peak] > 0 {
                Text(rhythm == .day ? "Mostly on \(StatFormat.weekdayNames[peak])s." : "Mostly around \(StatFormat.hourLabel(peak)).")
                    .font(.subheadline).foregroundStyle(Palette.textSecondary)
            }
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("When", labels[i]), y: .value("Hours", v / 3600))
                    .foregroundStyle(i == peak ? Palette.brand : Palette.elevated)
                    .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(SettingsMetrics.hairline)
                    AxisValueLabel().foregroundStyle(Palette.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: rhythm == .day ? labels : stride(from: 0, to: 24, by: 6).map { labels[$0] }) { _ in
                    AxisValueLabel().foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(height: 170)
            .accessibilityLabel(rhythm == .day ? "Hours watched by day of the week" : "Hours watched by hour of the day")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Nothing watched yet").font(.title3.weight(.bold))
            Text("Watch a film or a few episodes and your hours, top shows and genres show up here.")
                .font(.subheadline).foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Spacing.xl)
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Statistics are off").font(.title3.weight(.bold))
            Text("Bluebox isn't working out any statistics for this profile.")
                .font(.subheadline).foregroundStyle(Palette.textSecondary)
            Button("Turn On Statistics") { app.featureSwitches.statistics = true }
                .buttonStyle(SettingsActionStyle())
        }
        .padding(.vertical, Spacing.xl)
    }

    private var footer: some View {
        Text("Worked out on this device from your watch progress; nothing is sent anywhere. Time counts on the day you last watched each film or episode. Turn Statistics off in Privacy & Features.")
            .font(.footnote)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pieces

/// "Year in Bluebox": the year's headline figures on one card.
private struct YearCard: View {
    let year: WatchStatistics.Year

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(verbatim: "\(year.year) in Bluebox".uppercased())
                .font(.caption.weight(.heavy))
                .kerning(1.2)
                .foregroundStyle(Palette.brandBright)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(StatFormat.hoursNumber(year.seconds))
                    .font(.system(size: 64, weight: .black))
                    .monospacedDigit()
                Text(StatFormat.hoursUnit(year.seconds)).font(.title2.weight(.bold)).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let show = year.topShow { line("Top show", show.name) }
                if let film = year.topFilm { line("Top film", film.name) }
                if let genre = year.topGenre { line("Top genre", genre.name) }
                if let m = year.busiestMonth { line("Busiest month", Calendar.current.monthSymbols[m - 1]) }
                line("Finished", StatFormat.split(films: year.filmsFinished, episodes: year.episodesFinished))
                if let b = year.longestBinge { line("Longest binge", "\(b.episodes) episodes of \(b.name)") }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(alignment: .topTrailing) {
            // A quiet brand mark: the one blue shape on the card besides its label.
            Rectangle().fill(Palette.brand).frame(width: 4, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.top, Spacing.xl).padding(.trailing, Spacing.xl)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(year.year) in Bluebox")
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(ui: label).font(.subheadline).foregroundStyle(Palette.textSecondary).frame(width: 120, alignment: .leading)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.heavy)).accessibilityAddTraits(.isHeader)
    }
}

private struct BigFigure: View {
    let value: String
    let label: String
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(highlighted ? Palette.brandBright : Palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(ui: label).font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A numbered top five with a bar each: the leader's in blue, the rest grey.
private struct RankedList: View {
    let title: String
    let items: [WatchStatistics.Ranked]
    let unit: (WatchStatistics.Ranked) -> String?

    var body: some View {
        let most = max(items.first?.seconds ?? 1, 1)
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeading(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HStack(alignment: .center, spacing: Spacing.m) {
                        Text("\(i + 1)")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(i == 0 ? Palette.textPrimary : Palette.textTertiary)
                            .frame(width: 26, alignment: .leading)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name).font(.body.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: Spacing.s)
                                Text(StatFormat.hours(item.seconds)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(i == 0 ? Palette.brand : Palette.elevated)
                                    .frame(width: max(4, geo.size.width * item.seconds / most))
                            }
                            .frame(height: 4)
                            if let u = unit(item) {
                                Text(u).font(.caption).foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.m)
                    .overlay(alignment: .bottom) {
                        if i < items.count - 1 { Rectangle().fill(SettingsMetrics.hairline).frame(height: 1) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// How the page writes numbers.
enum StatFormat {
    /// "142 h", "3.5 h", "45 min".
    static func hours(_ seconds: TimeInterval) -> String { "\(hoursNumber(seconds)) \(hoursUnit(seconds))" }

    static func hoursNumber(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h < 1 { return "\(Int((seconds / 60).rounded()))" }
        return h < 10 ? String(format: "%.1f", h) : "\(Int(h.rounded()))"
    }

    static func hoursUnit(_ seconds: TimeInterval) -> String { seconds < 3600 ? "min" : "h" }

    /// "12 films · 42 episodes".
    static func split(films: Int, episodes: Int) -> String {
        "\(films) film\(films == 1 ? "" : "s") · \(episodes) episode\(episodes == 1 ? "" : "s")"
    }

    /// Monday first, like `WatchStatistics.byWeekday`.
    static var weekdayNames: [String] {
        let names = Calendar.current.weekdaySymbols  // Sunday first
        return Array(names[1...]) + [names[0]]
    }
    static var weekdays: [String] {
        let names = Calendar.current.shortWeekdaySymbols
        return Array(names[1...]) + [names[0]]
    }

    static func hourLabel(_ hour: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        let date = Calendar.current.date(from: c) ?? .now
        return date.formatted(.dateTime.hour())
    }
}
