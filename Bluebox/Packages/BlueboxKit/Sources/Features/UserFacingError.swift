import Addons
import Domain
import Downloads
import Foundation
import TorrentStreaming

/// Turns any error into a sentence that says what happened and what to do,
/// instead of "The operation couldn't be completed (… error 0)".
enum UserFacingError {
    /// Where the failure happened, for wording that fits it.
    enum Context { case playback, addons, download, catalog, general }

    static func message(for error: Error, context: Context = .general) -> String {
        if let url = error as? URLError { return message(for: url) }
        if isOutOfSpace(error) {
            return "Your device is out of space. Delete some downloads, or lower the stream cache in Settings › Storage."
        }
        switch error {
        case let e as AddonError:
            if case .badStatus(let code) = e, code == 429 {
                return "The add-ons are limiting how often Bluebox can ask. Wait a minute, then try again."
            }
            return e.errorDescription ?? e.localizedDescription
        case let e as SourceError:
            if e == .notFound, context == .addons {
                return "The add-ons didn't find a release of this. Try Choose Release, or turn on more add-ons in Settings › Torrents & Debrid."
            }
            if e == .unauthorized {
                return "The server didn't accept Bluebox's sign-in. Remove the source and add it again in Settings › Sources."
            }
            return e.errorDescription ?? e.localizedDescription
        case let e as MetadataError:
            if e == .unauthorized {
                return "TMDB rejected the access token. Check it in Settings › Catalog & Ratings."
            }
            return e.errorDescription ?? e.localizedDescription
        case is DecodingError:
            return "The server sent something Bluebox couldn't read. Try again later."
        case let e as LocalizedError where e.errorDescription != nil:
            return e.errorDescription!
        default:
            return error.localizedDescription
        }
    }

    static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            "You're offline. Downloaded titles still play; connect to the internet to stream."
        case .timedOut:
            "The server took too long to answer. Check your connection and try again."
        case .networkConnectionLost:
            "The connection dropped. Try again."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            "Couldn't reach \(error.failingURL?.host() ?? "the server"). Check the address and your connection."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            "A secure connection to \(error.failingURL?.host() ?? "the server") couldn't be made."
        case .userAuthenticationRequired, .userCancelledAuthentication:
            "The server asked for a sign-in. Check the account in Settings › Sources."
        case .badServerResponse, .cannotParseResponse, .zeroByteResource:
            "The server sent an empty or broken answer. Try again later."
        case .fileDoesNotExist, .noPermissionsToReadFile:
            "The file isn't there any more, or Bluebox can't open it. If it's in a folder, add the folder again in Settings › Sources."
        default:
            error.localizedDescription
        }
    }

    /// Worth offering Try Again: the same request may well work in a moment.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case let e as URLError:
            [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
             .cannotFindHost, .badServerResponse, .dataNotAllowed].contains(e.code)
        case let e as TorrentStreamError: e.suggestsFallback
        case let e as AddonError: e != .debridRejected && e != .noAddons
        case let e as SourceError: e.isTransient
        case let e as MetadataError:
            switch e {
            case .offline, .rateLimited, .server, .transport: true
            default: false
            }
        default: false
        }
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        if let e = error as? DownloadError, case .insufficientSpace = e { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
