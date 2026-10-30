import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Whether sound (and with AVPlayer, the video) goes to an AirPlay receiver
/// right now: the audio session's route on iOS, the default output device's
/// transport on the Mac. Release ranking prefers MP4 while it does.
@MainActor
public final class AirPlayRoute {
    public private(set) var isActive = false
    /// Called on the main actor when `isActive` changes.
    public var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?

    public init() {}

    public func start() {
        isActive = Self.readActive()
        #if os(iOS)
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #else
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #endif
    }

    private func refresh() {
        let active = Self.readActive()
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }

    private static func readActive() -> Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #else
        var address = defaultOutputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeAirPlay
        #endif
    }

    #if os(macOS)
    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    #endif
}
