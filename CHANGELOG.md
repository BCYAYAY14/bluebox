# Changelog

What changed in each Bluebox release, newest first. Each version ships as one build for iPhone, iPad and Mac, on the [Releases](https://github.com/BCYAYAY14/bluebox/releases) page and through the AltStore source.

## 1.0.14 (30 October 2026)

### Mac
- Installing from the DMG: a new window, Bluebox's black and blue with an arrow from the app to Applications, the version, and what to do if macOS won't open Bluebox the first time. The disk shows Bluebox's icon.

### Episodes
- A watched episode shows a full blue bar under its picture, the same as one you've started, instead of a WATCHED tag.

### Fixed
- Updating from inside the Mac app failed with "hdiutil: attach failed - Operation not permitted". macOS keeps other programs out of Bluebox's own folder, so the updater now gets the download as an open file. Bluebox 1.0.13 and earlier still have the old updater: download 1.0.14 from the Releases page once, and updates work from then on.
- After an update installed, the old Bluebox never quit, so the new one never opened. Erase All Data had the same hang.

## 1.0.13 (30 October 2026)

### Player
- Picking a subtitle track or changing how subtitles look never reopens the video, so there's no rebuffer. Colour, background, outline, size and position show from the next line; font, weight and shadow take effect from the next video.
- Picking a subtitle no longer switches the audio to the file's default track.
- Opening the subtitle card no longer stutters: the track list isn't rebuilt several times a second, and ASS subtitles no longer load about 140 MB of Chinese, Japanese and Korean fonts each time they start.
- A simpler Subtitle Style card: presets, then Size, Colour, Background, Outline and Position.
- Every subtitle language is in one list that scrolls inside the card.
- Tools is three columns on a phone.
- Subtitles from files and subtitles in the video use the same font.
- Infuse as an external player: Open in Infuse on each release and finished download, and Settings › Player › Always Open in Infuse (this device only).

### Downloads
- A show's page has one ↓ button beside the season, with a menu: Download Season, Unwatched Only, As One Season Pack, and Download Rules…. While the season downloads, one thin progress line sits under the picker, with Pause and Cancel.
- Download Rules has no Use Defaults / Custom switch. Changing anything gives the show its own rules, and Reset to Settings goes back. Keep Next, Quality and Audio open a list instead of a pop-up.

### Fixed
- Torrents that reached "ready" but wouldn't play after the app had been in the background. iOS could close the stream server's socket while the app was suspended; the server now checks itself before each stream and listens again on the same port.
- Titles saved while using one catalog (TMDB or Cinemeta) still open, with their progress, downloads and My List, after switching to the other.
- A changelog, on the front page of the public repository.

## 1.0.12 (29 October 2026)

### Player
- Subtitles are listed by language. A language with several tracks opens its own list (SDH, Forced, SRT or ASS, and files).
- A new subtitle Style page, with a live sample, Look and Position tabs, a nine-spot anchor, Apply Now, and one note on what applies to the current track.
- Subtitle timing, audio delay and speed share one dial: the value in words, steps you can hold down, and a slider.
- Denser cards on a phone turned on its side.

### Fixed
- ASS subtitle tracks show again when the video carries no fonts of its own.
- Closing the player never leaves sound playing: not while a video is still opening, not after the red button, not after a second Play, and not after Cancel.
- The credits countdown waits while the video is paused or a card is open.
- Holding for 2× speed no longer sticks.
- Speed carries over between episodes.
- Esc closes an open card before it leaves full screen.
- The episode list retries when it fails to load.
- Subtitle timing starts fresh for each file.
- The second line of a two-line subtitle stays on screen.
- Downloaded subtitles no longer overwrite each other.
- Five subtitle files that failed to parse now load.
- The buffering spinner waits a moment before it shows, and never covers a card.

## 1.0.11 (29 October 2026)

- Every secret is kept in one Keychain item, so a Mac asks for Keychain access once instead of once per secret. Items saved by earlier versions are moved in, then deleted.
- Mac builds are signed with a stable certificate, so Always Allow lasts across updates.
- Mac updates: the app downloads the update itself, with progress over the window and in Settings › About, and gives up after 30 seconds without data. The helper only mounts, checks and swaps, with a time limit on each step, and says when macOS App Management blocks it.
- A subtitle change that reopens the stream keeps the audio track that was playing.

## 1.0.10 (29 October 2026)

- Mac player: changing subtitle size no longer reopens the stream, and never crashes. Font, colour and outline changes apply once the subtitle panel closes (one reopen, not one per tweak).
- Mac player: fixed a crash when switching videos (seen with AV1).

## 1.0.9 (29 October 2026)

The first release from the open-source repository, under the MIT licence. Builds 1.0.1 to 1.0.8 came out before the public history started over.

### Highlights
- **Home:** Top Picks, Because You Watched, Continue Watching that goes on to the next episode, and Not Interested.
- **Profiles:** Kids profiles and maturity limits, PIN lock, per-profile settings, and a Profiles menu on the Mac.
- **Lists:** a Library grid, list pages, Add to List, smart lists and Play All, synced between devices.
- **Search:** stable sections, filter chips, recent searches with pictures, and instant results from the cache and your library.
- **Release picker:** quality groups, chips and tags, with duplicates folded together.
- **Downloads:** whole seasons and season packs, a queue screen, show pages, and Download Rules.
- **Smart Downloads:** per-show rules, caps, a download window, upgrades, subtitles, and deleting watched episodes while keeping the next ones ready on Wi-Fi.
- **Player:** Audio & Subtitles picker with clean track names, an episodes panel, styled subtitles, torrent availability on the timeline, and anchored cards for tracks, speed and tools.
- **Sync:** API keys, add-ons, settings and lists sync through your own Supabase project, live. Sign in with a username and password, set up from one access token, and add another device.
- **Live Activity** for downloads on iPhone, a downloads item in the Mac menu bar, and iPhone as a remote for the Mac player.
- **My Bluebox:** watch statistics, a spoiler guard, always-skip per show, and release alerts.
- **Updates:** checks GitHub's latest release once a day and from Settings › About. The Mac installs it and opens again; iPhone and iPad point to AltStore.
- **Settings › Storage:** Clear Search History and Erase All Data.
- A custom About window on the Mac.

### Fixed
- Torrent downloads keep running in the background on iPhone and iPad.
- Home retries dropped requests and keeps the lists that did load.
- Searches no longer get stuck.
- The Mac app always opens with its main window, and Window › Bluebox (⌘0) brings it back.
- The Mac app no longer hangs at launch (the menu-bar downloads item rebuilt the window in a loop), and a Keychain prompt can no longer freeze it before the window appears.
- The player no longer hangs when stretching video.
- The Dynamic Island stays hidden while the player is up.
