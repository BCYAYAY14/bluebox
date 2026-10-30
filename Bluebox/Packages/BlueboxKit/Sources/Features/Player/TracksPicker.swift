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
    /// "ASS", "SRT", "PGS": shown when it tells tracks of one language apart.
    var format: String? = nil
    /// Draws in the file's own look (ASS in the video), not the subtitle style.
    var keepsOwnStyle = false

    /// What's shown at the row's end: the detail and where it's from ("SDH · File").
    var tag: String? {
        let parts = [detail, sourceLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Subtitle file" / "Added": only files are marked; tracks in the video are the norm.
    var sourceLabel: String? {
        switch source {
        case .video: nil
        case .file: "File"
        case .added: "Added"
        }
    }
}

/// One language in the subtitle list and its tracks ("English": plain, SDH, ASS, a file).
struct TrackLanguageGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let languageCode: String?
    let rows: [TrackRow]
    var selected: TrackRow? { rows.first(where: \.selected) }
}

/// Builds the rows for the picker and the subtitle panel: cleaned names,
/// duplicates numbered, the languages you use first.
///
/// The card asks again on every redraw (the player's state changes several
/// times a second while it plays) and a video can carry 40 subtitle tracks,
/// so the last answer is kept until the tracks, the choice or the languages change.
@MainActor
enum TrackRows {
    private struct AudioKey: Equatable { let tracks: [MediaTrack]; let selected: String? }
    private struct SubtitleKey: Equatable {
        let embedded: [MediaTrack]; let external: [MediaTrack]; let selection: SubtitleSelection; let preferred: [String]
    }
    private static var audioCache: (AudioKey, [TrackRow])?
    private static var subtitleCache: (SubtitleKey, [TrackRow])?
    private static var groupCache: ([TrackRow], [TrackLanguageGroup])?

    static func audio(_ session: PlayerSession) -> [TrackRow] {
        let key = AudioKey(tracks: session.snapshot.audioTracks, selected: session.snapshot.selectedAudioID)
        if let (k, rows) = audioCache, k == key { return rows }
        let tracks = key.tracks
        let labels = TrackLabel.labels(for: tracks)
        let rows = tracks.map { t in
            let l = labels[t.id] ?? TrackLabel(title: t.label)
            return TrackRow(id: t.id, title: l.title, detail: l.detail, source: .video, isBitmap: false,
                            languageCode: l.languageCode, selected: key.selected == t.id, selection: nil)
        }
        audioCache = (key, rows)
        return rows
    }

    static func subtitles(_ session: PlayerSession, preferred: [String]) -> [TrackRow] {
        let key = SubtitleKey(embedded: session.snapshot.embeddedSubtitles, external: session.externalSubtitles,
                              selection: session.subtitleSelection, preferred: preferred)
        if let (k, rows) = subtitleCache, k == key { return rows }
        let rows = makeSubtitles(key)
        subtitleCache = (key, rows)
        return rows
    }

    private static func makeSubtitles(_ key: SubtitleKey) -> [TrackRow] {
        let embedded = key.embedded, external = key.external, preferred = key.preferred
        let labels = TrackLabel.labels(for: embedded + external)
        let tracks = embedded + external
        let details = distinctDetails(tracks, labels: labels)
        let rows = tracks.map { t in
            let l = labels[t.id] ?? TrackLabel(title: t.label)
            let selection: SubtitleSelection = t.isExternal ? .external(t.id) : .embedded(t.id)
            let source: TrackRow.Source = !t.isExternal ? .video : t.id.hasPrefix("import-") ? .added : .file
            return TrackRow(id: t.id, title: l.title, detail: details[t.id] ?? nil, source: source, isBitmap: t.isBitmap,
                            languageCode: l.languageCode, selected: key.selection == selection, selection: selection,
                            format: t.format, keepsOwnStyle: t.keepsOwnStyle)
        }
        return ordered(rows, preferred: preferred)
    }

    /// Details that tell tracks with the same name apart: "SDH", "Forced",
    /// then the format ("ASS", "SRT") when that differs, and only then a number
    /// ("2 of 3"), never VLC's "Track 7".
    static func distinctDetails(_ tracks: [MediaTrack], labels: [String: TrackLabel]) -> [String: String?] {
        var out: [String: String?] = [:]
        let parsed = tracks.map { t -> (MediaTrack, TrackLabel) in
            var l = labels[t.id] ?? TrackLabel(title: t.label)
            l.details.removeAll { $0.range(of: #"^Track \d+$"#, options: .regularExpression) != nil }
            return (t, l)
        }
        let groups = Dictionary(grouping: parsed, by: { $0.1.title })
        for (_, group) in groups {
            let formats = Set(group.map { $0.0.format ?? "" })
            var withFormat = group.map { t, l in
                (t.id, l.details + (group.count > 1 && formats.count > 1 ? [t.format].compactMap { $0 } : []))
            }
            // Still the same: number them in the file's order.
            let counts = Dictionary(grouping: withFormat, by: { $0.1 }).mapValues(\.count)
            var seen: [[String]: Int] = [:]
            for i in withFormat.indices where counts[withFormat[i].1, default: 0] > 1 {
                let key = withFormat[i].1
                seen[key, default: 0] += 1
                withFormat[i].1.append("\(seen[key]!) of \(counts[key]!)")
            }
            for (id, parts) in withFormat { out[id] = parts.isEmpty ? nil : parts.joined(separator: " · ") }
        }
        return out
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

    /// Subtitle rows by language, in the rows' order (your languages first):
    /// one row per language in the list, its tracks a tap away.
    static func languageGroups(_ rows: [TrackRow], locale: Locale = .current) -> [TrackLanguageGroup] {
        if locale == .current, let (r, groups) = groupCache, r == rows { return groups }
        let groups = makeGroups(rows, locale: locale)
        if locale == .current { groupCache = (rows, groups) }
        return groups
    }

    private static func makeGroups(_ rows: [TrackRow], locale: Locale) -> [TrackLanguageGroup] {
        var order: [String] = []
        var byKey: [String: [TrackRow]] = [:]
        for r in rows {
            let key = r.languageCode.map { "lang:" + TrackChoice.normalized($0) } ?? "name:" + r.title
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(r)
        }
        return order.map { key in
            let members = byKey[key] ?? []
            let code = members.first?.languageCode.map(TrackChoice.normalized)
            let name = code.flatMap { locale.localizedString(forLanguageCode: $0) }.map { $0.capitalized(with: locale) }
            return TrackLanguageGroup(id: key, title: name ?? members.first?.title ?? "Unknown", languageCode: code, rows: members)
        }
    }

    /// Long language lists show your languages, the chosen one and added files, then "More".
    static func split(_ groups: [TrackLanguageGroup], preferred: [String], limit: Int = 6)
        -> (shown: [TrackLanguageGroup], more: [TrackLanguageGroup]) {
        guard groups.count > limit + 2 else { return (groups, []) }
        let prefs = preferred.map(TrackChoice.normalized)
        var shown = groups.filter { g in
            g.selected != nil || g.rows.contains { $0.source == .added } || g.languageCode.map(prefs.contains) == true
        }
        if shown.count < limit { shown += groups.filter { !shown.contains($0) }.prefix(limit - shown.count) }
        let ids = Set(shown.map(\.id))
        return (groups.filter { ids.contains($0.id) }, groups.filter { !ids.contains($0.id) })
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
