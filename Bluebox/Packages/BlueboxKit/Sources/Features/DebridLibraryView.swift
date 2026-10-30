import DesignSystem
import Domain
import MediaSources
import SwiftUI

/// Your debrid cloud (Real-Debrid, Premiumize, TorBox, AllDebrid or Debrid-Link): a poster grid of the
/// titles its files matched, then "Unmatched files" to play by name. Pull to
/// refresh (or the Refresh button) reloads it from the service. The API key
/// is never shown. Must sit inside a NavigationStack (posters open `Route.title`).
public struct DebridLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var contents: DebridLibraryContents?
    @State private var error: String?
    @State private var isLoading = false
    @State private var fixingMatch: FixMatchRequest?

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header(inset: inset)
                    if app.debridLibraryName == nil {
                        StateMessage(systemImage: "externaldrive.badge.icloud", title: "No debrid library",
                                     message: "Choose a debrid service and add its API key in Settings › Sources to browse what's in your cloud.")
                            .frame(maxWidth: .infinity)
                    } else if let error, contents == nil {
                        StateMessage(systemImage: "exclamationmark.triangle", title: "Couldn't load your library", message: error,
                                     actionTitle: "Try Again") { Task { await load(refresh: true) } }
                            .frame(maxWidth: .infinity)
                    } else if let contents {
                        if contents.titles.isEmpty && contents.unmatched.isEmpty {
                            StateMessage(systemImage: "tray", title: "Your library is empty",
                                         message: "Videos you add to \(app.debridLibraryName ?? "your debrid service") show up here.")
                                .frame(maxWidth: .infinity)
                        }
                        if !contents.titles.isEmpty { grid(contents.titles, width: geo.size.width - inset * 2, inset: inset) }
                        if !contents.unmatched.isEmpty { unmatched(contents.unmatched, inset: inset) }
                    } else {
                        LazyVGrid(columns: columns(geo.size.width - inset * 2), spacing: Spacing.l) {
                            ForEach(0..<12, id: \.self) { _ in SkeletonBlock().aspectRatio(2 / 3, contentMode: .fit) }
                        }
                        .padding(.horizontal, inset)
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .refreshable { await load(refresh: true) }
            .reportsHeaderScroll()
        }
        .background(Palette.background)
        .task(id: app.features.debridRevision) { await load(refresh: false) }
        .fixMatchSheet($fixingMatch)
        .onChange(of: app.debridLibraryName) { contents = nil; error = nil }
    }

    private func header(inset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Debrid Library").font(Typography.pageTitle).foregroundStyle(Palette.textPrimary)
                if let name = app.debridLibraryName {
                    Text(summary(name)).font(Typography.meta).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            if app.debridLibraryName != nil {
                Button { Task { await load(refresh: true) } } label: {
                    if isLoading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, inset)
    }

    private func summary(_ service: String) -> String {
        guard let contents else { return service }
        let files = contents.titles.reduce(0) { $0 + $1.entries.count } + contents.unmatched.count
        return "\(service) · \(contents.titles.count) title\(contents.titles.count == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")"
    }

    private func columns(_ width: CGFloat) -> [GridItem] {
        let min: CGFloat = width < 500 ? 104 : 150
        return [GridItem(.adaptive(minimum: min, maximum: min * 1.4), spacing: Spacing.cardGap)]
    }

    private func grid(_ groups: [DebridLibraryContents.Group], width: CGFloat, inset: CGFloat) -> some View {
        LazyVGrid(columns: columns(width), alignment: .leading, spacing: Spacing.l) {
            ForEach(groups) { group in
                NavigationLink(value: Route.title(group.title)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ArtworkView(url: app.imageURL(group.title.poster, width: 200), fallbackTitle: group.title.name,
                                    kind: .poster, pixelWidth: 400)
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        Text(caption(group)).font(Typography.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(group.title.name), \(caption(group))")
                .contextMenu {
                    // Every file under the poster: a wrong show is usually wrong for all its episodes.
                    Button("Fix Match…", systemImage: "wand.and.stars") {
                        Task { fixingMatch = await app.fixMatchRequest(for: group.entries) }
                    }
                    Button("Unmatch", systemImage: "xmark.circle") { Task { await unmatch(group.entries) } }
                    if group.entries.contains(where: { app.matchOverride(for: variant($0)) != nil }) {
                        Button("Reset Match", systemImage: "arrow.uturn.backward") { app.resetMatch(group.entries.map(variant)) }
                    }
                }
            }
        }
        .padding(.horizontal, inset)
    }

    private func caption(_ g: DebridLibraryContents.Group) -> String {
        if g.title.kind == .series {
            let n = Set(g.entries.compactMap(\.key)).count
            return "\(n) episode\(n == 1 ? "" : "s")"
        }
        return g.entries.first?.parsed.resolution ?? (g.title.year.map(String.init) ?? "Movie")
    }

    private func unmatched(_ entries: [DebridLibrarySource.Entry], inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Unmatched files").font(Typography.rowTitle).foregroundStyle(Palette.textPrimary)
                .padding(.bottom, Spacing.s)
            ForEach(entries) { entry in
                Button { Task { await app.play(entry) } } label: {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "play.circle").font(.title2).foregroundStyle(Palette.textPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.file.filename).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                                .lineLimit(2).truncationMode(.middle)
                            Text(details(entry)).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Spacing.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .contextMenu {
                    FixMatchMenuItems(variant: variant(entry)) {
                        Task { fixingMatch = await app.fixMatchRequest(for: variant(entry)) }
                    }
                }
                Divider().overlay(Palette.separator)
            }
        }
        .padding(.horizontal, inset)
    }

    /// The entry as the source's variant (same ID and key the overrides use).
    private func variant(_ e: DebridLibrarySource.Entry) -> MediaVariant {
        MediaVariant(id: e.file.id, sourceID: SidebarSource.debridLibraryID, mediaKey: e.key, displayName: e.file.filename,
                     container: e.parsed.container, location: .remote)
    }

    private func unmatch(_ entries: [DebridLibrarySource.Entry]) async {
        guard let request = await app.fixMatchRequest(for: entries) else { return }
        app.unmatch([request.file] + request.siblings)
    }

    private func details(_ e: DebridLibrarySource.Entry) -> String {
        var parts: [String] = []
        if let s = e.file.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        if let r = e.parsed.resolution { parts.append(r) }
        if let d = e.file.addedAt { parts.append("Added \(d.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }

    private func load(refresh: Bool) async {
        guard app.debridLibraryName != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            contents = try await app.debridLibrary(refresh: refresh)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Check your connection and API key."
        }
    }
}
