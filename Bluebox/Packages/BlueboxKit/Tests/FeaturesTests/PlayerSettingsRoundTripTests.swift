import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import TorrentStreaming
import Testing

@MainActor @Suite struct CrowdSkipSettingTests {
    /// "Wrong time?" turns a show's community timestamps off; Undo (or the
    /// Tools toggle) turns them back on, and both survive a relaunch.
    @Test func offAndBackOnRoundTripsThroughPreferences() {
        let defaults = UserDefaults(suiteName: "crowd.\(UUID().uuidString)")!
        let episode = MediaKey.episode(seriesID: 1396, season: 2, episode: 3)
        let sameShow = MediaKey.episode(seriesID: 1396, season: 5, episode: 1)
        let other = MediaKey.episode(seriesID: 60059, season: 1, episode: 1)

        let settings = AppSettings(prefs: PreferencesStore(defaults: defaults))
        #expect(settings.crowdSkipsAllowed(for: episode))
        settings.setCrowdSkipsAllowed(false, for: episode)
        #expect(!settings.crowdSkipsAllowed(for: sameShow))  // per show, not per episode
        #expect(settings.crowdSkipsAllowed(for: other))

        let relaunched = AppSettings(prefs: PreferencesStore(defaults: defaults))
        #expect(!relaunched.crowdSkipsAllowed(for: episode))

        relaunched.setCrowdSkipsAllowed(true, for: sameShow)  // Undo
        #expect(relaunched.crowdSkipsAllowed(for: episode))
        #expect(relaunched.crowdSkipDisabledShows.isEmpty)
        #expect(AppSettings(prefs: PreferencesStore(defaults: defaults)).crowdSkipsAllowed(for: episode))
    }
}

@Suite struct PlayerEpisodeNavigationTests {
    @Test func previousEpisodeStepsBackAcrossSeasons() {
        let seasons = [SeasonSummary(number: 0, name: "Specials", episodeCount: 3),
                       SeasonSummary(number: 1, name: "S1", episodeCount: 7),
                       SeasonSummary(number: 2, name: "S2", episodeCount: 13)]
        #expect(PlayerEpisodes.previous(before: 2, 5, seasons: seasons).map { [$0.season, $0.episode] } == [2, 4])
        #expect(PlayerEpisodes.previous(before: 2, 1, seasons: seasons).map { [$0.season, $0.episode] } == [1, 7])
        #expect(PlayerEpisodes.previous(before: 1, 1, seasons: seasons) == nil)
    }

    @Test func loadingTextSaysWhatsHappening() {
        #expect(PlayerLoadingText.line(status: .playing, bufferFill: nil, torrent: nil, loadingNext: false, elapsed: 0) == nil)
        let peers = SwarmStats(connectedPeers: 12)
        #expect(PlayerLoadingText.line(status: .buffering, bufferFill: 0.4, torrent: peers, loadingNext: false, elapsed: 3)?.headline
                == "Buffering 40%")
        #expect(PlayerLoadingText.line(status: .loading, bufferFill: nil, torrent: SwarmStats(connectedPeers: 0),
                                       loadingNext: false, elapsed: 1)?.headline == "Connecting to peers…")
        #expect(PlayerLoadingText.line(status: .loading, bufferFill: nil, torrent: nil, loadingNext: false, elapsed: 1)?.headline
                == "Opening the video…")
    }
}
