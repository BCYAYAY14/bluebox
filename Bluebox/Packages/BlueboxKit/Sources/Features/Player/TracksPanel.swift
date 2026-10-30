import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// A page inside the Audio & Subtitles card.
enum TracksPage: String, CaseIterable { case style, timing, secondLine, lines }

/// Audio & Subtitles: audio and subtitle columns side by side (stacked when
/// the card is narrow), the chosen tracks checked, Add File and Search Online
/// under the subtitles, then Style, Timing, Lines and Second line, which show their
/// values and open as pages inside the same card.
struct TracksPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: PlayerSession
    /// The card's content width: two columns from 300 pt.
    let width: CGFloat
    let canSearch: Bool
    let onAddFile: () -> Void
    let onSearch: () -> Void
    @State private var page: TracksPage?
    /// The language whose subtitle tracks are open (a page in the card).
    @State private var language: String?

    init(session: PlayerSession, width: CGFloat, canSearch: Bool, initialPage: TracksPage? = nil,
         onAddFile: @escaping () -> Void, onSearch: @escaping () -> Void) {
        self.session = session; self.width = width; self.canSearch = canSearch
        self.onAddFile = onAddFile; self.onSearch = onSearch
        _page = State(initialValue: initialPage)
    }

    private var sideBySide: Bool { width >= 300 }

    var body: some View {
        @Bindable var app = app
        Group {
            if let language, page == nil,
               let group = TrackRows.languageGroups(TrackRows.subtitles(session, preferred: TrackRows.preferredLanguages(session, style: app.subtitleStyle)))
                .first(where: { $0.id == language }) {
                languagePage(group).transition(pageTransition)
            } else {
            switch page {
            case .style:
                SubtitleStylePage(style: $app.subtitleStyle, session: session, onBack: { page = nil })
                    .transition(pageTransition)
            case .timing:
                SubtitleTimingPage(session: session, onBack: { page = nil })
                    .transition(pageTransition)
            case .secondLine:
                SecondLinePage(session: session, style: $app.subtitleStyle, onBack: { page = nil })
                    .transition(pageTransition)
            case .lines:
                SubtitleLinesPage(session: session, onBack: { page = nil })
                    .transition(pageTransition)
            case nil:
                main.transition(reduceMotion ? .opacity : .push(from: .leading))
            }
            }
        }
        .animation(Motion.snappy(reduceMotion), value: page)
        .animation(Motion.snappy(reduceMotion), value: language)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio and Subtitles")
        .accessibilityIdentifier("tracksPicker")
    }

    private var pageTransition: AnyTransition { reduceMotion ? .opacity : .push(from: .trailing) }

    private var main: some View {
        let preferred = TrackRows.preferredLanguages(session, style: app.subtitleStyle)
        let audio = TrackRows.audio(session)
        let subs = TrackRows.subtitles(session, preferred: preferred)
        return VStack(alignment: .leading, spacing: 8) {
            if sideBySide {
                // Audio a little narrower than subtitles (1 : 1.15), as in the design.
                let audioWidth = audio.isEmpty ? 0 : ((width - 6) / 2.15).rounded()
                HStack(alignment: .top, spacing: 6) {
                    if !audio.isEmpty {
                        audioColumn(audio, preferred: preferred).frame(width: audioWidth, alignment: .topLeading)
                    }
                    subtitleColumn(subs, preferred: preferred)
                        .frame(width: audio.isEmpty ? width : width - audioWidth - 6, alignment: .topLeading)
                }
            } else {
                if !audio.isEmpty { audioColumn(audio, preferred: preferred) }
                subtitleColumn(subs, preferred: preferred)
            }
            if let err = session.subtitleError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Palette.separator).frame(height: 1).padding(.horizontal, 4)
            FlowLayout(spacing: 6) {
                PlayerPageChip(title: "Style", symbol: "textformat") { page = .style }
                    .accessibilityIdentifier("tracks.style")
                PlayerPageChip(title: "Timing", value: session.subtitleOffset.isDefault ? nil : session.subtitleOffset.label) { page = .timing }
                    .accessibilityIdentifier("tracks.timing")
                PlayerPageChip(title: "Lines") { page = .lines }
                    .accessibilityIdentifier("tracks.lines")
                PlayerPageChip(title: "Second Line", value: secondLineValue) { page = .secondLine }
                    .accessibilityIdentifier("tracks.secondLine")
            }
        }
    }

    private var secondLineValue: String? {
        guard let id = session.secondarySubtitleID else { return nil }
        return TrackLabel.labels(for: session.externalSubtitles + session.snapshot.embeddedSubtitles)[id]?.title
    }

    // MARK: Columns

    /// Rows a list shows before it scrolls: a phone on its side has little height.
    private var visibleRows: Int { PanelMetrics.dense ? 4 : 6 }

    private func audioColumn(_ rows: [TrackRow], preferred: [String]) -> some View {
        column("Audio", shortcut: "B") {
            scrolling(count: rows.count, selected: rows.first(where: \.selected)?.id) {
                ForEach(rows) { r in row(r) { session.selectAudio(r.id) }.id(r.id) }
            }
        }
    }

    private func subtitleColumn(_ rows: [TrackRow], preferred: [String]) -> some View {
        let groups = TrackRows.languageGroups(rows)
        return column("Subtitles", shortcut: "V") {
            // Every language, your languages first; a long list scrolls in place.
            scrolling(count: groups.count + 1, selected: groups.first(where: { $0.selected != nil })?.id) {
                row(TrackRow(id: "off", title: "Off", detail: nil, source: .video, isBitmap: false, languageCode: nil,
                             selected: session.subtitleSelection == .off, selection: .off)) { session.selectSubtitle(.off) }
                ForEach(groups) { g in groupRow(g).id(g.id) }
            }
            if rows.isEmpty {
                Text("None in this video.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
            }
            linkRow("Add File…", symbol: "plus", action: onAddFile)
            if canSearch { linkRow("Search Online…", symbol: "magnifyingglass", action: onSearch) }
        }
    }

    private func column<Content: View>(_ title: String, shortcut: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                KeyCap(shortcut)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// The rows as they are, or in a list of `visibleRows` rows that scrolls
    /// (starting at the chosen one) when there are more.
    @ViewBuilder
    private func scrolling<Rows: View>(count: Int, selected: String?, @ViewBuilder rows: () -> Rows) -> some View {
        let list = VStack(spacing: 1) { rows() }
        if count <= visibleRows + 1 {
            list
        } else {
            ScrollViewReader { proxy in
                ScrollView { list }
                .scrollIndicators(.automatic)
                // Half a row shows past the edge, so it's plain the list goes on.
                .frame(height: (Double(visibleRows) + 0.5) * (PlayerPopoverMetrics.rowHeight + 1))
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
        }
    }

    /// One language: a single track picks straight away; several open their list.
    @ViewBuilder private func groupRow(_ g: TrackLanguageGroup) -> some View {
        if g.rows.count == 1, let only = g.rows.first {
            row(TrackRow(id: only.id, title: g.title, detail: only.detail, source: only.source, isBitmap: only.isBitmap,
                         languageCode: only.languageCode, selected: only.selected, selection: only.selection,
                         format: only.format, keepsOwnStyle: only.keepsOwnStyle)) {
                if let s = only.selection { session.selectSubtitle(s) }
            }
        } else {
            let chosen = g.selected
            Button { language = g.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold)).foregroundStyle(Palette.brandBright)
                        .opacity(chosen != nil ? 1 : 0).frame(width: 14)
                        .accessibilityHidden(true)
                    Text(g.title)
                        .font(PlayerPopoverMetrics.rowFont.weight(chosen != nil ? .semibold : .regular))
                        .foregroundStyle(Palette.textPrimary).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    // Which one is on, or how many there are.
                    Text(chosen?.tag ?? "\(g.rows.count)")
                        .font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(chosen != nil ? Palette.textSecondary : Palette.textTertiary).lineLimit(1)
                    Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: PlayerPopoverMetrics.rowHeight)
                .background {
                    if chosen != nil {
                        RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous).fill(Palette.wash)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous))
            }
            .buttonStyle(PopoverRowStyle())
            .accessibilityLabel("\(g.title), \(g.rows.count) tracks" + (chosen.map { ", \($0.tag ?? "on")" } ?? ""))
            .accessibilityAddTraits(chosen != nil ? .isSelected : [])
        }
    }

    /// A language's tracks: picking one turns it on and goes back.
    private func languagePage(_ g: TrackLanguageGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PlayerPageHeader("\(g.title) Subtitles", onBack: { language = nil })
            VStack(spacing: 1) {
                ForEach(g.rows) { r in
                    PanelPickRow(title: r.detail ?? "Standard", detail: languagePageDetail(r, in: g), selected: r.selected) {
                        if let s = r.selection { session.selectSubtitle(s) }
                        language = nil
                    }
                }
            }
            Text("SDH adds sound cues for the deaf and hard of hearing. Forced shows only foreign-language lines. ASS tracks keep their own look.")
                .font(.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    /// Under each track: its region or name when that differs, and where it's from.
    private func languagePageDetail(_ r: TrackRow, in g: TrackLanguageGroup) -> String? {
        var parts: [String] = []
        if r.detail != nil, r.title != g.title { parts.append(r.title) }
        let source = switch r.source {
        case .video: "In the video"
        case .added: "Added file"
        case .torrent: "In the torrent"
        case .file: "Subtitle file"
        }
        parts.append(source)
        return parts.joined(separator: " · ")
    }

    private func linkRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.bold)).frame(width: 14)
                Text(title).font(PlayerPopoverMetrics.rowFont).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.brandBright)
            .padding(.horizontal, 6)
            .frame(minHeight: PlayerPopoverMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowStyle())
    }

    private func row(_ r: TrackRow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.brandBright)
                    .opacity(r.selected ? 1 : 0)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(r.title)
                    .font(PlayerPopoverMetrics.rowFont.weight(r.selected ? .semibold : .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // Both: two English files are told apart by "SDH" or "2 of 2".
                if let tag = r.tag {
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .help(tag)
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: PlayerPopoverMetrics.rowHeight)
            .background {
                if r.selected {
                    RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous).fill(Palette.wash)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(PopoverRowStyle())
        .accessibilityLabel([r.title, r.detail, r.sourceLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(r.selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: r.selected) { _, new in new }
    }
}

/// The chapter list, opened from the chapter name above the timeline.
struct ChaptersPanel: View {
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlayerCardHeader("Chapters") { KeyCap("N P") }
            ScrollViewReader { proxy in
                VStack(spacing: 1) {
                    ForEach(Array(session.snapshot.chapters.enumerated()), id: \.offset) { i, c in
                        let current = session.currentChapterIndex == i
                        Button { Task { await session.seek(to: c.start) } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Palette.brandBright)
                                    .opacity(current ? 1 : 0).frame(width: 14)
                                Text(c.title.isEmpty ? "Chapter \(i + 1)" : c.title)
                                    .font(PlayerPopoverMetrics.rowFont.weight(current ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: Spacing.s)
                                Text(Formatters.duration(c.start)).font(.caption).monospacedDigit().foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, 6)
                            .frame(minHeight: PlayerPopoverMetrics.rowHeight)
                            .background {
                                if current { RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous).fill(Palette.wash) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PopoverRowStyle())
                        .id(i)
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
                .onAppear { if let i = session.currentChapterIndex { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chaptersPanel")
    }
}
