import Addons
import DesignSystem
import Domain
import Playback
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Every release the add-ons found for a movie or episode, ranked. "Best for
/// you" (what Play would use) stays pinned on top whatever the chips say;
/// under it the rest, narrowed by the chips (4K, 1080p, 720p, HDR/DV,
/// Cached, a size cap, your audio language), grouped by quality, with
/// near-copies folded into one row ("+3 similar").
///
/// Each row: quality, size, plain tags (Cached, Fast, Small, HDR, DV, Atmos,
/// Remux), the add-on (Mac and wide iPad), and seeders. A tap plays; ⓘ or a
/// long press shows the release name and its details. On mobile data, big
/// files and releases above the quality limit are marked; a release from the
/// group last played for this show is marked "Same group".
struct ReleasePickerSheet: View {
    let item: NowPlayingItem
    /// Plays the picked release; nil plays it with `app.play(_:release:)`.
    let onChoose: ((AddonRelease) -> Void)?
    /// Whether "No releases" offers Settings. Off where the settings action
    /// can't reach (the preparing overlay sits above it).
    let canOpenSettings: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettingsPage) private var openSettingsPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var releases: [AddonRelease] = []
    @State private var choice: ShowChoice?
    @State private var loading = true
    @State private var error: String?
    @State private var sort: ReleaseListSort = .best
    @State private var filter = ReleaseFilter()
    /// Rows whose "+3 similar" is open.
    @State private var expanded: Set<String> = []
    /// The row whose menu is open (touch and hold).
    @State private var menuRelease: String?
    /// When a touch-and-hold opened a menu, so the tap that ends it doesn't also play.
    @State private var longPressAt: Date?

    init(item: NowPlayingItem, canOpenSettings: Bool = false, onChoose: ((AddonRelease) -> Void)? = nil) {
        self.item = item
        self.canOpenSettings = canOpenSettings
        self.onChoose = onChoose
    }

    /// The add-on gets its own column on the Mac and on a wide iPad; on a
    /// phone it's in the row's menu ("From Torrentio").
    private var showsAddonColumn: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    private var sorted: [AddonRelease] { sort.apply(releases) }

    /// The mobile data limits releases are marked against, or nil on Wi‑Fi.
    private var mobileRanking: MobileDataRanking? {
        app.settings.isOnMobileData ? app.settings.mobileData.ranking(dataSaver: app.settings.dataSaverForThisPlayback) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if loading {
                    ReleaseListSkeleton().transition(.opacity)
                } else if let error {
                    StateMessage(systemImage: "exclamationmark.triangle", title: "Couldn't find releases", message: error,
                                 actionTitle: "Try Again") { Task { await load(refresh: true) } }
                        .frame(maxHeight: .infinity)
                } else if releases.isEmpty {
                    StateMessage(systemImage: "magnifyingglass", title: "No releases",
                                 message: "The add-ons didn't find anything for this. Try other add-ons or quality settings in Settings › Torrents & Debrid.",
                                 actionTitle: canOpenSettings ? "Add-on Settings" : "Search Again",
                                 action: canOpenSettings ? openAddonSettings : { Task { await load(refresh: true) } },
                                 secondaryActionTitle: canOpenSettings ? "Search Again" : nil,
                                 secondaryAction: canOpenSettings ? { Task { await load(refresh: true) } } : nil)
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        chips
                        list
                    }
                }
            }
        }
        .animation(Motion.standard(reduceMotion), value: loading)
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.brand)
        .blueboxMenuHost()
        .task { await load() }
        .onAppear { sort = ReleaseListSort.initial(remembered: ViewMemory.string("releaseSort", profile: app.currentProfileID),
                                                   settings: app.addonSettings.sort) }
        .onChange(of: sort) { _, s in
            ViewMemory.set(ReleaseListSort.memory(s, settings: app.addonSettings.sort), "releaseSort", profile: app.currentProfileID)
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 540, idealHeight: 620)
        #else
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        #endif
    }

    // MARK: Header

    private var titleText: String {
        item.key.episodeNumbers == nil ? item.title : "\(item.title) · " + (item.subtitle ?? "")
    }

    private var summary: String? {
        guard !loading, error == nil, !releases.isEmpty else { return item.key.episodeNumbers == nil ? item.subtitle : nil }
        let addons = Set(releases.compactMap(\.addonName)).count
        var parts = ["\(releases.count) found"]
        if addons > 0 { parts.append(addons == 1 ? "1 add-on" : "\(addons) add-ons") }
        return parts.joined(separator: " · ")
    }

    /// "Releases", then what they're for and, on its own line, how many were found.
    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Releases").font(.title2.weight(.heavy))
                Text(titleText)
                    .font(.footnote.weight(.semibold)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                if let summary {
                    Text(summary)
                        .font(.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: Spacing.s)
            if !releases.isEmpty { sortMenu }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Palette.elevated, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.leading, Spacing.l + 4)
        .padding(.trailing, Spacing.s)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.s)
    }

    private var sortMenu: some View {
        BlueboxMenu("Sort Releases") {
            BlueboxMenuSection("Sort By") {
                for s in ReleaseListSort.allCases {
                    BlueboxMenuButton(s.title, systemImage: s.symbol, checked: s == sort) { sort = s }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(sort == .best ? "Best" : sort.shortTitle)
                Image(systemName: "chevron.down").font(.caption2.weight(.heavy)).foregroundStyle(Palette.textSecondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Palette.elevated, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .fixedSize()
        .accessibilityLabel("Sort")
        .accessibilityValue(sort.title)
        .accessibilityIdentifier("releaseSort")
    }

    // MARK: Chips

    /// The rest of the list, below "Best for you", in the chosen order.
    private var others: [AddonRelease] {
        let best = releases.first?.id
        return sorted.filter { $0.id != best }
    }

    /// Settings › Playback › Audio Language, when one is set.
    private var audioLanguage: String? { app.settings.preferredAudioLanguage.flatMap { $0.isEmpty ? nil : $0 } }

    /// Only chips that would match something (or are on), so none leads to an empty list.
    private var chips: some View {
        let pool = others
        let tiers = Set(pool.map { QualityTier(resolution: $0.resolution) })
        return ChipRow(inset: Spacing.l + 4) {
            ForEach([QualityTier.uhd, .fullHD, .hd], id: \.self) { tier in
                if tiers.contains(tier) || filter.tiers.contains(tier) {
                    FilterChip(tier.title, selected: filter.tiers.contains(tier)) {
                        change { if $0.tiers.contains(tier) { $0.tiers.remove(tier) } else { $0.tiers.insert(tier) } }
                    }
                }
            }
            if filter.hdrOnly || pool.contains(where: \.info.isHDR) {
                FilterChip("HDR / DV", selected: filter.hdrOnly) { change { $0.hdrOnly.toggle() } }
            }
            if filter.instantOnly || pool.contains(where: \.startsInstantly) {
                FilterChip("Cached", systemImage: "bolt.fill", selected: filter.instantOnly) { change { $0.instantOnly.toggle() } }
                    .accessibilityHint("Only releases that start at once")
            }
            sizeChip
            if let audioLanguage {
                let name = Locale.current.localizedString(forLanguageCode: audioLanguage) ?? audioLanguage
                FilterChip(name, systemImage: "speaker.wave.2.fill", selected: filter.language != nil) {
                    change { $0.language = $0.language == nil ? audioLanguage : nil }
                }
                .accessibilityHint("Only releases with \(name) audio")
            }
            if filter.isActive {
                Button("Clear") { change { $0 = ReleaseFilter() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.s)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.bottom, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private var sizeChip: some View {
        BlueboxMenu("File Size") {
            BlueboxMenuSection("Largest File") {
                BlueboxMenuButton("Any Size", checked: filter.sizeCap == nil) { change { $0.sizeCap = nil } }
                for cap in ReleaseSizeCap.allCases {
                    BlueboxMenuButton(cap.title, subtitle: count(cap), checked: filter.sizeCap == cap) { change { $0.sizeCap = cap } }
                }
            }
        } label: {
            FilterChipLabel(title: filter.sizeCap?.title ?? "Size", selected: filter.sizeCap != nil, opensMenu: true)
        }
        .fixedSize()
        .accessibilityLabel("File size")
        .accessibilityValue(filter.sizeCap?.title ?? "Any")
    }

    /// "31 releases": how many the cap leaves with the other chips as they are.
    private func count(_ cap: ReleaseSizeCap) -> String {
        var f = filter
        f.sizeCap = cap
        let n = f.apply(others).count
        return n == 1 ? "1 release" : "\(n) releases"
    }

    private func change(_ edit: (inout ReleaseFilter) -> Void) {
        var f = filter
        edit(&f)
        withAnimation(Motion.standard(reduceMotion)) { filter = f }
    }

    // MARK: List

    private var list: some View {
        let rest = others
        let shown = filter.apply(rest)
        let sections = ReleaseCollapser.sections(ReleaseCollapser.collapse(shown))
        let best = releases.first  // the ranked top: what Play uses
        let mobile = mobileRanking
        let small = ReleaseTag.smallThresholds(releases)
        // Eyebrows are plain rows, not section headers: those turn into grey
        // sticky bars on the Mac.
        return List {
            if let best {
                eyebrow("Best for you")
                row(best, isBest: true, mobile: mobile, small: small)
            }
            eyebrow(filter.isActive ? "All releases · \(shown.count) of \(rest.count)" : "All releases · \(rest.count)")
            if sections.isEmpty && filter.isActive {
                noMatches
            }
            ForEach(sections) { section in
                groupHeader(section)
                ForEach(section.clusters) { cluster in
                    row(cluster.lead, isBest: false, mobile: mobile, small: small)
                    if !cluster.similar.isEmpty {
                        let open = expanded.contains(cluster.id)
                        if open {
                            ForEach(cluster.similar) { r in row(r, isBest: false, mobile: mobile, small: small, nested: true) }
                        }
                        similarToggle(cluster, open: open)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 40)
        .refreshable { await load(refresh: true, showsSpinner: false) }
    }

    /// "4K · 12": a quality group's header, quieter than the eyebrows above.
    private func groupHeader(_ section: ReleaseSection) -> some View {
        HStack(spacing: 6) {
            Text(section.tier.title).font(.subheadline.weight(.bold)).foregroundStyle(Palette.textSecondary)
            Text("\(section.count)").font(.footnote.monospacedDigit()).foregroundStyle(Palette.textTertiary)
        }
        .padding(.top, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l + 4, bottom: 2, trailing: Spacing.l))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "+3 similar" under a row with near-copies; opens them in place.
    private func similarToggle(_ cluster: ReleaseCluster, open: Bool) -> some View {
        Button {
            withAnimation(Motion.standard(reduceMotion)) {
                if open { expanded.remove(cluster.id) } else { expanded.insert(cluster.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(open ? "Hide similar" : "+\(cluster.similar.count) similar")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .heavy)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.textSecondary)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Hide similar releases" : "\(cluster.similar.count) similar releases")
        .accessibilityHint("Same quality, source and codec at about the same size")
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l + Spacing.m + 2, bottom: 2, trailing: Spacing.l))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("No other releases match these filters.").font(.subheadline).foregroundStyle(Palette.textSecondary)
            Button("Clear Filters") { change { $0 = ReleaseFilter() } }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.vertical, Spacing.s)
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l + 4, bottom: 0, trailing: Spacing.l))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Closes the sheet first: on iPhone, Settings is a sheet of its own.
    private func openAddonSettings() {
        dismiss()
        let open = openSettingsPage
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            open(.torrents)
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(1.1)
            .foregroundStyle(Palette.textTertiary)
            .padding(.top, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l + 4, bottom: 4, trailing: Spacing.l))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    /// - Parameter nested: one of a row's "similar" copies, drawn indented under it.
    private func row(_ r: AddonRelease, isBest: Bool, mobile: MobileDataRanking?, small: [QualityTier: Int64],
                     nested: Bool = false) -> some View {
        let marks = ReleaseMarks(release: r, choice: choice, mobile: mobile)
        let tags = ReleaseTag.tags(for: r, smallBelow: small[QualityTier(resolution: r.resolution)])
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: 0) {
            Button {
                // The finger lifting after a touch-and-hold opened the menu isn't a tap.
                if let t = longPressAt, Date().timeIntervalSince(t) < 1 { longPressAt = nil; return }
                choose(r)
            } label: {
                ReleaseRow(release: r, highlighted: isBest, marks: marks, tags: tags, showsAddon: showsAddonColumn)
            }
            .buttonStyle(ReleaseRowStyle())
            .accessibilityHint("Plays this release")
            detailsButton(r, marks: marks)
        }
        // In the sheet's own layer: while it's up, the remote moves only among its releases.
        .remoteFocusable("release:\(r.id)", label: [r.resolution, r.sizeText].compactMap { $0 }.joined(separator: " · "),
                         cornerRadius: 9, layer: 1) { choose(r) }
        .background(shape.fill(isBest ? Palette.wash : nested ? Palette.chrome : Palette.surface))
        .overlay { shape.strokeBorder(isBest ? Palette.brand : Palette.edge, lineWidth: 1) }
        .padding(.leading, nested ? Spacing.l : 0)
        // Touch and hold (iOS) or right-click (Mac): the solid Bluebox panel (decision 5), not the system menu.
        #if os(iOS)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            longPressAt = Date()
            menuRelease = r.id
        })
        #else
        .overlay { SecondaryClickCatcher { menuRelease = r.id } }
        #endif
        .blueboxMenu(isPresented: Binding(get: { menuRelease == r.id }, set: { if !$0, menuRelease == r.id { menuRelease = nil } }),
                     title: "Release") { menuEntries(r, marks: marks) }
        .accessibilityAction(named: "Release Details") { menuRelease = r.id }
        .accessibilityIdentifier(isBest ? "bestRelease" : "release")
        // Row traits last: the List reads them from the outermost view.
        .listRowInsets(EdgeInsets(top: 2, leading: Spacing.l, bottom: 2, trailing: Spacing.l))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// ⓘ: the same details as a long press, for anyone who doesn't know to hold.
    private func detailsButton(_ r: AddonRelease, marks: ReleaseMarks) -> some View {
        BlueboxMenu("Release Details") { menuEntries(r, marks: marks) } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .accessibilityLabel("Release Details")
    }

    /// The details panel: the release name and its facts, then Play, Download, Copy Name.
    @BlueboxMenuBuilder private func menuEntries(_ r: AddonRelease, marks: ReleaseMarks) -> [BlueboxMenuEntry] {
        [BlueboxMenuEntry.note(ReleaseFacts.breakable(r.fileName))]
        facts(r, marks: marks).map { BlueboxMenuEntry.note($0) }
        BlueboxMenuSection {
            BlueboxMenuButton("Play", systemImage: "play.fill") { choose(r) }
            if r.isDebrid || app.addonsCanStreamTorrents {
                BlueboxMenuButton("Download", systemImage: "arrow.down.circle") {
                    Task { await app.download(r, for: downloadItem) }
                }
            }
            BlueboxMenuButton("Copy Name", systemImage: "doc.on.doc") { copy(r.fileName) }
        }
        ExternalPlayerMenuSection(players: app.externalPlayers(for: r)) { chooseExternally(r, in: $0) }
    }

    /// The add-on, size and seeders, codecs, group and languages, and what the row's marks mean.
    private func facts(_ r: AddonRelease, marks: ReleaseMarks) -> [String] {
        var lines: [String] = []
        if let from = ReleaseFacts.provenance(r) { lines.append(from) }
        lines.append(ReleaseFacts.numbers(r))
        let tags = r.info.tags
        if !tags.isEmpty { lines.append(tags.joined(separator: " · ")) }
        if let details = ReleaseFacts.details(r) { lines.append(details) }
        if marks.sameGroup { lines.append("Same group as last time") }
        if marks.aboveCap { lines.append("Above your mobile data quality") }
        return lines
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func load(refresh: Bool = false, showsSpinner: Bool = true) async {
        if showsSpinner { loading = true }
        defer { loading = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seed-screens") {
            try? await Task.sleep(for: .milliseconds(refresh ? 600 : 250))
            releases = ReleaseFacts.reviewSamples
            choice = ShowChoice(group: "NTb", resolution: "1080p", bingeGroup: nil, addonID: nil)
            error = nil
            return
        }
        #endif
        do {
            async let found = app.releases(for: item.key, refresh: refresh)
            async let remembered = app.showChoice(for: item.key)
            releases = try await found
            choice = await remembered
            error = nil
        } catch is CancellationError {
        } catch {
            Log.playback.error("Release search failed: \(String(describing: error), privacy: .public)")
            self.error = UserFacingError.message(for: error, context: .addons)
        }
    }

    /// Download rows show the subtitle under the title: an episode's
    /// "S1·E3 · Name", but nothing for a movie (its subtitle is the year).
    private var downloadItem: NowPlayingItem {
        guard item.key.episodeNumbers == nil else { return item }
        return NowPlayingItem(key: item.key, title: item.title, subtitle: nil, artworkURL: item.artworkURL)
    }

    private func choose(_ release: AddonRelease) {
        menuRelease = nil
        dismiss()
        if let onChoose { onChoose(release) } else { Task { await app.play(item, release: release) } }
    }

    private func chooseExternally(_ release: AddonRelease, in player: ExternalPlayer) {
        menuRelease = nil
        dismiss()
        Task { await app.play(item, release: release, in: player) }
    }
}

/// What a row flags besides its numbers.
struct ReleaseMarks: Equatable {
    /// On mobile data and over 1 GB.
    var cellular = false
    /// On mobile data and above the quality limit.
    var aboveCap = false
    /// From the release group last played for this show.
    var sameGroup = false

    static let largeOnMobile: Int64 = 1_000_000_000

    init(cellular: Bool = false, aboveCap: Bool = false, sameGroup: Bool = false) {
        self.cellular = cellular; self.aboveCap = aboveCap; self.sameGroup = sameGroup
    }

    init(release: AddonRelease, choice: ShowChoice?, mobile: MobileDataRanking?) {
        if let mobile {
            cellular = (release.sizeBytes ?? 0) > Self.largeOnMobile
            aboveCap = mobile.isAboveCap(release)
        }
        sameGroup = ChoiceMatch.of(release, choice).isMatch
    }
}

/// How the list is ordered. Best keeps the ranking (the order Play tries them in).
enum ReleaseListSort: String, CaseIterable, Identifiable {
    case best, quality, largest, smallest, seeders
    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: "Best Match"
        case .quality: "Highest Quality"
        case .largest: "Largest First"
        case .smallest: "Smallest First"
        case .seeders: "Most Seeders"
        }
    }

    var shortTitle: String {
        switch self {
        case .best: "Best"
        case .quality: "Quality"
        case .largest: "Largest"
        case .smallest: "Smallest"
        case .seeders: "Seeders"
        }
    }

    var symbol: String {
        switch self {
        case .best: "sparkles"
        case .quality: "4k.tv"
        case .largest: "arrow.down.right.and.arrow.up.left"
        case .smallest: "arrow.up.left.and.arrow.down.right"
        case .seeders: "person.2"
        }
    }

    /// Settings › Torrents & Debrid › Sort By, as a list order.
    init(_ settingsSort: ReleaseSort) {
        switch settingsSort {
        case .quality: self = .quality
        case .seeders: self = .seeders
        case .size: self = .largest
        }
    }

    /// The order the sheet opens in: Settings' sort, unless a different one
    /// was picked here since Settings' sort last changed. Remembered as
    /// "<settings sort>:<list sort>".
    static func initial(remembered: String?, settings: ReleaseSort) -> ReleaseListSort {
        guard let remembered else { return ReleaseListSort(settings) }
        let parts = remembered.split(separator: ":").map(String.init)
        guard parts.count == 2, parts[0] == settings.rawValue, let picked = ReleaseListSort(rawValue: parts[1]) else {
            return ReleaseListSort(settings)
        }
        return picked
    }

    static func memory(_ sort: ReleaseListSort, settings: ReleaseSort) -> String {
        "\(settings.rawValue):\(sort.rawValue)"
    }

    /// Stable: ties keep the ranked order.
    func apply(_ releases: [AddonRelease]) -> [AddonRelease] {
        let indexed = Array(releases.enumerated())
        func by<T: Comparable>(_ key: (AddonRelease) -> T, descending: Bool) -> [AddonRelease] {
            indexed.sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                if ka != kb { return descending ? ka > kb : ka < kb }
                return a.offset < b.offset
            }.map(\.element)
        }
        switch self {
        case .best: return releases
        case .quality: return by({ StremioSource.resolutionLevel($0.resolution) ?? 0 }, descending: true)
        case .largest: return by({ $0.sizeBytes ?? -1 }, descending: true)
        case .smallest: return by({ $0.sizeBytes ?? .max }, descending: false)
        case .seeders: return by({ $0.startsInstantly ? Int.max : ($0.seeders ?? -1) }, descending: true)
        }
    }
}

/// Wording for release rows.
enum ReleaseFacts {
    /// "4K" for 2160p; other resolutions as given ("1080p"); "SD" when unknown.
    static func quality(_ resolution: String?) -> String {
        switch resolution {
        case nil, "": "SD"
        case "2160p": "4K"
        case "480p": "SD"
        case let r?: r
        }
    }

    /// "From Torrentio, also StremThru Torz".
    static func provenance(_ r: AddonRelease) -> String? {
        guard let addon = r.addonName else { return nil }
        return r.alsoFrom.isEmpty ? "From \(addon)" : "From \(addon), also \(r.alsoFrom.joined(separator: ", "))"
    }

    /// A release name that wraps at its dots, dashes and underscores instead
    /// of being hyphenated mid-word ("Sintel.2010.1080p.BluRay…").
    static func breakable(_ name: String) -> String {
        var out = ""
        for c in name {
            out.append(c)
            if c == "." || c == "-" || c == "_" { out.append("\u{200B}") }
        }
        return out
    }

    /// "4K · 18.2 GB · 96 seeders", or "… · Cached" for a link.
    static func numbers(_ r: AddonRelease) -> String {
        var parts = [quality(r.resolution)]
        if let size = r.sizeText { parts.append(size) }
        if let link = linkState(r) {
            parts.append(link.text)
        } else if let s = r.seeders {
            parts.append(s == 1 ? "1 seeder" : "\(s) seeders")
        }
        return parts.joined(separator: " · ")
    }

    /// "Group NTb · English, Japanese".
    static func details(_ r: AddonRelease) -> String? {
        var parts: [String] = []
        if let group = r.group { parts.append("Group \(group)") }
        let names = r.info.languages.map { code in
            code == "multi" ? "Multi-language" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the health column says for a link: cached, waiting on the service, or a plain link.
    static func linkState(_ r: AddonRelease) -> (text: String, symbol: String)? {
        guard r.isDebrid else { return nil }
        switch r.cache {
        case .cached: return ("Cached", "bolt.fill")
        case .uncached: return ("Not cached", "hourglass")
        case .unknown: return ("Direct", "link")
        }
    }
}

#if DEBUG
extension ReleaseFacts {
    /// Releases for screenshots (`-seed-screens`), in ranked order.
    static var reviewSamples: [AddonRelease] {
        func torrent(_ hash: String, _ addon: String, _ text: String, file: String, seeders: Int, size: Int64) -> AddonRelease {
            AddonRelease(id: "\(hash):0", title: text, name: addon, infoHash: hash, fileIndex: 0, trackers: [],
                         seeders: seeders, sizeText: nil, resolution: nil, container: nil, url: nil,
                         addonID: addon.lowercased(), addonName: addon, filename: file, videoSize: size)
        }
        let gb: Int64 = 1_073_741_824
        return [
            AddonRelease(id: "https://debrid.example/1", title: "Sintel.2010.1080p.WEB-DL.H264.AAC-NTb", name: "[RD+] Torrentio\n1080p",
                         infoHash: nil, fileIndex: nil, trackers: [], seeders: nil, sizeText: nil, resolution: nil, container: nil,
                         url: URL(string: "https://debrid.example/1"), addonID: "torrentio", addonName: "Torrentio",
                         cache: .cached, filename: "Sintel.2010.1080p.WEB-DL.H264.AAC-NTb.mp4", videoSize: gb * 21 / 10),
            torrent(String(repeating: "a", count: 40), "Torrentio", "Sintel.2010.1080p.BluRay.x265.10bit.AAC5.1-NTb\n👤 230 💾 1.2 GB",
                    file: "Sintel.2010.1080p.BluRay.x265.10bit.AAC5.1-NTb.mkv", seeders: 230, size: gb * 12 / 10),
            torrent(String(repeating: "b", count: 40), "StremThru Torz", "Sintel.2010.2160p.UHD.BluRay.HDR10.x265.Atmos-FLUX\n👤 96 💾 18.2 GB",
                    file: "Sintel.2010.2160p.UHD.BluRay.HDR10.x265.Atmos-FLUX.mkv", seeders: 96, size: gb * 182 / 10),
            torrent(String(repeating: "c", count: 40), "Comet", "Sintel.2010.1080p.WEBRip.x264.DDP5.1-RARBG\n👤 41 💾 1.6 GB",
                    file: "Sintel.2010.1080p.WEBRip.x264.DDP5.1-RARBG.mp4", seeders: 41, size: gb * 16 / 10),
            torrent(String(repeating: "d", count: 40), "Torrentio", "Sintel.2010.720p.BRRip.x264.AAC-YTS\n👤 58 💾 1.1 GB",
                    file: "Sintel.2010.720p.BRRip.x264.AAC-YTS.mp4", seeders: 58, size: gb * 11 / 10),
            torrent(String(repeating: "e", count: 40), "Comet", "Sintel.2010.2160p.WEB-DL.DV.HEVC.TrueHD.7.1-SiC\n👤 12 💾 22.4 GB",
                    file: "Sintel.2010.2160p.WEB-DL.DV.HEVC.TrueHD.7.1-SiC.mkv", seeders: 12, size: gb * 224 / 10),
            torrent(String(repeating: "f", count: 40), "Torrentio", "Sintel.2010.480p.DVDRip.XviD-aXXo\n👤 6 💾 410 MB",
                    file: "Sintel.2010.480p.DVDRip.XviD-aXXo.avi", seeders: 6, size: 410 * 1_048_576),
            // The same encode re-shared: folds under the NTb BluRay x265 as "+1 similar".
            torrent(String(repeating: "9", count: 40), "Comet", "Sintel.2010.1080p.BluRay.x265.10bit.AAC5.1-PSA\n👤 18 💾 1.21 GB",
                    file: "Sintel.2010.1080p.BluRay.x265.10bit.AAC5.1-PSA.mkv", seeders: 18, size: gb * 121 / 100),
        ]
    }
}
#endif

/// One release: quality, size (with mobile data marks), "Same group", the
/// add-on (Mac and wide iPad), then seeders or the link's state; its plain
/// tags on a second line under the size. Numbers are grey; only the best
/// release is blue, and only a dead one red. The card behind it (and ⓘ) is
/// the picker's.
private struct ReleaseRow: View {
    let release: AddonRelease
    let highlighted: Bool
    let marks: ReleaseMarks
    let tags: [ReleaseTag]
    let showsAddon: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                firstLine
                if !tags.isEmpty { ReleaseTagLine(tags: tags, highlighted: highlighted) }
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.vertical, tags.isEmpty ? 0 : 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var badge: some View {
        QualityBadge(ReleaseFacts.quality(release.resolution), highlighted: highlighted)
            .opacity(marks.aboveCap ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if marks.aboveCap {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .background(Circle().fill(Palette.background))
                        .offset(x: 5, y: -5)
                }
            }
    }

    private var firstLine: some View {
        HStack(spacing: Spacing.m) {
            HStack(spacing: 5) {
                Text(release.sizeText ?? "Size unknown")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(release.sizeText == nil ? Palette.textTertiary : Palette.textPrimary)
                if marks.cellular {
                    Image(systemName: "cellularbars")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            if marks.sameGroup {
                Text("Same group")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Palette.brandBright)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Palette.brand.opacity(0.7), lineWidth: 1))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Spacing.s)
            if showsAddon, let addon = release.addonName {
                Text(addon).font(.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    .fixedSize()
            }
            health.fixedSize().frame(minWidth: 52, alignment: .trailing)
        }
    }

    @ViewBuilder private var health: some View {
        if release.isDebrid && release.cache == .cached {
            // The "Cached" tag says it in words; the column keeps the bolt so cached rows line up.
            Image(systemName: "bolt.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(highlighted ? Palette.brandBright : Palette.textSecondary)
        } else if let link = ReleaseFacts.linkState(release) {
            Label(link.text, systemImage: link.symbol)
                .labelStyle(TightLabelStyle())
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(highlighted && release.cache == .cached ? Palette.brandBright : Palette.textSecondary)
        } else if let s = release.seeders {
            Label("\(s)", systemImage: "arrowtriangle.up.fill")
                .labelStyle(TightLabelStyle())
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(s == 0 ? SwarmHealth.poor : highlighted ? Palette.brandBright : Palette.textSecondary)
        } else {
            Text("–").font(.footnote).foregroundStyle(Palette.textTertiary)
        }
    }

    private var accessibilityText: String {
        var parts = [ReleaseFacts.quality(release.resolution)]
        if let s = release.sizeText { parts.append(s) }
        if marks.cellular { parts.append("large on mobile data") }
        if marks.aboveCap { parts.append("above your mobile data quality") }
        if marks.sameGroup { parts.append("same group as last time") }
        if let a = release.addonName { parts.append(a) }
        if let link = ReleaseFacts.linkState(release) { parts.append(link.text.lowercased()) }
        else if let s = release.seeders { parts.append("\(s) seeders") }
        parts += tags.filter { $0 != .cached }.map(\.spokenTitle)
        if highlighted { parts.append("best match") }
        return parts.joined(separator: ", ")
    }
}

/// A row's tags as small grey capsules ("Cached" with its bolt).
private struct ReleaseTagLine: View {
    let tags: [ReleaseTag]
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 2) {
                    if tag == .cached { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)) }
                    Text(tag.title)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tag == .cached && highlighted ? Palette.brandBright : Palette.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.elevated, in: Capsule())
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

extension ReleaseTag {
    /// VoiceOver reads "DV" letter by letter.
    var spokenTitle: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .small: "small file"
        case .fast: "fast"
        default: title
        }
    }
}

/// Dims while pressed; a faint lift under the pointer on Mac and iPad.
private struct ReleaseRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering ? 0.06 : 0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
        }
    }
}

/// Shown in place of the player while Play finds a release and buffers a
/// torrent: the title over its dimmed art, a spinner or the prebuffer bar,
/// what's happening with real numbers (peers, speed, how much is in), and
/// Cancel or Choose Another Release. Black like the player, which then takes
/// its place without a second transition (`PlayerPresentation`).
struct StreamPreparingOverlay: View {
    let status: AddonPlaybackStatus
    let cancel: () -> Void
    @Environment(AppModel.self) private var app
    @State private var choosingRelease: TitleDetailView.ReleaseRequest?

    var body: some View {
        let item = app.preparingItem
        ZStack {
            Color.black.ignoresSafeArea()
            if let art = item?.artworkURL {
                GeometryReader { geo in
                    ArtworkView(url: art, fallbackTitle: item?.title ?? "", kind: .backdrop,
                                pixelWidth: Int(geo.size.width * 2), showsFallbackTitle: false)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.32)
                        .overlay(RadialGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], center: .center,
                                                startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6))
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
            VStack(spacing: Spacing.l) {
                if let item {
                    VStack(spacing: Spacing.xs) {
                        Text(ui: item.title)
                            .font(.title2.weight(.heavy))
                            .lineLimit(2)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                }
                Group {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Palette.brand)
                            .frame(width: 240)
                            .animation(.easeOut(duration: 0.25), value: progress)
                    } else {
                        ProgressView().tint(.white).controlSize(.large)
                    }
                }
                .frame(height: 36)
                VStack(spacing: Spacing.xs) {
                    Text(headline)
                        .font(.headline)
                    if let stats {
                        Text(stats)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Palette.textSecondary)
                            .contentTransition(.numericText())
                    }
                    Text(([stepLabel] + [release.map(ReleaseFacts.breakable)].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .frame(maxWidth: 340)
                }
                .multilineTextAlignment(.center)
                HStack(spacing: Spacing.s) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    if let item, canChooseRelease(item) {
                        Button("Choose Another Release") { choosingRelease = TitleDetailView.ReleaseRequest(item: item) }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                .padding(.top, Spacing.xs)
            }
            .foregroundStyle(.white)
            .padding(Spacing.xxl)
            .accessibilityElement(children: .contain)
        }
        .transition(.opacity)
        .sheet(item: $choosingRelease) { request in
            ReleasePickerSheet(item: request.item) { release in
                Task {
                    // Stop this one (and its stream) before starting the one picked.
                    app.cancelPreparing()
                    try? await Task.sleep(for: .milliseconds(300))
                    await app.play(request.item, release: release)
                }
            }
            .remoteModal()
        }
    }

    private func canChooseRelease(_ item: NowPlayingItem) -> Bool {
        app.addonSettings.isEnabled && (item.key.tmdbID != nil || item.key.imdbID != nil)
    }

    private var step: Int {
        switch status {
        case .searching: 1
        case .trying: 2
        case .torrent(.findingPeers, _): 2
        case .torrent(.starting, _), .torrent(.buffering, _): 3
        }
    }

    private var stepLabel: String { "Step \(step) of 3" }

    private var progress: Double? {
        if case .torrent(.buffering(let p), _) = status { return p.fraction }
        return nil
    }

    private var headline: String {
        switch status {
        case .searching: "Finding releases…"
        case .trying: "Opening the release…"
        case .torrent(.findingPeers(_, let candidates), _):
            candidates > 1 ? "Connecting to peers (\(candidates) releases at once)…" : "Connecting to peers…"
        case .torrent(.starting, _): "Opening the file…"
        case .torrent(.buffering(let p), _):
            p.waitingForIndex
                ? "Fetching the file index…"
                : "Buffering \(Int((p.fraction * 100).rounded()))%"
        }
    }

    private var stats: String? {
        switch status {
        case .torrent(.findingPeers(let peers, _), _):
            return peers == 0 ? "Looking for peers" : "\(peers) peer\(peers == 1 ? "" : "s") connected"
        case .torrent(.buffering(let p), _):
            guard p.peers > 0 else { return "Waiting for peers" }
            let speed = ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file)
            var parts = ["\(p.peers) peer\(p.peers == 1 ? "" : "s")", "\(speed)/s"]
            if p.targetBytes > 0 {
                let have = ByteCountFormatter.string(fromByteCount: p.bufferedBytes, countStyle: .file)
                let want = ByteCountFormatter.string(fromByteCount: p.targetBytes, countStyle: .file)
                parts.append("\(have) of \(want)")
            }
            return parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    private var release: String? {
        switch status {
        case .searching: nil
        case .trying(let name): name
        case .torrent(_, let name): name
        }
    }
}

/// The release list's shape while the add-ons answer: rows with a quality
/// badge, a name and a size line, under "Asking your add-ons…".
private struct ReleaseListSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Asking your add-ons…")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(0..<7, id: \.self) { i in
                    HStack(spacing: Spacing.m) {
                        SkeletonBlock(width: 46, height: 22, radius: 5)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: [220, 180, 250, 200, 160, 230, 190][i], height: 13, radius: 4)
                            SkeletonBlock(width: 120, height: 11, radius: 4)
                        }
                        Spacer(minLength: 0)
                        SkeletonBlock(width: 52, height: 13, radius: 4)
                    }
                    .padding(.vertical, 6)
                }
            }
            .shimmering()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel("Asking your add-ons")
    }
}
