import DesignSystem
import Domain
import Foundation
import MediaSources
import Playback
import SwiftUI
import Torrent
import UniformTypeIdentifiers

// Opening things from outside Bluebox (GAPS M1, decision Q5 A): a magnet
// link clicked in a browser, a .torrent or video file opened with Bluebox or
// dropped on the Mac window, a folder of videos. Each goes the way you'd add
// it in Settings › Sources (a torrent is added and matched to the catalog,
// a folder becomes a source), then one sheet offers Play.

/// What a link, file or dropped text is.
enum ExternalItem: Equatable {
    case magnet(String)
    case torrentFile(URL)
    case videoFile(URL)
    case folder(URL)
    /// An https link to a video file (your own server).
    case videoLink(URL)

    /// The same list a folder scan uses, so a file that shows in a folder source opens on its own too.
    static var videoExtensions: Set<String> { LocalFolderSource.videoExtensions }

    /// Bluebox's own links (`bluebox://…`) aren't external items: nil.
    /// - Parameter isDirectory: for file URLs; nil checks the disk.
    static func classify(_ url: URL, isDirectory: Bool? = nil) -> ExternalItem? {
        switch url.scheme?.lowercased() {
        case "magnet":
            return url.absoluteString.lowercased().contains("xt=urn:btih:") ? .magnet(url.absoluteString) : nil
        case "file":
            let directory = isDirectory ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            if directory { return .folder(url) }
            let ext = url.pathExtension.lowercased()
            if ext == "torrent" { return .torrentFile(url) }
            if videoExtensions.contains(ext) { return .videoFile(url) }
            return nil
        case "https", "http":
            return videoExtensions.contains(url.pathExtension.lowercased()) ? .videoLink(url) : nil
        default:
            return nil
        }
    }

    /// Dropped or pasted text: a magnet, or a link to a video.
    static func classify(text: String) -> ExternalItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), let url = URL(string: trimmed) else { return nil }
        return classify(url, isDirectory: false)
    }
}

/// Why a folder couldn't be added as a source.
enum LocalFolderAddError: Error, Equatable, LocalizedError {
    case alreadyAdded(String)
    /// The system wouldn't keep permission to read it after Bluebox quits.
    case noBookmark(String)

    var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name): "That folder is already in My Sources, as “\(name)”."
        case .noBookmark(let name):
            "Bluebox couldn't keep permission to read “\(name)”. Try adding it again, or move the videos to a folder in your home folder."
        }
    }
}

/// What the open sheet shows.
public struct ExternalOpenState: Identifiable, Equatable {
    public enum Phase: Equatable {
        case working(String)
        /// Ready: the title it matched (if any), and what Play opens.
        case ready(title: Title?, variant: MediaVariant)
        /// Added, but nothing in it plays (no video files).
        case nothingToPlay(String)
        case failed(String)
    }

    public let id = UUID()
    /// "Opened from a magnet link", "Opened from a .torrent file".
    public let source: String
    public var phase: Phase

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.phase == b.phase }
}

extension AppModel {
    /// Opens a magnet, .torrent, video file, folder or video link.
    func openExternal(_ item: ExternalItem) async {
        switch item {
        case .magnet(let link):
            await openTorrent(source: "Opened from a magnet link") { try await self.addTorrent(magnet: link) }
        case .torrentFile(let url):
            await openTorrent(source: "Opened from a .torrent file") { try await self.addTorrent(file: url) }
        case .videoFile(let url):
            externalOpen = nil
            await playFile(at: url)
        case .videoLink(let url):
            let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            do {
                let before = Set(try await directLinks.catalog().map(\.id))
                try await addDirectLink(url: url, title: name, matching: nil)
                let after = try await directLinks.catalog()
                guard let variant = after.first(where: { !before.contains($0.id) }) ?? after.first(where: { $0.displayName == name })
                else { throw SourceError.notFound }
                externalOpen = ExternalOpenState(source: "Opened from a link", phase: .ready(title: nil, variant: variant))
            } catch {
                externalOpen = ExternalOpenState(source: "Opened from a link", phase: .failed(UserFacingError.message(for: error)))
            }
        case .folder(let url):
            await addFolderReporting(url)
        }
    }

    /// Opens several dropped or picked items: every folder and torrent is added,
    /// the first video plays. Says so when none of it is something Bluebox opens.
    func openExternal(_ items: [ExternalItem], ignored: [String] = []) async {
        if items.isEmpty {
            let what = ignored.count == 1 ? "“\(ignored[0])”" : "these"
            alert = AppAlert(title: "Bluebox can't open \(what)",
                             message: "Open or drop videos (\(LocalFolderSource.extensionList)), folders of videos, .torrent files or magnet links.")
            return
        }
        let videos = items.filter { if case .videoFile = $0 { true } else { false } }
        for item in items {
            if case .videoFile = item { continue }
            await openExternal(item)
        }
        if let first = videos.first { await openExternal(first) }
    }

    /// Adds a folder as a source and says what came of it: how many videos, or
    /// why it couldn't be added.
    func addFolderReporting(_ url: URL) async {
        let name = url.lastPathComponent
        do {
            let count = try await addLocalFolder(url)
            if count == 0 {
                showToast(AppToast(name, message: "Added, but there are no videos in it yet. Bluebox looks for \(LocalFolderSource.extensionList) files.",
                                   style: .info))
            } else {
                showToast(AppToast(name, message: "Added to My Sources · \(count) video\(count == 1 ? "" : "s")", style: .success))
            }
        } catch {
            alert = AppAlert(title: "Couldn't add “\(name)”", message: UserFacingError.message(for: error))
        }
    }

    /// Adds a torrent the way Settings › Sources does, then offers its first video.
    private func openTorrent(source: String, add: () async throws -> TorrentSource.Item) async {
        externalOpen = ExternalOpenState(source: source, phase: .working("Getting the file list…"))
        let id = externalOpen?.id
        do {
            let item = try await add()
            guard externalOpen?.id == id else { return }  // closed meanwhile
            let variants = try await torrents.catalog().filter { $0.id.hasPrefix(item.infoHash.hex + ":") }
            guard let first = variants.first(where: { $0.mediaKey != nil }) ?? variants.first else {
                externalOpen?.phase = .nothingToPlay(item.title)
                return
            }
            var matched: Title?
            if let key = first.mediaKey { matched = await title(for: key.seriesKey ?? key) }
            externalOpen?.phase = .ready(title: matched, variant: first)
        } catch {
            guard externalOpen?.id == id else { return }
            externalOpen?.phase = .failed(UserFacingError.message(for: error))
        }
    }

    /// Plays what the open sheet found.
    func playExternal(_ variant: MediaVariant, title: Title?) async {
        externalOpen = nil
        let key = variant.mediaKey ?? MediaKey(rawValue: "url:\(variant.id)")
        await play(NowPlayingItem(key: key, title: title?.name ?? variant.displayName,
                                  subtitle: key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }), variant: variant)
    }
}

// MARK: - Sheet

/// "Opened from a magnet link": the matched title, what's in it, and Play.
struct ExternalOpenSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.pushRoute) private var pushRoute
    let state: ExternalOpenState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(state.source.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.6)
                .foregroundStyle(Palette.textTertiary)
            content
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 400, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("externalOpenSheet")
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .working(let text):
            HStack(spacing: Spacing.m) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(Palette.textSecondary)
            }
            buttons(primary: nil)
        case .ready(let title, let variant):
            HStack(alignment: .top, spacing: Spacing.m) {
                if let title {
                    PosterCard(title: title.name, url: app.imageURL(title.poster, width: 60), width: 60)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title?.name ?? variant.displayName).font(.title3.weight(.heavy)).lineLimit(2)
                    Text(title.map { [$0.year.map(String.init), $0.kind == .movie ? "Film" : "Series", "matched from the file name"]
                        .compactMap { $0 }.joined(separator: " · ") } ?? "Not matched to the catalog")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                    Text([variant.displayName, variant.sizeBytes.map(Formatters.bytes)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Palette.textTertiary).lineLimit(2)
                }
            }
            buttons(primary: ("Play", { Task { await app.playExternal(variant, title: title) } }), details: title)
        case .nothingToPlay(let name):
            Text("“\(name)” was added to Your Torrents in Settings › Sources, but there's no video in it to play.")
                .font(.callout).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            buttons(primary: nil)
        case .failed(let message):
            Text("Couldn't open it").font(.title3.weight(.heavy))
            Text(ui: message).font(.callout).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            buttons(primary: nil)
        }
    }

    private func buttons(primary: (String, () -> Void)?, details: Title? = nil) -> some View {
        HStack(spacing: Spacing.s) {
            if let details {
                Button("Details") { app.externalOpen = nil; pushRoute(.title(details)) }
                    .buttonStyle(GlassButtonStyle(fullWidth: true))
            } else {
                Button(primary == nil ? "Close" : "Not Now") { app.externalOpen = nil }
                    .buttonStyle(GlassButtonStyle(fullWidth: true))
                    .keyboardShortcut(.cancelAction)
            }
            if let primary {
                Button {
                    primary.1()
                } label: {
                    Label(primary.0, systemImage: "play.fill")
                }
                .buttonStyle(PlayButtonStyle(fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("externalOpen.play")
            }
        }
        .background {
            Button("Close") { app.externalOpen = nil }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
    }
}

/// Shows `app.externalOpen` over the window, dimming the library.
struct ExternalOpenPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .overlay {
                if let state = app.externalOpen {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { if case .working = state.phase {} else { app.externalOpen = nil } }
                            .accessibilityHidden(true)
                        ExternalOpenSheet(state: state)
                            .padding(Spacing.xl)
                    }
                    .transition(.opacity)
                    .zIndex(5)
                }
            }
            .animation(.easeOut(duration: 0.18), value: app.externalOpen)
    }
}

/// The picker behind File › Open… and My Sources' Open Files…: videos (MKV
/// and AVI too, which aren't `public.movie` everywhere), folders and .torrent files.
struct OpenFilesImporter: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    static var contentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .folder]
        if let torrent = UTType(filenameExtension: "torrent") { types.append(torrent) }
        for ext in LocalFolderSource.videoExtensions.sorted() {
            if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
        }
        return types
    }

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: Self.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let (items, ignored) = Self.classify(urls)
                Task { await app.openExternal(items, ignored: ignored) }
            case .failure(let error):
                app.alert = AppAlert(title: "Couldn't open it", message: UserFacingError.message(for: error))
            }
        }
    }

    /// Picked URLs are security-scoped: telling a folder from a file needs access first.
    static func classify(_ urls: [URL]) -> ([ExternalItem], [String]) {
        var items: [ExternalItem] = []
        var ignored: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let item = ExternalItem.classify(url) { items.append(item) } else { ignored.append(url.lastPathComponent) }
        }
        return (items, ignored)
    }
}

extension View {
    func openFilesImporter(isPresented: Binding<Bool>) -> some View {
        modifier(OpenFilesImporter(isPresented: isPresented))
    }
}

#if os(macOS)
/// Drop a magnet, .torrent, video or folder anywhere on the Mac window: a
/// blue drop target shows while something is over it.
struct ExternalDropTarget: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted) { providers in
                Self.items(from: providers) { items, ignored in
                    Task { await app.openExternal(items, ignored: ignored) }
                }
                return true
            }
            .overlay {
                if targeted {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "arrow.down.to.line.circle")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundStyle(Palette.brandBright)
                        Text("Drop to play or download").font(.title3.weight(.heavy))
                        Text("Magnet links, .torrent files, videos and folders")
                            .font(.callout).foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
                        .strokeBorder(Palette.brand, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .padding(Spacing.m)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityIdentifier("dropTarget")
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }

    /// Reads file URLs, links and text from a drop, keeping what Bluebox can open.
    /// `done` gets what can be opened and the names of the files that can't.
    static func items(from providers: [NSItemProvider], done: @escaping @MainActor ([ExternalItem], [String]) -> Void) {
        let group = DispatchGroup()
        let found = Found()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    let item = url.flatMap { ExternalItem.classify($0) }
                    found.add(item)
                    if item == nil, let url, url.isFileURL { found.ignore(url.lastPathComponent) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    found.add(text.flatMap { ExternalItem.classify(text: $0) })
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let items = found.items, ignored = found.ignored
            MainActor.assumeIsolated { done(items, ignored) }
        }
    }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ExternalItem] = []
        private var skipped: [String] = []
        func add(_ item: ExternalItem?) {
            guard let item else { return }
            lock.withLock { list.append(item) }
        }
        func ignore(_ name: String) { lock.withLock { skipped.append(name) } }
        var items: [ExternalItem] { lock.withLock { list } }
        var ignored: [String] { lock.withLock { skipped } }
    }
}
#endif
