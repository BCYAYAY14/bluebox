import Addons
import Domain
import Foundation
import Playback
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// A debrid link that led to an add-on's notice clip (`DebridPlaceholder`):
// say what's wrong and offer what to do — the service's account page, or
// another release.

extension AppModel {
    func debridAlert(_ error: DebridLinkError, title: String, item: NowPlayingItem?) -> AppAlert {
        var actions: [AppAlert.Action] = []
        let service = addonSettings.debrid
        let openAccount = service.accountURL.map { url in AppAlert.Action("Open \(service.title)") { Self.openInBrowser(url) } }
        let pickRelease = item.flatMap { item in
            (item.key.tmdbID != nil || item.key.imdbID != nil) && addonSettings.isEnabled
                ? AppAlert.Action("Releases…") { [weak self] in self?.releasePickerRequest = .init(item: item) } : nil
        }
        // The account is the way forward when it's the account; otherwise another release is.
        if error.problem.isPerRelease {
            actions = [pickRelease, openAccount].compactMap { $0 }
        } else {
            actions = [openAccount, pickRelease].compactMap { $0 }
        }
        return AppAlert(title: Self.debridTitle(error.problem, fallback: title), message: error.localizedDescription,
                        actions: actions)
    }

    static func debridTitle(_ problem: DebridProblem, fallback: String) -> String {
        switch problem {
        case .planExpired: "Debrid plan expired"
        case .keyRejected: "Debrid key not accepted"
        case .notCachedYet: "Not ready on your debrid service yet"
        case .limitReached: "Debrid limit reached"
        case .archiveUnsupported, .failed: fallback
        }
    }

    static func openInBrowser(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}
