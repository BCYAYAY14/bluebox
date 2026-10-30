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
extension AppModel: RemoteAppHandler {
    public func remoteGo(_ destination: RemoteDestination) {
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

    public func remoteFocus(_ id: String, driver: String) { remoteFocus.focus(id: id, driver: driver) }
    public func remoteMove(_ direction: RemoteDirection, driver: String) { remoteFocus.move(direction, driver: driver) }
    public func remoteSelect(driver: String) { remoteFocus.select(driver: driver) }

    public func remoteScreen() -> (title: String, focusedID: String?, focusedLabel: String?) {
        let title = activePlayer?.item?.title ?? remoteFocus.screenTitle
        return (title, activePlayer == nil ? remoteFocus.focusedID : nil, activePlayer == nil ? remoteFocus.focusedLabel : nil)
    }
}
