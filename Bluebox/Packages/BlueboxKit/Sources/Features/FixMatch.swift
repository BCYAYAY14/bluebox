import DesignSystem
import Domain
import MediaSources
import Persistence
import SwiftUI

// Fix Match: local folders and the debrid library are matched to the catalog
// by file name (`AppModel.makeMatcher`), which gets same-named shows ("The
// Office" UK and US), remakes and files without a year wrong. Fix Match lets
// you pick the title by hand for one file, or for every file of that name;
// Unmatch leaves a file unmatched; Reset Match goes back to the automatic
// match. Choices are kept per file (`MatchOverrides`) on this device only.

/// One file Fix Match can change.
struct FixMatchFile: Identifiable, Hashable {
    let variant: MediaVariant
    /// Its name as parsed: the search starts from it, and episodes keep their numbers.
    let parsed: ParsedMediaName
    var id: String { MatchOverrides.fileKey(source: variant.sourceID, variant: variant.id) }
}

/// What the Fix Match sheet is for: a file, and the others named like it.
struct FixMatchRequest: Identifiable {
    let id = UUID()
    let file: FixMatchFile
    /// Other files of the same film or show in the same source (the rest of a season).
    let siblings: [FixMatchFile]
    /// A poster stands for all its files: they all change, without asking.
    var wholeGroup = false

    /// The search the sheet starts with.
    var query: String { file.parsed.title }
}

enum FixMatch {
    /// Files in `all` named like `file` (same normalised title, both films or
    /// both episodes), not counting `file`.
    static func siblings(of file: FixMatchFile, in all: [FixMatchFile]) -> [FixMatchFile] {
        let want = MediaNameParser.normalized(file.parsed.title)
        guard !want.isEmpty else { return [] }
        return all.filter { other in
            other.id != file.id && MediaNameParser.normalized(other.parsed.title) == want
                && isEpisode(other.parsed) == isEpisode(file.parsed)
        }
    }

    static func isEpisode(_ p: ParsedMediaName) -> Bool {
        if case .episode = p.kind { return true }
        return false
    }

    /// The key a file gets when matched to `title`: the film, or the episode of
    /// the show its name numbers (or `season`/`episode` when it has none).
    static func key(for title: Title, file: ParsedMediaName, season: Int?, episode: Int?) -> MediaKey? {
        switch title.kind {
        case .movie:
            return title.key
        case .series:
            let show = title.key.seriesKey ?? title.key
            if case .episode(let s, let e) = file.kind { return show.episode(season: s, episode: e) }
            guard let season, let episode else { return nil }
            return show.episode(season: season, episode: episode)
        }
    }
}

extension AppModel {
    /// What a file was matched to by hand, if anything.
    func matchOverride(for variant: MediaVariant) -> MatchOverride? {
        matchOverrides.override(source: variant.sourceID, variant: variant.id)
    }

    /// The Fix Match sheet for one file of a local folder or the debrid library.
    func fixMatchRequest(for variant: MediaVariant) async -> FixMatchRequest {
        let all = await fixableFiles(in: variant.sourceID)
        let file = all.first { $0.variant.id == variant.id }
            ?? FixMatchFile(variant: variant, parsed: Self.parsedName(of: variant))
        return FixMatchRequest(file: file, siblings: FixMatch.siblings(of: file, in: all))
    }

    /// The Fix Match sheet for a debrid poster: every file it groups.
    func fixMatchRequest(for entries: [DebridLibrarySource.Entry]) async -> FixMatchRequest? {
        var files: [FixMatchFile] = []
        for e in entries { files.append(FixMatchFile(variant: await features.debridLibrary.variant(for: e), parsed: e.parsed)) }
        guard let first = files.first else { return nil }
        return FixMatchRequest(file: first, siblings: Array(files.dropFirst()), wholeGroup: true)
    }

    /// Every file of a source with the name it was parsed from.
    private func fixableFiles(in source: SourceID) async -> [FixMatchFile] {
        if source == features.debridLibrary.id {
            let entries = (try? await features.debridLibrary.library()) ?? []
            var out: [FixMatchFile] = []
            for e in entries { out.append(FixMatchFile(variant: await features.debridLibrary.variant(for: e), parsed: e.parsed)) }
            return out
        }
        guard let local = await registry.source(source) as? LocalFolderSource,
              let variants = try? await local.catalog() else { return [] }
        var out: [FixMatchFile] = []
        for v in variants {
            let parsed = await local.parsedName(of: v.id) ?? Self.parsedName(of: v)
            out.append(FixMatchFile(variant: v, parsed: parsed))
        }
        return out
    }

    private static func parsedName(of v: MediaVariant) -> ParsedMediaName {
        MediaNameParser.parse(filename: v.container.map { "\(v.displayName).\($0)" } ?? v.displayName)
    }

    /// Films and shows for the Fix Match search.
    func searchForMatch(_ query: String) async throws -> [Title] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await metadata.search(q, page: 1).items
    }

    /// Matches `files` to `title` (episodes keep their own numbers). Returns how many changed.
    @discardableResult
    func applyMatch(_ title: Title, season: Int? = nil, episode: Int? = nil, to files: [FixMatchFile]) -> Int {
        var changed = 0
        for f in files {
            guard let key = FixMatch.key(for: title, file: f.parsed, season: season, episode: episode) else { continue }
            matchOverrides.set(.title(key), source: f.variant.sourceID, variant: f.variant.id)
            changed += 1
        }
        matchesChanged()
        return changed
    }

    /// Leaves `files` unmatched, whatever their names match.
    func unmatch(_ files: [FixMatchFile]) {
        for f in files { matchOverrides.set(.unmatched, source: f.variant.sourceID, variant: f.variant.id) }
        matchesChanged()
    }

    /// Back to matching by name.
    func resetMatch(_ variants: [MediaVariant]) {
        for v in variants { matchOverrides.set(nil, source: v.sourceID, variant: v.id) }
        matchesChanged()
    }

    private func matchesChanged() {
        let all = matchOverrides.all
        prefs.set(all.isEmpty ? nil : all, for: PreferenceKey.matchOverrides)
        sourcesRevision += 1
        libraryRevision += 1
        features.noteDebridChanged()
    }
}

// MARK: - Menu

/// Fix Match…, Unmatch and Reset Match for a file's context menu.
struct FixMatchMenuItems: View {
    @Environment(AppModel.self) private var app
    let variant: MediaVariant
    let fix: () -> Void

    var body: some View {
        Button("Fix Match…", systemImage: "wand.and.stars", action: fix)
        if variant.mediaKey != nil {
            Button("Unmatch", systemImage: "xmark.circle") {
                app.unmatch([FixMatchFile(variant: variant, parsed: MediaNameParser.parse(filename: variant.displayName))])
            }
        }
        if app.matchOverride(for: variant) != nil {
            Button("Reset Match", systemImage: "arrow.uturn.backward") { app.resetMatch([variant]) }
        }
    }
}

// MARK: - Sheet

/// Search the catalog for what a file really is, and match it (and, if you
/// like, the other files named like it) to that.
struct FixMatchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: FixMatchRequest
    @State private var query = ""
    @State private var results: [Title] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selected: Title?
    @State private var applyToAll = true
    @State private var season = 1
    @State private var episode = 1

    private var needsEpisodeNumbers: Bool { selected?.kind == .series && !FixMatch.isEpisode(request.file.parsed) }
    private var files: [FixMatchFile] {
        request.wholeGroup || applyToAll ? [request.file] + request.siblings : [request.file]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.file.variant.displayName).lineLimit(2).truncationMode(.middle)
                    if request.wholeGroup, !request.siblings.isEmpty {
                        Text("and \(request.siblings.count) other file\(request.siblings.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                } header: {
                    Text("File")
                }

                Section {
                    TextField("Film or show", text: $query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                        .accessibilityIdentifier("fixMatch.query")
                    if searching {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let error {
                        Text(error).font(.footnote).foregroundStyle(Palette.warning)
                    } else if results.isEmpty, !query.isEmpty {
                        Text("Nothing found. Try the title without the year or extra words.")
                            .font(.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(results) { title in
                        resultRow(title)
                    }
                } header: {
                    Text("Search")
                }

                if needsEpisodeNumbers {
                    Section {
                        Stepper("Season \(season)", value: $season, in: 0...99)
                        Stepper("Episode \(episode)", value: $episode, in: 1...999)
                    } footer: {
                        Text("The file's name doesn't say which episode it is.")
                    }
                }

                if !request.wholeGroup, !request.siblings.isEmpty {
                    Section {
                        Toggle("Also the other \(request.siblings.count) file\(request.siblings.count == 1 ? "" : "s") named “\(request.file.parsed.title)”",
                               isOn: $applyToAll)
                    } footer: {
                        Text(ui: FixMatch.isEpisode(request.file.parsed)
                             ? "Each episode keeps its own season and episode number."
                             : "For other copies of the same film.")
                    }
                }

                Section {
                    Button("Unmatch", role: .destructive) {
                        app.unmatch(files)
                        dismiss()
                    }
                    if files.contains(where: { app.matchOverride(for: $0.variant) != nil }) {
                        Button("Reset to Automatic Match") {
                            app.resetMatch(files.map(\.variant))
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Unmatch keeps the file in My Sources as it is, without a title. Matches are saved on this device.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Fix Match")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Match") { save() }
                        .disabled(selected == nil)
                        .accessibilityIdentifier("fixMatch.save")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .preferredColorScheme(.dark)
        .task {
            query = request.query
            if case .episode(let s, let e) = request.file.parsed.kind { season = s; episode = e }
        }
        // Searches as you type, after a pause.
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func resultRow(_ title: Title) -> some View {
        Button {
            selected = title
        } label: {
            HStack(spacing: Spacing.m) {
                ArtworkView(url: app.imageURL(title.poster, width: 40), fallbackTitle: title.name, kind: .poster,
                            pixelWidth: 80, showsFallbackTitle: false)
                    .frame(width: 32, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name).foregroundStyle(Palette.textPrimary).lineLimit(2)
                    Text([title.year.map(String.init), title.kind == .movie ? "Film" : "Series"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if selected?.key == title.key {
                    Image(systemName: "checkmark").foregroundStyle(Palette.brand).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected?.key == title.key ? .isSelected : [])
    }

    private func search() async {
        searching = true
        defer { searching = false }
        do {
            results = try await app.searchForMatch(query)
            error = nil
        } catch is CancellationError {
        } catch {
            results = []
            self.error = UserFacingError.message(for: error)
        }
    }

    private func save() {
        guard let selected else { return }
        app.applyMatch(selected, season: needsEpisodeNumbers ? season : nil, episode: needsEpisodeNumbers ? episode : nil,
                       to: files)
        dismiss()
    }
}

extension View {
    /// Presents the Fix Match sheet for `request`.
    func fixMatchSheet(_ request: Binding<FixMatchRequest?>) -> some View {
        sheet(item: request) { FixMatchSheet(request: $0) }
    }
}
