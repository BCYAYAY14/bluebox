import Addons
import Foundation
import Playback
import Sync

/// Where the remote asked the Mac to go (`RemoteDestination`), once.
public struct RemoteNavigation: Equatable, Sendable {
    public let id = UUID()
    public let destination: RemoteDestination
}

/// The Mac's side of the remote's app commands (RemoteControl.swift): going
/// somewhere is RootView's job (`remoteNavigation`), the highlight is
/// `RemoteFocus`'s, and Play is the same as pressing Play here.
///
/// While the player is open it covers the window, so the touch pad steers
/// the player instead (a tap plays or pauses, left and right skip 10 s);
/// while a stream loads, the pad does nothing, so a second tap can't press
/// Play again on the page underneath.
extension AppModel: RemoteAppHandler {
    public func remoteGo(_ destination: RemoteDestination) {
        // Back closes the top sheet first; going anywhere else closes them all.
        if destination == .back, activePlayer == nil, remoteFocus.dismissTopModal() { return }
        if destination != .back { remoteFocus.dismissAllModals() }
        remoteNavigation = RemoteNavigation(destination: destination)
    }

    public func remotePlay(_ play: RemotePlay) async {
        let item = NowPlayingItem(key: play.key, title: play.title, subtitle: play.subtitle)
        if let data = play.release, let release = try? JSONDecoder().decode(AddonRelease.self, from: data) {
            await self.play(item, release: release)
        } else {
            await self.play(item, resume: play.resume)
        }
    }

    public func remoteClosePlayer() async { await closePlayer() }

    public func remoteFocus(_ id: String, driver: String) {
        guard activePlayer == nil, preparingItem == nil else { return }
        remoteFocus.focus(id: id, driver: driver)
    }

    public func remoteMove(_ direction: RemoteDirection, driver: String) {
        if let player = activePlayer {
            let step: TimeInterval = switch direction {
            case .left: -10
            case .right: 10
            case .up, .down: 0
            }
            guard step != 0 else { return }
            let target = max(0, player.displayPosition + step)
            Task { await player.seek(to: player.snapshot.duration.map { min(target, $0) } ?? target) }
            return
        }
        guard preparingItem == nil else { return }
        remoteFocus.move(direction, driver: driver)
    }

    public func remoteSelect(driver: String) {
        if let player = activePlayer { player.togglePlayPause(); return }
        guard preparingItem == nil else { return }
        remoteFocus.select(driver: driver)
    }

    public func remoteScreen() -> (title: String, focusedID: String?, focusedLabel: String?) {
        let title = activePlayer?.item?.title ?? remoteFocus.screenTitle
        return (title, activePlayer == nil ? remoteFocus.focusedID : nil, activePlayer == nil ? remoteFocus.focusedLabel : nil)
    }
}
