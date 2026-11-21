import Domain
import Persistence
import Playback

/// Keeps a profile's audio and subtitle picks per show across players: each
/// play opens a new `PlayerSession`, whose own memory ends with it, so a pick
/// (or Off) made in one episode would be lost on the next.
extension AppModel {
    /// The current profile's picks, by show (`AppSettings.showKey`).
    var showTrackMemory: ShowTrackMemory {
        prefs.value(ShowTrackMemory.self, for: ProfileSettingKey.showTracks(currentProfileID)) ?? ShowTrackMemory()
    }

    /// Hands `session` the show's picks as each item starts, and keeps every pick made in it.
    func keepShowTracks(on session: PlayerSession) {
        session.showTrackChoices = { [weak self] key in
            self?.showTrackMemory.entry(for: AppSettings.showKey(for: key))
        }
        session.onTrackChosen = { [weak self] key, audio, subtitle in
            guard let self else { return }
            var memory = showTrackMemory
            memory.remember(audio: audio, subtitle: subtitle, for: AppSettings.showKey(for: key))
            prefs.set(memory, for: ProfileSettingKey.showTracks(currentProfileID))
        }
        // A subtitle file chosen for a title is kept with it (`KeptSubtitleStore`).
        session.onSubtitleFileChosen = { [weak session] key, url in
            try? KeptSubtitleStore.shared.keep(url, for: key, duration: session?.snapshot.duration)
        }
    }
}
