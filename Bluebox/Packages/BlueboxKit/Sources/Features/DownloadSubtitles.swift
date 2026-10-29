import Domain
import Downloads
import Foundation
import Metadata

// Subtitles with downloads: once a movie or episode is saved, a subtitle in
// the profile's language is fetched from OpenSubtitles and kept beside it,
// so it plays offline with subtitles. Settings › Downloads › Subtitles With
// Downloads; needs an OpenSubtitles key and a subtitle language.

enum DownloadSubtitles {
    /// The language to fetch for `record`, or nil when it already has one in
    /// it (a debrid or Jellyfin download can bring its own).
    static func languageToFetch(preferred: String?, record: DownloadRecord) -> String? {
        guard let preferred, !preferred.isEmpty else { return nil }
        let has = record.subtitleFiles.contains { $0.languageCode.map { AppModel.sameLanguage($0, preferred) } ?? false }
        return has ? nil : preferred
    }

    /// Human-made before machine-translated, then the most downloaded (the search's order).
    static func best(_ results: [SubtitleSearchResult], language: String) -> SubtitleSearchResult? {
        results.filter { $0.language.map { AppModel.sameLanguage($0, language) } ?? false }
            .min { ($0.machineTranslated ? 1 : 0, -$0.downloadCount) < ($1.machineTranslated ? 1 : 0, -$1.downloadCount) }
    }
}

extension AppModel {
    /// Fetches a subtitle for a finished download when Settings asks for one.
    /// Quiet on failure: it's a nicety, and the player can still search.
    func fetchSubtitles(for record: DownloadRecord) async {
        guard downloadSettings.fetchSubtitles, hasOpenSubtitlesKey, let key = record.mediaKey,
              let lang = DownloadSubtitles.languageToFetch(preferred: subtitleStyle.preferredLanguage, record: record),
              let service = subtitleSearch else { return }
        do {
            let results = try await service.search(key, languages: [lang])
            guard let best = DownloadSubtitles.best(results, language: lang) else { return }
            let data = try await service.download(best)
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            try downloads.addSubtitle(data, languageCode: lang, label: "\(name) (OpenSubtitles)", format: "srt", to: record.id)
            Log.sources.info("Saved \(lang, privacy: .public) subtitles with \(record.title, privacy: .public)")
        } catch {
            Log.sources.info("No subtitles saved with \(record.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
