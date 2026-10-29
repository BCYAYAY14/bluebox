import Addons
import Domain
import Foundation
import Playback

/// What a Handoff activity carries: enough to open the same title at the same
/// second on another device, under the same profile.
public struct WatchActivityPayload: Equatable, Sendable {
    public static let activityType = "app.bluebox.watch"

    public var key: MediaKey
    public var title: String
    public var subtitle: String?
    /// Whole seconds.
    public var position: Int
    public var profileID: String?
    /// A release the other device can open directly (an add-on torrent, as
    /// "<info hash>:<file index>"). Local files and expiring links aren't sent.
    public var sourceID: String?
    public var variantID: String?
    public var container: String?

    public init(key: MediaKey, title: String, subtitle: String? = nil, position: Int, profileID: String? = nil,
                sourceID: String? = nil, variantID: String? = nil, container: String? = nil) {
        self.key = key; self.title = title; self.subtitle = subtitle; self.position = position; self.profileID = profileID
        self.sourceID = sourceID; self.variantID = variantID; self.container = container
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["key": key.rawValue, "title": title, "position": position, "v": 1]
        if let subtitle { info["subtitle"] = subtitle }
        if let profileID { info["profile"] = profileID }
        if let sourceID, let variantID {
            info["source"] = sourceID
            info["variant"] = variantID
            if let container { info["container"] = container }
        }
        return info
    }

    public init?(userInfo info: [AnyHashable: Any]?) {
        guard let info, let raw = info["key"] as? String, !raw.isEmpty, let title = info["title"] as? String else { return nil }
        let position = (info["position"] as? Int) ?? (info["position"] as? NSNumber)?.intValue ?? 0
        self.init(key: MediaKey(rawValue: raw), title: title, subtitle: info["subtitle"] as? String, position: max(position, 0),
                  profileID: info["profile"] as? String, sourceID: info["source"] as? String,
                  variantID: info["variant"] as? String, container: info["container"] as? String)
    }

    /// Only add-on torrents resume on another device as the same release: local
    /// files aren't there, and debrid or server links are per account and expire.
    static func handoffVariant(_ variant: MediaVariant, addonsID: SourceID) -> (source: String, id: String, container: String?)? {
        guard variant.sourceID == addonsID, StremioSource.torrent(fromVariantID: variant.id) != nil else { return nil }
        return (variant.sourceID.rawValue, variant.id, variant.container)
    }
}

/// Advertises what's playing for Handoff. Updated on start, on pause or
/// play, and whenever the position moves more than 30 seconds from what was
/// last advertised; invalidated when the player closes.
@MainActor
final class WatchHandoff {
    private var activity: NSUserActivity?
    private var advertised: WatchActivityPayload?
    nonisolated static let refreshInterval = 30

    /// True when `payload` differs enough from what's advertised to resend.
    nonisolated static func needsRefresh(old: WatchActivityPayload?, new: WatchActivityPayload) -> Bool {
        guard let old else { return true }
        if old.key != new.key || old.profileID != new.profileID || old.variantID != new.variantID { return true }
        return abs(old.position - new.position) > refreshInterval
    }

    func update(_ payload: WatchActivityPayload, force: Bool = false) {
        guard force || Self.needsRefresh(old: advertised, new: payload) else { return }
        let a: NSUserActivity
        if let activity, advertised?.key == payload.key {
            a = activity
        } else {
            activity?.invalidate()
            a = NSUserActivity(activityType: WatchActivityPayload.activityType)
            a.isEligibleForHandoff = true
            a.isEligibleForSearch = false
            #if os(iOS)
            a.isEligibleForPrediction = false
            #endif
            activity = a
        }
        a.title = payload.subtitle.map { "\(payload.title) · \($0)" } ?? payload.title
        a.userInfo = payload.userInfo
        a.requiredUserInfoKeys = ["key", "title", "position"]
        a.needsSave = true
        a.becomeCurrent()
        advertised = payload
    }

    func invalidate() {
        activity?.invalidate()
        activity = nil
        advertised = nil
    }
}

extension AppModel {
    /// The Handoff payload for what `session` plays now.
    func handoffPayload(for session: PlayerSession) -> WatchActivityPayload? {
        guard let item = session.item else { return nil }
        let pos = session.snapshot.position
        var payload = WatchActivityPayload(key: item.key, title: item.title, subtitle: item.subtitle,
                                           position: pos.isFinite ? Int(pos) : 0, profileID: currentProfileID)
        if let variant = session.currentResource?.variant,
           let v = WatchActivityPayload.handoffVariant(variant, addonsID: addons.id) {
            payload.sourceID = v.source; payload.variantID = v.id; payload.container = v.container
        }
        return payload
    }

    /// Continues a Handoff from another device: same profile, same title, at
    /// that second, through the normal play path.
    public func continueWatching(from activity: NSUserActivity) async {
        guard activity.activityType == WatchActivityPayload.activityType,
              let payload = WatchActivityPayload(userInfo: activity.userInfo) else { return }
        await continueWatching(payload)
    }

    func continueWatching(_ payload: WatchActivityPayload) async {
        if let profile = payload.profileID, profile != currentProfileID,
           profiles.contains(where: { $0.id == profile && !$0.isRemoved }) {
            await switchProfile(to: profile)
        }
        if activePlayer != nil { await closePlayer() }
        // Record the handed-off position as the newest progress, so the play
        // path's resume lands on it (and sync carries it like any other).
        let known = (try? await store.progress(for: payload.key)) ?? nil
        let record = ProgressPolicy.standard.record(key: payload.key, position: TimeInterval(payload.position),
                                                    duration: known?.duration, at: Date(), deviceID: prefs.deviceID)
        _ = try? await store.save(record)
        let artwork = await title(for: payload.key.seriesKey ?? payload.key).flatMap { imageURL($0.backdrop, width: 640) }
        let item = NowPlayingItem(key: payload.key, title: payload.title, subtitle: payload.subtitle, artworkURL: artwork)
        var variant: MediaVariant?
        if let source = payload.sourceID, let id = payload.variantID, source == addons.id.rawValue {
            variant = MediaVariant(id: id, sourceID: addons.id, mediaKey: payload.key, displayName: payload.title,
                                   container: payload.container, location: .remote)
        }
        // Explicit: a handoff lands on the handed-off second even with Start
        // Playing set to From the Beginning, or under the 30 s resume threshold.
        await play(item, variant: variant, resume: true, startAt: TimeInterval(payload.position))
    }
}
