#if canImport(UIKit)
import UIKit
#endif

/// Whether the engines can trust their own count of new video frames.
///
/// On iPhone and iPad, while the film plays in Picture in Picture (or the app
/// is otherwise in the background), the system draws the picture itself, and
/// neither AVPlayer's video output nor VLC's displayed-picture count keeps
/// moving. The frozen-picture watchdog took that for a frozen picture and
/// seeked in place every few seconds, which flashed the PiP window grey and
/// woke its controls, then reopened the stream. So it only watches the
/// picture while the app is in front. On the Mac the picture is always drawn
/// by the app, PiP included.
@MainActor public enum PictureOnScreen {
    public static var countsFrames: Bool {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }
}
