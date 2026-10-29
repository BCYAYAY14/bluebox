import Domain
import Foundation
import Metadata
import Persistence

// Not Interested (question 16 A) and Continue Watching's next-episode cards.

extension AppModel {
    /// The current profile's hidden titles, newest first.
    public func hiddenTitleList() -> [HiddenTitle] {
        _ = hiddenRevision
        return hiddenTitles.all(profileID: currentProfileID)
    }

    /// Keys of the current profile's hidden titles.
    func hiddenKeys() -> Set<MediaKey> {
        _ = hiddenRevision
        return hiddenTitles.keys(profileID: currentProfileID)
    }

    /// "Not Interested": leaves Home's rows at once, with Undo in a toast.
    public func hideTitle(_ title: Title) {
        let profile = currentProfileID
        hiddenTitles.hide(title, profileID: profile)
        hiddenRevision += 1
        showToast(AppToast(title.name, message: "Hidden from Home", actionTitle: "Undo") { [weak self] in
            self?.unhideTitle(title.key, profileID: profile)
        })
    }

    /// Settings › Hidden Titles: shows it on Home again.
    public func unhideTitle(_ key: MediaKey) {
        unhideTitle(key, profileID: currentProfileID)
    }

    private func unhideTitle(_ key: MediaKey, profileID: String) {
        hiddenTitles.unhide(key, profileID: profileID)
        hiddenRevision += 1
    }

    /// Remove from Row on a next-episode card: a reset record for the next
    /// episode takes the show out (as Remove does for one in progress), and
    /// syncs. Undo makes the finished episode the newest record again.
    func dismissUpNext(_ entry: WatchEntry) async {
        guard let next = entry.next?.key else { return }
        let finished = entry.progress
        _ = try? await store.save(WatchProgress(key: next, position: 0, duration: nil, updatedAt: .now, deviceID: prefs.deviceID))
        noteLibraryChanged()
        showToast(AppToast("Removed from Continue Watching", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            var restored = finished
            restored.updatedAt = .now
            restored.deviceID = self.prefs.deviceID
            Task {
                _ = try? await self.store.save(restored)
                self.noteLibraryChanged()
            }
        })
    }

    /// What Home knows about these shows without asking the network: seasons
    /// from a detail still in memory (the sample catalog answers locally) and
    /// the last aired episode from the new-episode tracker.
    func showInfo(for shows: [MediaKey]) async -> [MediaKey: ContinueWatchingRules.ShowInfo] {
        var out: [MediaKey: ContinueWatchingRules.ShowInfo] = [:]
        let cached = metadata as? CachedMetadataProvider
        for s in shows {
            var info = ContinueWatchingRules.ShowInfo()
            if let cached {
                info.seasons = await cached.cachedDetail(for: s)?.seasons
                if let airing = await cached.cachedAiring(for: s), let last = airing.lastEpisode,
                   let date = last.airDate, date <= .now {
                    info.lastAired = last.key
                    info.lastAiredDate = date
                }
            } else if catalogMode == .sample {
                info.seasons = try? await metadata.detail(for: s).seasons
            }
            if info.lastAired == nil, let raw = features.tracker.lastSeen[s.rawValue], !raw.isEmpty {
                info.lastAired = MediaKey(rawValue: raw)
            }
            out[s] = info
        }
        return out
    }

    /// Every rating, for Top Picks.
    func ratingEntries() -> [MediaKey: RatingEntry] {
        trakt.allRatings().mapValues { RatingEntry(rating: $0.rating, date: $0.date) }
    }
}
