import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// A page inside the Audio & Subtitles card.
enum TracksPage: String, CaseIterable { case style, timing, secondLine }

/// Audio & Subtitles: audio and subtitle columns side by side (stacked when
/// the card is narrow), the chosen tracks checked, Add File and Search Online
/// under the subtitles, then Style, Timing and Second line, which show their
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
    @State private var showsMoreSubtitles = false
    @State private var showsMoreAudio = false

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
            switch page {
            case .style:
                SubtitleStylePage(style: $app.subtitleStyle, note: subtitleStyleNote(session), onBack: { page = nil })
                    .transition(pageTransition)
            case .timing:
                SubtitleTimingPage(session: session, onBack: { page = nil })
                    .transition(pageTransition)
            case .secondLine:
                SecondLinePage(session: session, style: $app.subtitleStyle, onBack: { page = nil })
                    .transition(pageTransition)
            case nil:
                main.transition(reduceMotion ? .opacity : .push(from: .leading))
            }
        }
        .animation(Motion.snappy(reduceMotion), value: page)
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
                PlayerPageChip(title: "Second Line", value: secondLineValue) { page = .secondLine }
                    .accessibilityIdentifier("tracks.secondLine")
            }
        }
    }

    private var secondLineValue: String? {
        guard let id = session.secondarySubtitleID else { return nil }
        return TrackLabel.labels(for: session.externalSubtitles)[id]?.title
    }

    // MARK: Columns

    private func audioColumn(_ rows: [TrackRow], preferred: [String]) -> some View {
        let parts = TrackRows.split(rows, preferred: preferred)
        return column("Audio", shortcut: "B") {
            ForEach(parts.shown) { r in row(r) { session.selectAudio(r.id) } }
            more(parts.more, expanded: $showsMoreAudio) { r in session.selectAudio(r.id) }
        }
    }

    private func subtitleColumn(_ rows: [TrackRow], preferred: [String]) -> some View {
        let parts = TrackRows.split(rows, preferred: preferred)
        return column("Subtitles", shortcut: "V") {
            row(TrackRow(id: "off", title: "Off", detail: nil, source: .video, isBitmap: false, languageCode: nil,
                         selected: session.subtitleSelection == .off, selection: .off)) { session.selectSubtitle(.off) }
            ForEach(parts.shown) { r in row(r) { if let s = r.selection { session.selectSubtitle(s) } } }
            more(parts.more, expanded: $showsMoreSubtitles) { r in if let s = r.selection { session.selectSubtitle(s) } }
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

    @ViewBuilder
    private func more(_ rows: [TrackRow], expanded: Binding<Bool>, pick: @escaping (TrackRow) -> Void) -> some View {
        if !rows.isEmpty {
            Button { withAnimation(.snappy(duration: 0.25)) { expanded.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .frame(width: 14)
                    Text(expanded.wrappedValue ? "Fewer" : "More (\(rows.count))")
                        .font(PlayerPopoverMetrics.rowFont.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 6)
                .frame(minHeight: PlayerPopoverMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowStyle())
            if expanded.wrappedValue {
                ForEach(rows) { r in row(r) { pick(r) } }
            }
        }
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
                if let tag = r.sourceLabel ?? r.detail {
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
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
