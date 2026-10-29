#if os(iOS)
import AVFoundation
import Domain
import Foundation

/// Plays silence so iOS keeps Bluebox running in the background while
/// torrents download (Info.plist › UIBackgroundModes › audio). The session
/// mixes with other audio, so it never stops the user's music, and nothing
/// shows in Now Playing. `DownloadLifecycle` starts and stops it.
///
/// After a phone call or Siri (an interruption) and after the audio route
/// changes it plays again; `onChange` reports anything that may have
/// stopped it, and the lifecycle decides what to do.
@MainActor
final class SilentAudioKeepAlive {
    /// Called after an interruption, a route change or a media-services reset.
    var onChange: (() -> Void)?
    /// A phone call or another app's non-mixing audio has the session; wait for it to end.
    private(set) var isInterrupted = false
    private var player: AVAudioPlayer?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { wanted && player?.isPlaying == true }

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesReset() }
        })
    }

    /// Starts (or keeps) playing silence. False when iOS refused the session.
    @discardableResult
    func start() -> Bool {
        wanted = true
        if player?.isPlaying == true { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try player ?? AVAudioPlayer(data: Self.silence)
            p.numberOfLoops = -1
            player = p
            guard p.prepareToPlay(), p.play() else { throw CocoaError(.featureUnsupported) }
            isInterrupted = false
            Log.sources.notice("Background downloads: keep-alive audio started")
            return true
        } catch {
            Log.sources.error("Background downloads: keep-alive audio failed: \(error.localizedDescription, privacy: .public)")
            wanted = false
            player?.stop()
            player = nil
            restoreCategory()
            return false
        }
    }

    /// Stops the silence. `deactivate` releases the audio session; pass
    /// false while the player is open, so its audio isn't cut off.
    func stop(deactivate: Bool) {
        let wasActive = wanted || player != nil
        wanted = false
        isInterrupted = false
        player?.stop()
        player = nil
        guard wasActive else { return }
        restoreCategory()
        if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        Log.sources.notice("Background downloads: keep-alive audio stopped")
    }

    /// Back to what the player expects (BlueboxApp sets it at launch): not
    /// mixable, so playback gets Now Playing and the lock-screen controls.
    private func restoreCategory() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    private func interrupted(began: Bool) {
        guard wanted else { return }
        if began {
            isInterrupted = true  // iOS has paused the player
        } else {
            isInterrupted = false
            // Mixable sessions may start again from the background.
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
        onChange?()
    }

    private func routeChanged() {
        guard wanted, !isInterrupted, let player, !player.isPlaying else { return }
        player.play()
        onChange?()
    }

    private func mediaServicesReset() {
        guard wanted else { return }
        player = nil
        isInterrupted = false
        start()
        onChange?()
    }

    /// Five seconds of 8 kHz mono 16-bit silence as a WAV file.
    private static let silence: Data = {
        let rate: UInt32 = 8000, seconds: UInt32 = 5
        let dataBytes = rate * seconds * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)              // PCM
        u16(1)              // mono
        u32(rate)
        u32(rate * 2)       // bytes per second
        u16(2)              // block align
        u16(16)             // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }()
}
#endif
