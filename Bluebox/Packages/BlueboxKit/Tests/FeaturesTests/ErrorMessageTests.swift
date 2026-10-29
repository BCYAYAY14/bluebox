import Addons
import Domain
import Downloads
@testable import Features
import Foundation
import Persistence
import Testing
import TorrentStreaming

@MainActor
@Suite struct ErrorMessageTests {
    @Test func networkFailuresSayWhatToDo() {
        #expect(UserFacingError.message(for: URLError(.notConnectedToInternet)).contains("offline"))
        let host = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://torrentio.strem.fun/x")!])
        #expect(UserFacingError.message(for: host).contains("torrentio.strem.fun"))
        // Bridged NSErrors get the same wording.
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(UserFacingError.message(for: ns).contains("too long"))
    }

    @Test func serviceErrorsPointAtTheSetting() {
        #expect(UserFacingError.message(for: MetadataError.unauthorized).contains("Settings › Catalog"))
        #expect(UserFacingError.message(for: AddonError.badStatus(429)).contains("Wait a minute"))
        #expect(UserFacingError.message(for: AddonError.debridRejected).contains("Settings › Torrents & Debrid"))
        #expect(UserFacingError.message(for: SourceError.notFound, context: .addons).contains("didn't find a release"))
        #expect(UserFacingError.message(for: SourceError.unauthorized).contains("add it again"))
    }

    @Test func outOfSpaceIsRecognisedHoweverItArrives() {
        #expect(UserFacingError.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(UserFacingError.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(UserFacingError.isOutOfSpace(wrapped))
        #expect(UserFacingError.message(for: DownloadError.insufficientSpace(needed: nil, free: nil)).contains("out of space"))
    }

    @Test func onlyTransientFailuresOfferTryAgain() {
        #expect(UserFacingError.isRetryable(URLError(.timedOut)))
        #expect(UserFacingError.isRetryable(TorrentStreamError.noPeers))
        #expect(UserFacingError.isRetryable(MetadataError.offline))
        #expect(!UserFacingError.isRetryable(TorrentStreamError.noPlayableFile))
        #expect(!UserFacingError.isRetryable(AddonError.debridRejected))
        #expect(!UserFacingError.isRetryable(MetadataError.unauthorized))
    }

    @Test func reportShowsAToastWithTryAgainWhenItHelps() throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "errors.\(UUID().uuidString)")!), forceSample: true)
        app.report(TorrentStreamError.noPeers, title: "Couldn't play", context: .addons) {}
        #expect(app.toast?.style == .error)
        #expect(app.toast?.actionTitle == "Try Again")
        #expect(app.toast?.message == TorrentStreamError.noPeers.errorDescription)

        app.report(TorrentStreamError.noPlayableFile, title: "Couldn't play") {}
        #expect(app.toast?.actionTitle == nil)
    }
}
