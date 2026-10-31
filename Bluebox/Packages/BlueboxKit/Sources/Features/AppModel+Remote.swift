import Addons
import DesignSystem
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
/// Play again on the page underneath, and Back cancels it.
///
/// The better remote's commands (protocol 4) go to `RemoteFocus` too: jumps,
/// two-finger scrolling, the pointer, a hold's menu and picking from it; the
/// skip button goes to the player's (`remoteSkip`).
extension AppModel: RemoteAppHandler {
    public func remoteGo(_ destination: RemoteDestination) {
        // Back stops a stream that's still loading, as the loading screen's Cancel does.
        if destination == .back, activePlayer == nil, preparingItem != nil { cancelPreparing(); return }
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

    public func remote4(_ action: RemoteCommand.Action, driver: String) {
        if let player = activePlayer {
            switch action {
            case .jump(let j):
                let step: TimeInterval = j.direction == .left ? -10 : j.direction == .right ? 10 : 0
                guard step != 0 else { return }
                let target = max(0, player.displayPosition + step * Double(j.count))
                Task { await player.seek(to: player.snapshot.duration.map { min(target, $0) } ?? target) }
            case .acceptSkip:
                remoteSkip?.accept()
            case .menuPick(let i):
                BlueboxMenuRemote.current?.pick(i)
            default:
                break  // the player covers the window: nothing to scroll, point at or hold
            }
            return
        }
        guard preparingItem == nil else { return }
        switch action {
        case .jump(let j): remoteFocus.jump(j.direction, count: j.count, driver: driver)
        case .scroll(let s): remoteFocus.scroll(s, driver: driver)
        case .setPointer(let on): remoteFocus.setPointer(on, driver: driver)
        case .pointer(let m): remoteFocus.movePointer(dx: m.dx, dy: m.dy, driver: driver)
        case .click: remoteFocus.click(driver: driver)
        case .menu: remoteFocus.openMenu(driver: driver)
        case .menuPick(let i): remoteFocus.pickMenuItem(i, driver: driver)
        case .acceptSkip: remoteSkip?.accept()
        default: break
        }
    }

    public func remoteScreen() -> RemoteScreen {
        if let player = activePlayer {
            // The player covers the window: nothing on it to highlight, but a menu may be open over it.
            var s = RemoteScreen(deviceID: "", title: player.item?.title ?? remoteFocus.screenTitle)
            s.menu = remoteFocus.screen().menu
            return s
        }
        return remoteFocus.screen()
    }

    public func remoteSkipOffer() -> String? { activePlayer == nil ? nil : remoteSkip?.title }
}
