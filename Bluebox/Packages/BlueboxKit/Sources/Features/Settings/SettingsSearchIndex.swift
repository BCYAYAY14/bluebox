import Foundation

/// Every setting by name, so Settings search can find it. Add a line here
/// when you add a setting.
enum SettingsSearchIndex {
    struct Entry: Identifiable, Hashable, Sendable {
        let title: String
        let page: SettingsPage
        let section: String
        var keywords: [String] = []
        /// iPhone and iPad only (hidden from the Mac's search).
        var phoneOnly = false
        /// A page one level down from `page` that holds the row ("Torrent Engine").
        var subpage: String?
        var id: String { "\(page.rawValue)/\(subpage.map { $0 + "/" } ?? "")\(section)/\(title)" }
        var location: String {
            if let subpage { return "\(page.title) › \(subpage)" }
            return section.isEmpty ? page.title : "\(page.title) › \(section)"
        }
    }

    private static let engine = TorrentEngineSettingsPage.title

    static let entries: [Entry] = [
        // Account & Sync
        .init(title: "Supabase Project", page: .account, section: "Account", keywords: ["server", "sync", "url", "anon key", "backend"]),
        .init(title: "Sign In", page: .account, section: "Account", keywords: ["email", "code", "apple", "sign out", "login"]),
        .init(title: "Sync Now", page: .account, section: "Account", keywords: ["cloud", "icloud"]),
        .init(title: "Change Server", page: .account, section: "Server", keywords: ["disconnect", "project"]),
        .init(title: "Trakt", page: .account, section: "Trakt", keywords: ["watchlist", "history", "scrobble"]),
        // Profiles
        .init(title: "Add Profile", page: .profiles, section: "Profiles", keywords: ["kids", "user", "who's watching"]),
        .init(title: "Switch Profile", page: .profiles, section: "Profiles"),
        .init(title: "Edit Profile", page: .profiles, section: "Profiles", keywords: ["name", "avatar", "colour", "color", "delete", "pin", "lock", "kids", "maturity", "rating"]),
        // The profile's own pages
        .init(title: "Audio Language", page: .languages, section: "Audio", keywords: ["dub", "track", "language"]),
        .init(title: "Preferred Language", page: .languages, section: "Subtitles", keywords: ["captions", "subtitle language"]),
        .init(title: "Second Language", page: .languages, section: "Subtitles", keywords: ["dual subtitles", "learn"]),
        .init(title: "Autoplay Next Episode", page: .myPlayback, section: "Episodes", keywords: ["up next", "binge", "auto play"]),
        // Playback
        .init(title: "Player", page: .playback, section: "Player", keywords: ["engine", "vlc", "avplayer", "mkv", "picture in picture", "airplay"]),
        .init(title: "Start Playing", page: .playback, section: "Starting Playback", keywords: ["resume", "continue", "beginning", "start over"]),
        .init(title: "Default Speed", page: .playback, section: "Starting Playback", keywords: ["rate", "faster", "slower"]),
        .init(title: "Skip Back", page: .playback, section: "Controls", keywords: ["rewind", "interval", "seconds", "arrow"]),
        .init(title: "Skip Forward", page: .playback, section: "Controls", keywords: ["fast forward", "interval", "seconds", "arrow"]),
        .init(title: "Countdown", page: .playback, section: "Episodes", keywords: ["up next", "timer", "autoplay"]),
        .init(title: "Stream over Cellular", page: .playback, section: "Network", keywords: ["wifi", "wi-fi", "mobile data", "network"], phoneOnly: true),
        .init(title: "Skip Intro", page: .playback, section: "Skipping", keywords: ["recap", "opening", "automatic", "button"]),
        .init(title: "Skip Credits", page: .playback, section: "Skipping", keywords: ["end credits", "next episode", "outro"]),
        .init(title: "Skip Recap", page: .playback, section: "Skipping", keywords: ["previously on", "recap", "automatic"]),
        .init(title: "Always Skipping", page: .playback, section: "Skipping", keywords: ["always for this show", "skip intro", "skip credits", "per show"]),
        .init(title: "Shows with Skipping Off", page: .playback, section: "Skipping", keywords: ["skip intro", "don't skip", "list"]),
        .init(title: "Community Intro Timestamps", page: .playback, section: "Community Intro Timestamps", keywords: ["theintrodb", "introdb", "crowd", "wrong time", "ignoring community times"]),
        .init(title: "Dialogue Boost", page: .playback, section: "Audio", keywords: ["speech", "voices", "centre", "center", "clarity"]),
        .init(title: "Equaliser", page: .playback, section: "Equaliser", keywords: ["equalizer", "eq", "bass", "treble", "sound", "audio", "preset"]),
        .init(title: "Night Mode", page: .playback, section: "Audio", keywords: ["loud", "quiet", "compressor", "volume", "late"]),
        .init(title: "Always Open in Infuse", page: .playback, section: "External Player", keywords: ["infuse", "external", "player", "dolby vision", "atmos"]),
        .init(title: "Preview Thumbnails While Scrubbing", page: .playback, section: "Player", keywords: ["scrub", "seek", "timeline", "frames"]),
        .init(title: "Handoff", page: .playback, section: "Player", keywords: ["continuity", "other devices", "iphone", "ipad", "mac"]),
        .init(title: "Autoplay Previews", page: .playback, section: "Previews", keywords: ["trailer", "hero", "video", "muted"]),
        .init(title: "Scrobble What You Watch", page: .playback, section: "Trakt", keywords: ["trakt", "history", "now watching"]),
        // Subtitles
        .init(title: "Default Delay", page: .subtitles, section: "Timing", keywords: ["offset", "sync", "timing"]),
        .init(title: "Subtitle Style", page: .subtitles, section: "Presets", keywords: ["font", "size", "colour", "color", "outline", "shadow", "background", "position", "preset", "weight", "alignment", "atkinson", "inter", "large print", "save look"]),
        .init(title: "OpenSubtitles API Key", page: .subtitles, section: "Subtitle Search", keywords: ["search", "download"]),
        .init(title: "Search Automatically", page: .subtitles, section: "Subtitle Search", keywords: ["opensubtitles", "auto"]),
        .init(title: "Subdl API Key", page: .subtitles, section: "Search Online", keywords: ["subdl", "subtitle sites", "search"]),
        .init(title: "Search Online Sites", page: .subtitles, section: "Search Online",
              keywords: ["opensubtitles", "subdl", "podnapisi", "jellyfin", "subtitle sites"]),
        // Picture
        .init(title: "Brightness", page: .picture, section: "Every Video Starts With", keywords: ["picture", "video", "dark", "light"]),
        .init(title: "Contrast", page: .picture, section: "Every Video Starts With", keywords: ["picture", "video"]),
        .init(title: "Saturation", page: .picture, section: "Every Video Starts With", keywords: ["picture", "video", "colour", "color", "vivid"]),
        // Mobile Data (iPhone and iPad)
        .init(title: "Streaming on Mobile Data", page: .mobileData, section: "Streaming", keywords: ["cellular", "ask first", "wifi", "wi-fi", "4g", "5g"], phoneOnly: true),
        .init(title: "Video Quality on Mobile Data", page: .mobileData, section: "Streaming", keywords: ["data saver", "cellular", "720p", "1080p", "resolution"], phoneOnly: true),
        .init(title: "Torrents on Mobile Data", page: .mobileData, section: "Torrents", keywords: ["cellular", "debrid only", "peer to peer", "p2p"], phoneOnly: true),
        .init(title: "Downloads on Wi‑Fi Only", page: .mobileData, section: "Downloads", keywords: ["cellular", "wifi", "mobile data"], phoneOnly: true),
        .init(title: "Data Used This Month", page: .mobileData, section: "Data Used", keywords: ["cellular", "usage", "counter", "reset", "low data mode"], phoneOnly: true),
        // Torrents & Debrid
        .init(title: "Find Releases with Add-ons", page: .torrents, section: "", keywords: ["stremio", "torrentio", "stremthru", "comet"]),
        .init(title: "Add-ons", page: .torrents, section: "Add-ons", keywords: ["stremio", "manifest", "add by link", "install", "order", "priority", "health", "torrentio", "stremthru", "comet"]),
        .init(title: "Test Add-ons", page: .torrents, section: "Add-ons"),
        .init(title: "Debrid Service", page: .torrents, section: "Debrid", keywords: ["real-debrid", "realdebrid", "premiumize", "alldebrid", "torbox", "debridlink", "api key"]),
        .init(title: "Share Key with Community Add-ons", page: .torrents, section: "Debrid", keywords: ["stremthru", "comet", "api key"]),
        .init(title: "Check What's Cached", page: .torrents, section: "Debrid", keywords: ["cache", "instant", "torbox", "premiumize"]),
        .init(title: "Same Group Next Episode", page: .torrents, section: "Releases", keywords: ["release group", "binge", "remember", "episode"]),
        .init(title: "Upload Limit", page: .torrents, section: "Uploads and Cache", keywords: ["seeding", "upload", "share"], subpage: engine),
        .init(title: "Add-on Timeout", page: .torrents, section: "Advanced", keywords: ["slow", "wait", "seconds"], subpage: engine),
        .init(title: "Sort By", page: .torrents, section: "Releases", keywords: ["seeders", "size", "quality"]),
        .init(title: "Preferred Resolution", page: .torrents, section: "Releases", keywords: ["4k", "1080p", "720p", "quality"]),
        .init(title: "Hidden Qualities", page: .torrents, section: "Releases", keywords: ["cam", "screener", "filter"]),
        .init(title: "Maximum Peers", page: .torrents, section: "Streaming", keywords: ["connections", "speed"], subpage: engine),
        .init(title: "Torrents Tried at Once", page: .torrents, section: "Streaming", keywords: ["race", "speed", "start"], subpage: engine),
        .init(title: "Start Playing After", page: .torrents, section: "Streaming", keywords: ["buffer", "prebuffer", "speed"], subpage: engine),
        .init(title: "Buffer at Most", page: .torrents, section: "Streaming", keywords: ["buffer", "prebuffer"], subpage: engine),
        .init(title: "Find Releases Early", page: .torrents, section: "Releases", keywords: ["prefetch", "speed", "start"]),
        .init(title: "Keep Streams", page: .torrents, section: "Uploads and Cache", keywords: ["cache size", "stream cache"], subpage: engine),
        .init(title: "Clear Stream Cache", page: .torrents, section: "Uploads and Cache", keywords: ["delete", "space"], subpage: engine),
        .init(title: "Extra Trackers", page: .torrents, section: "Advanced", keywords: ["announce", "udp"], subpage: engine),
        .init(title: "Stream Server Port", page: .torrents, section: "Advanced", keywords: ["localhost", "port"], subpage: engine),
        .init(title: "StremThru Server", page: .torrents, section: "Advanced", keywords: ["host", "self-hosted"], subpage: engine),
        .init(title: "Torrent Engine", page: .torrents, section: "Advanced", keywords: ["libtorrent", "peers", "buffer", "upload", "cache", "port"]),
        // Downloads
        .init(title: "Downloads Space Used", page: .downloads, section: "On This Device", keywords: ["storage", "offline"]),
        .init(title: "Manage Downloads", page: .downloads, section: "On This Device", keywords: ["delete", "pause", "resume", "offline"]),
        .init(title: "Simultaneous Downloads", page: .downloads, section: "Downloading", keywords: ["queue", "concurrent", "at once"]),
        .init(title: "Wi‑Fi Only", page: .downloads, section: "Downloading", keywords: ["cellular", "data", "wifi"], phoneOnly: true),
        .init(title: "Smart Downloads", page: .downloads, section: "Smart Downloads",
              keywords: ["next episode", "delete after watching", "auto", "series"]),
        .init(title: "Keep Next Episodes", page: .downloads, section: "Smart Downloads", keywords: ["series", "auto"]),
        .init(title: "Delete Watched Films", page: .downloads, section: "Smart Downloads", keywords: ["remove", "space", "movies"]),
        .init(title: "Storage Limit", page: .downloads, section: "Smart Downloads", keywords: ["space", "gb", "full", "make room"]),
        .init(title: "Delete After Watching", page: .downloads, section: "Smart Downloads", keywords: ["episodes", "remove", "watched"]),
        .init(title: "Smart Downloads Can Delete Watched Downloads", page: .downloads, section: "What Bluebox Does on Its Own",
              keywords: ["delete", "remove", "automatic", "make room"]),
        .init(title: "Follow Watching on Other Devices", page: .downloads, section: "What Bluebox Does on Its Own",
              keywords: ["sync", "trakt", "other devices", "progress"]),
        .init(title: "Download Window", page: .downloads, section: "What Bluebox Does on Its Own",
              keywords: ["overnight", "night", "charging", "battery", "schedule"]),
        .init(title: "Subtitles With Downloads", page: .downloads, section: "What Bluebox Does on Its Own",
              keywords: ["offline", "opensubtitles", "captions"]),
        .init(title: "Download Quality", page: .downloads, section: "Quality", keywords: ["resolution", "1080p", "4k", "720p", "cap"]),
        .init(title: "Largest Episode", page: .downloads, section: "Quality", keywords: ["size", "gb", "cap", "max"]),
        .init(title: "Download Audio", page: .downloads, section: "Quality", keywords: ["language", "dub"]),
        .init(title: "Keep Downloading in the Background", page: .downloads, section: "Downloading", keywords: ["background", "battery", "torrent", "lock"], phoneOnly: true),
        .init(title: "Keep Screen Awake While Downloading", page: .downloads, section: "Downloading", keywords: ["sleep", "lock", "torrent"], phoneOnly: true),
        // Sources
        .init(title: "Add Folder", page: .sources, section: "Sources", keywords: ["local", "files"]),
        .init(title: "Add Jellyfin Server", page: .sources, section: "Sources", keywords: ["media server", "plex", "emby"]),
        .init(title: "Open Movies", page: .sources, section: "Sources", keywords: ["blender", "creative commons"]),
        .init(title: "Test All Sources", page: .sources, section: "Sources", keywords: ["connection"]),
        .init(title: "Add Link", page: .sources, section: "Direct Links", keywords: ["url", "hls", "m3u8", "mp4"]),
        .init(title: "Add Torrent", page: .sources, section: "Your Torrents", keywords: ["magnet", ".torrent"]),
        .init(title: "Debrid Library", page: .sources, section: "Debrid Library", keywords: ["real-debrid", "premiumize", "alldebrid", "torbox", "cloud", "saved"]),
        // Catalog & Ratings
        .init(title: "TMDB Token", page: .catalog, section: "Catalog", keywords: ["api key", "themoviedb", "metadata", "sample"]),
        .init(title: "OMDb API Key", page: .catalog, section: "Ratings", keywords: ["imdb", "rotten tomatoes", "metacritic"]),
        // Privacy & Features
        .init(title: "Statistics", page: .privacy, section: "This Profile", keywords: ["my bluebox", "year in bluebox", "hours watched", "stats", "history"]),
        .init(title: "Spoiler Guard", page: .privacy, section: "This Profile", keywords: ["spoilers", "blur", "synopsis", "hide"]),
        .init(title: "Rows Based on Your Taste", page: .privacy, section: "This Profile", keywords: ["top picks", "because you watched", "personalised", "personalized", "recommendations"]),
        .init(title: "Release Alerts", page: .privacy, section: "Your Account", keywords: ["notify", "notifications", "my list", "available", "digital release", "debrid", "cached"]),
        .init(title: "Smart Downloads Can Delete Watched Downloads", page: .privacy, section: "Your Account", keywords: ["delete", "storage", "make room"]),
        .init(title: "Follow Watching on Other Devices", page: .privacy, section: "Your Account", keywords: ["trakt", "sync", "smart downloads"]),
        .init(title: "Downloads Live Activity", page: .privacy, section: "This Device", keywords: ["lock screen", "dynamic island"], phoneOnly: true),
        .init(title: "Allow Remote Control of This Device", page: .privacy, section: "This Device", keywords: ["remote", "control", "realtime"]),
        .init(title: "Use This Device as a Remote", page: .privacy, section: "This Device", keywords: ["remote", "control", "iphone"]),
        // Notifications
        .init(title: "New Episodes", page: .notifications, section: "New Episodes", keywords: ["alerts", "notify", "push", "series"]),
        .init(title: "Download New Episodes Automatically", page: .notifications, section: "New Episodes", keywords: ["auto download", "series", "offline"]),
        // Storage
        .init(title: "Clear Artwork", page: .storage, section: "Caches", keywords: ["images", "posters", "cache"]),
        .init(title: "Clear Catalog Data", page: .storage, section: "Caches", keywords: ["metadata", "cache"]),
        .init(title: "Clear Downloaded Subtitles", page: .storage, section: "Caches", keywords: ["cache"]),
        .init(title: "Clear All Caches", page: .storage, section: "Caches", keywords: ["space", "storage"]),
        .init(title: "Clear Search History", page: .storage, section: "History", keywords: ["recent searches", "privacy"]),
        .init(title: "Reset All Settings", page: .storage, section: "Reset", keywords: ["defaults", "factory"]),
        .init(title: "Erase All Data", page: .storage, section: "Reset", keywords: ["reset app", "factory", "wipe", "delete everything", "start over"]),
        // Advanced
        .init(title: "Torrent Diagnostics", page: .advanced, section: "Diagnostics", keywords: ["peers", "debug", "metrics"]),
        .init(title: "App Log", page: .advanced, section: "Diagnostics", keywords: ["debug", "logs"]),
        .init(title: "Export Logs", page: .advanced, section: "Diagnostics", keywords: ["share", "debug", "bug report"]),
        .init(title: "Play Intro at Launch", page: .advanced, section: "Launch", keywords: ["animation", "ident", "onboarding"]),
        // About
        .init(title: "Version", page: .about, section: "", keywords: ["build"]),
        .init(title: "Check for Updates", page: .about, section: "Updates", keywords: ["update", "new version", "upgrade", "github"]),
        .init(title: "Privacy", page: .about, section: "", keywords: ["data"]),
        .init(title: "Acknowledgements", page: .about, section: "", keywords: ["licenses", "credits", "tmdb", "libtorrent", "vlc", "open source"]),
    ]

    static func isAvailable(_ e: Entry) -> Bool {
        #if os(iOS)
        true
        #else
        !e.phoneOnly
        #endif
    }

    /// Entries matching every word of `query`, by title first, then by keyword.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func haystack(_ e: Entry) -> String { ([e.title, e.section, e.page.title] + e.keywords).joined(separator: " ").lowercased() }
        let hits = entries.filter { e in isAvailable(e) && words.allSatisfy { haystack(e).contains($0) } }
        // Title matches first, keeping the index order within each group.
        let inTitle = hits.filter { e in words.allSatisfy { e.title.lowercased().contains($0) } }
        return inTitle + hits.filter { !inTitle.contains($0) }
    }
}
