import CoreSpotlight
import DesignSystem
import Domain
import Foundation
import ImageIO
import Persistence
import Playback
import SystemSnapshot
import UniformTypeIdentifiers
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

// Bluebox outside itself: the widgets' snapshot (Continue Watching, Up Next,
// My List), Spotlight (those and downloads), and the bluebox:// links both
// open, which Siri's shortcuts (Apps/Shared/BlueboxShortcuts.swift) use too.

/// What `AppModel` keeps for this; off until the app turns it on at launch,
/// so tests and previews never write a snapshot or touch Spotlight.
@MainActor
public final class SystemSurfaces {
    var isEnabled = false
    var pending: Task<Void, Never>?
    /// Called after each snapshot is written (the app refreshes Siri's title list).
    public var onSnapshotWritten: (@MainActor () -> Void)?
    /// Changes come in bursts (a sync, a profile switch): wait for them to settle.
    static let settle: Duration = .seconds(2)
    /// Poster thumbnails for the widgets: the first few of each row, this wide in pixels.
    static let thumbnailCount = 6
    static let thumbnailWidth = 240
    nonisolated static let spotlightDomain = "app.bluebox.library"

    init() {}
}

/// A tab to show, from a link (My List, Search with its query).
public struct TabRequest: Equatable, Identifiable {
    public let id = UUID()
    public let tab: AppTab
    public let search: String?
}

extension AppModel {
    /// Called by the app once the library is open: writes the snapshot now and
    /// whenever the library changes.
    public func startSystemSurfaces(onSnapshotWritten: (@MainActor () -> Void)? = nil) {
        system.onSnapshotWritten = onSnapshotWritten
        system.isEnabled = true
        scheduleSystemRefresh(after: .zero)
    }

    func scheduleSystemRefresh(after delay: Duration = SystemSurfaces.settle) {
        guard system.isEnabled else { return }
        system.pending?.cancel()
        system.pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshSystemSurfaces()
        }
    }

    /// Rebuilds the snapshot and Spotlight for the current profile. A profile
    /// with a PIN shows nothing outside Bluebox: widgets sit on the Lock Screen.
    func refreshSystemSurfaces() async {
        let target = LibrarySnapshotStore.default
        let snapshot = lockedProfileIDs.contains(currentProfileID) ? LibrarySnapshot() : await makeSnapshot(target)
        guard !Task.isCancelled else { return }
        do { try target.write(snapshot) } catch { Log.persistence.error("Couldn't write the widget snapshot: \(error)") }
        #if canImport(WidgetKit) && os(iOS)
        if target.isShared { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        let downloads = lockedProfileIDs.contains(currentProfileID) ? [] : downloadedItems()
        await Self.index(snapshot, downloads: downloads, thumbnails: target)
        system.onSnapshotWritten?()
    }

    /// Continue Watching as Home works it out (in progress, then next
    /// episodes), and My List.
    private func makeSnapshot(_ target: LibrarySnapshotStore) async -> LibrarySnapshot {
        let now = Date()
        let progress = (try? await store.continueWatching(limit: 20)) ?? []
        let records = (try? await store.recent(limit: 400)) ?? []
        var shows: [MediaKey] = []
        for p in records where now.timeIntervalSince(p.updatedAt) <= ContinueWatchingRules.nextUpWindow {
            if let s = p.key.seriesKey, !shows.contains(s) { shows.append(s) }
            if shows.count >= 30 { break }
        }
        let info = await showInfo(for: shows)
        let entries = ContinueWatchingRules.build(inProgress: progress, recent: records, shows: info,
                                                  announced: features.tracker.notified, now: now)
        let titles = await titles(for: entries.map { $0.progress.key.seriesKey ?? $0.progress.key })
        var watching: [LibrarySnapshot.Item] = [], upNext: [LibrarySnapshot.Item] = []
        for (entry, title) in zip(entries, titles) {
            guard let title else { continue }
            if let next = entry.next {
                let code = next.season.flatMap { s in next.episode.map { "S\(s)·E\($0)" } }
                let link: SystemLink = next.key.map { .play(key: $0.rawValue) } ?? .title(key: title.key.rawValue, episode: nil)
                upNext.append(.init(key: next.key?.rawValue ?? title.key.rawValue, titleKey: title.key.rawValue, title: title.name,
                                    subtitle: code ?? "Next Episode", isNew: next.isNew, link: link.url))
            } else {
                let p = entry.progress
                watching.append(.init(key: p.key.rawValue, titleKey: title.key.rawValue, title: title.name,
                                      subtitle: p.key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" },
                                      progress: p.fraction, minutesLeft: p.remaining.map { max(1, Int(($0 / 60).rounded())) },
                                      link: SystemLink.play(key: p.key.rawValue).url))
            }
        }
        // Linkable titles only: a local file's key means nothing to a link.
        let list = ((try? await store.watchlist()) ?? []).prefix(30).compactMap { t -> LibrarySnapshot.Item? in
            let link = SystemLink.title(key: t.key.rawValue, episode: nil)
            guard SystemLink(url: link.url) != nil else { return nil }
            return .init(key: t.key.rawValue, titleKey: t.key.rawValue, title: t.name, link: link.url)
        }
        watching = watching.filter { SystemLink(url: $0.link) != nil }
        upNext = upNext.filter { SystemLink(url: $0.link) != nil }
        // Posters for what the widgets show; the rest keep none.
        let posterTitles = Dictionary(zip(entries, titles).compactMap { _, t in t.map { ($0.key.rawValue, $0) } },
                                      uniquingKeysWith: { a, _ in a })
        var named: [String: String] = [:]
        for item in (watching.prefix(SystemSurfaces.thumbnailCount) + upNext.prefix(SystemSurfaces.thumbnailCount))
        where named[item.titleKey] == nil {
            if target.hasThumbnail(for: item.titleKey) {
                named[item.titleKey] = LibrarySnapshotStore.thumbnailName(for: item.titleKey)
            } else if let title = posterTitles[item.titleKey], let data = await thumbnail(for: title),
                      let name = try? target.saveThumbnail(data, for: item.titleKey) {
                named[item.titleKey] = name
            }
        }
        func withPoster(_ item: LibrarySnapshot.Item) -> LibrarySnapshot.Item {
            var item = item
            item.thumbnail = named[item.titleKey]
            return item
        }
        return LibrarySnapshot(generatedAt: now, continueWatching: watching.map(withPoster),
                               upNext: upNext.map(withPoster), myList: Array(list))
    }

    /// A small JPEG of the title's poster.
    private func thumbnail(for title: Title) async -> Data? {
        guard let url = imageURL(title.poster, width: CGFloat(SystemSurfaces.thumbnailWidth / 2)),
              let image = try? await ImagePipeline.shared.image(for: url, maxPixelWidth: SystemSurfaces.thumbnailWidth) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Finished downloads, for Spotlight.
    private func downloadedItems() -> [LibrarySnapshot.Item] {
        downloads.all().compactMap { r in
            guard case .completed = r.state, let key = r.mediaKey else { return nil }
            let link = SystemLink.play(key: key.rawValue)
            guard SystemLink(url: link.url) != nil else { return nil }
            return .init(key: key.rawValue, titleKey: (key.seriesKey ?? key).rawValue, title: r.title,
                         subtitle: r.subtitle.map { "\($0) · Downloaded" } ?? "Downloaded", link: link.url)
        }
    }

    /// Replaces what Spotlight has from Bluebox. Each item's identifier is the
    /// link it opens (`continueFromSpotlight`).
    private static func index(_ snapshot: LibrarySnapshot, downloads: [LibrarySnapshot.Item],
                              thumbnails: LibrarySnapshotStore) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let items = snapshot.spotlightEntries(downloads: downloads).map { entry in
            let attributes = CSSearchableItemAttributeSet(contentType: .movie)
            attributes.title = entry.item.title
            attributes.displayName = entry.displayName
            attributes.contentDescription = entry.contentDescription
            attributes.keywords = ["Bluebox", entry.detail]
            if let name = entry.item.thumbnail { attributes.thumbnailURL = thumbnails.thumbnailURL(name) }
            return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: SystemSurfaces.spotlightDomain,
                                    attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [SystemSurfaces.spotlightDomain])
        if !items.isEmpty { try? await index.indexSearchableItems(items) }
    }

    /// Erase All Data: the snapshot, its posters and Spotlight's entries go too.
    nonisolated static func eraseSystemSurfaces() {
        LibrarySnapshotStore.default.removeAll()
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SystemSurfaces.spotlightDomain]) { _ in }
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Opening links

    /// A Spotlight result was opened: its identifier is a bluebox:// link.
    public func continueFromSpotlight(_ activity: NSUserActivity) {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let url = URL(string: id), let link = SystemLink(url: url) else { return }
        Task { await open(link) }
    }

    /// Opens a widget's, Spotlight's or Siri's link. A play link only plays
    /// what's already in this profile's library (anything could send one);
    /// otherwise it opens the title's page.
    public func open(_ link: SystemLink) async {
        switch link {
        case .title(let key, let episode):
            await openTitle(MediaKey(rawValue: key), episode: episode.map(MediaKey.init(rawValue:)))
        case .play(let raw):
            let key = MediaKey(rawValue: raw)
            let saved = (try? await store.progress(for: key)) ?? nil
            let snapshot = LibrarySnapshotStore.default.read()
            let queued = (snapshot?.continueWatching ?? []) + (snapshot?.upNext ?? [])
            let known = saved != nil || queued.contains { $0.key == raw }
            guard known, let title = await title(for: key.seriesKey ?? key) else {
                await openTitle(key.seriesKey ?? key, episode: key.seriesKey == nil ? nil : key)
                return
            }
            if activePlayer != nil { await closePlayer() }
            let resume = saved.map { !$0.isNearlyFinished } ?? false
            let subtitle = key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
            await play(NowPlayingItem(key: key, title: title.name, subtitle: subtitle,
                                      artworkURL: imageURL(title.backdrop, width: 640)), resume: resume)
        case .myList:
            if activePlayer != nil { await closePlayer() }
            features.tabRequest = TabRequest(tab: .myList, search: nil)
        case .search(let query):
            if activePlayer != nil { await closePlayer() }
            features.tabRequest = TabRequest(tab: .search, search: query)
        }
    }

    private func openTitle(_ key: MediaKey, episode: MediaKey?) async {
        guard let title = await title(for: key) else { return }
        features.openRequest = OpenRequest(title: title, episode: episode)
    }
}
