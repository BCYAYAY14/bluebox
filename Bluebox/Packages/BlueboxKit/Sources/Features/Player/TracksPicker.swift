import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// One audio or subtitle track as people read it: "English (US)" with "SDH"
/// underneath, not VLC's "English (SDH / US) - [English]".
struct TrackRow: Identifiable, Equatable {
    enum Source: Equatable { case video, file, added }
    let id: String
    let title: String
    let detail: String?
    let source: Source
    let isBitmap: Bool
    let languageCode: String?
    let selected: Bool
    let selection: SubtitleSelection?

    /// "Subtitle file" / "Added": only files are marked; tracks in the video are the norm.
    var sourceLabel: String? {
        switch source {
        case .video: nil
        case .file: "File"
        case .added: "Added"
        }
    }
}

/// Builds the rows for the picker and the subtitle panel: cleaned names,
/// duplicates numbered, the languages you use first.
@MainActor
enum TrackRows {
    static func audio(_ session: PlayerSession) -> [TrackRow] {
        let tracks = session.snapshot.audioTracks
        let labels = TrackLabel.labels(for: tracks)
        return tracks.map { t in
            let l = labels[t.id] ?? TrackLabel(title: t.label)
            return TrackRow(id: t.id, title: l.title, detail: l.detail, source: .video, isBitmap: false,
                            languageCode: l.languageCode, selected: session.snapshot.selectedAudioID == t.id, selection: nil)
        }
    }

    static func subtitles(_ session: PlayerSession, preferred: [String]) -> [TrackRow] {
        let embedded = session.snapshot.embeddedSubtitles
        let external = session.externalSubtitles
        let labels = TrackLabel.labels(for: embedded + external)
        let rows = (embedded + external).map { t in
            let l = labels[t.id] ?? TrackLabel(title: t.label)
            let selection: SubtitleSelection = t.isExternal ? .external(t.id) : .embedded(t.id)
            let source: TrackRow.Source = !t.isExternal ? .video : t.id.hasPrefix("import-") ? .added : .file
            return TrackRow(id: t.id, title: l.title, detail: l.detail, source: source, isBitmap: t.isBitmap,
                            languageCode: l.languageCode, selected: session.subtitleSelection == selection, selection: selection)
        }
        return ordered(rows, preferred: preferred)
    }

    /// Languages you use first (in the file's order), then the rest A to Z.
    static func ordered(_ rows: [TrackRow], preferred: [String]) -> [TrackRow] {
        let prefs = preferred.map(TrackChoice.normalized)
        func rank(_ r: TrackRow) -> Int { r.languageCode.flatMap { prefs.firstIndex(of: $0) } ?? Int.max }
        let mine = rows.filter { rank($0) != .max }.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let rest = rows.filter { rank($0) == .max }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        // Added files lead: you just went looking for them.
        let added = (mine + rest).filter { $0.source == .added }
        return added + (mine + rest).filter { $0.source != .added }
    }

    /// The languages that go first: your subtitle language, what you picked
    /// last, then your device languages.
    static func preferredLanguages(_ session: PlayerSession, style: SubtitleStyle) -> [String] {
        var out: [String] = []
        for code in [style.preferredLanguage, session.rememberedSubtitle?.languageCode, session.rememberedAudio?.languageCode]
            + Locale.preferredLanguages.prefix(3).map(Optional.some) {
            if let code, !out.contains(TrackChoice.normalized(code)) { out.append(TrackChoice.normalized(code)) }
        }
        return out
    }

    /// Long lists show the first few, the selected one, and a "More Languages" disclosure.
    static func split(_ rows: [TrackRow], preferred: [String], limit: Int = 6) -> (shown: [TrackRow], more: [TrackRow]) {
        guard rows.count > limit + 2 else { return (rows, []) }
        let prefs = preferred.map(TrackChoice.normalized)
        var shown = rows.filter { r in r.source != .video || r.selected || r.languageCode.map(prefs.contains) == true }
        if shown.count < limit {
            shown += rows.filter { r in !shown.contains(r) }.prefix(limit - shown.count)
        }
        let shownIDs = Set(shown.map(\.id))
        return (rows.filter { shownIDs.contains($0.id) }, rows.filter { !shownIDs.contains($0.id) })
    }
}
