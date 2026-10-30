import DesignSystem
import Domain
import Persistence
import SwiftUI
#if os(iOS)
import UIKit
#endif

// Lists on screen (UI review decisions 10–12, mockup part D): the mosaic
// covers, the Lists grid in My Library, a list's page with Play All, Shuffle
// and Edit, the Add to List card, and the New List editor.

// MARK: - Cover

/// Four posters in a square, or the list's symbol while it's empty.
struct ListCover: View {
    @Environment(AppModel.self) private var app
    let covers: [Title]
    let symbol: String
    let side: CGFloat

    var body: some View {
        let cell = (side - 2) / 2
        Group {
            if covers.isEmpty {
                ZStack {
                    Palette.surface
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.28, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { cellView(0, cell); cellView(1, cell) }
                    GridRow { cellView(2, cell); cellView(3, cell) }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.edge))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cellView(_ i: Int, _ side: CGFloat) -> some View {
        if covers.indices.contains(i) {
            let t = covers[i]
            ArtworkView(url: app.imageURL(t.poster, width: side), fallbackTitle: t.name, kind: .poster,
                        pixelWidth: Int(side * 2), showsFallbackTitle: false)
                .frame(width: side, height: side)
                .clipped()
        } else {
            Palette.surface.frame(width: side, height: side)
        }
    }
}

// MARK: - Lists grid

/// My Library › Lists: My List, your lists, then smart lists, as mosaic tiles.
struct ListsGrid: View {
    let summaries: [ListSummary]
    let loaded: Bool
    let inset: CGFloat
    let width: CGFloat

    var body: some View {
        // Two columns on iPhone; more as the page widens.
        let grid = FittedGrid(width: width - inset * 2, minimum: 150, gap: Spacing.m)
        LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.l) {
            if !loaded {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SkeletonBlock(width: grid.itemWidth, height: grid.itemWidth, radius: Radius.control)
                        SkeletonBlock(width: grid.itemWidth * 0.6, height: 12, radius: 4)
                    }
                }
            } else {
                ForEach(summaries) { s in
                    NavigationLink(value: Route.list(s.id)) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ListCover(covers: s.covers, symbol: s.symbol, side: grid.itemWidth)
                            Text(s.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Text(s.caption).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(s.name), \(s.caption)")
                    .accessibilityIdentifier("lists.\(s.name)")
                }
            }
        }
        .padding(.horizontal, inset)
    }
}

// MARK: - A list's page

/// A list: mosaic header, name, count and runtime, Play All, Shuffle and
/// Edit, then its titles. Edit drags to reorder and removes several at once.
struct ListDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let id: LibraryListID

    /// Newest added first (the "Recently Added" order).
    @State private var recent: [Title] = []
    /// The hand-set order (or a smart list's own).
    @State private var manual: [MediaKey] = []
    /// What the grid shows, arranged in `rearrange()`, not in `body`.
    @State private var shown: [Title] = []
    @State private var list: UserList?
    @State private var totalMinutes = 0
    @State private var loaded = false
    @State private var failed = false
    @State private var sort: MyListSort = .manual
    @State private var editing = false
    @State private var editOrder: [Title] = []
    @State private var selection: Set<MediaKey> = []
    @State private var confirmDelete = false

    private var isSmart: Bool { !id.isEditable }

    private var name: String {
        switch id {
        case .myList: "My List"
        case .own: list?.name ?? ""
        case .smart(let s): s.title
        }
    }

    private var symbol: String {
        switch id {
        case .myList: "plus"
        case .own: list?.symbol ?? UserList.defaultSymbol
        case .smart(let s): s.symbol
        }
    }

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            Group {
                if editing { editList(inset: inset) } else { page(width: geo.size.width, inset: inset) }
            }
        }
        .blueboxScreen()
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: app.libraryRevision) { await load() }
        .onChange(of: sort) { _, s in
            ViewMemory.set(s.rawValue, memoryKey, profile: app.currentProfileID)
            rearrange()
        }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete List", role: .destructive) {
                guard let list else { return }
                // The reload that follows finds the list gone and leaves the page.
                Task { await app.deleteList(list) }
            }
        } message: {
            Text("The titles stay on My List and your other lists.")
        }
    }

    private var memoryKey: String {
        switch id {
        case .myList: "listSort.myList"
        case .own(let listID): "listSort.\(listID)"
        case .smart(let s): "listSort.smart.\(s.rawValue)"
        }
    }

    private func load() async {
        do {
            switch id {
            case .myList:
                let entries = try await app.store.watchlistEntries()
                manual = entries.map(\.key)
                recent = entries.sorted { $0.addedAt > $1.addedAt }.map(\.title)
            case .own(let listID):
                list = try await app.store.list(listID)
                // A list deleted on another device: leave its page.
                guard list != nil else { dismiss(); return }
                let entries = try await app.store.entries(in: listID)
                manual = entries.map(\.key)
                recent = entries.sorted { $0.addedAt > $1.addedAt }.map(\.title)
            case .smart:
                let titles = try await app.listTitles(id)
                manual = titles.map(\.key)
                recent = titles
            }
            failed = false
        } catch {
            failed = true
        }
        let runtimes = await app.runtimes(for: recent)
        totalMinutes = recent.reduce(0) { $0 + (runtimes[$1.key] ?? 0) }
        if !loaded {
            let saved = ViewMemory.string(memoryKey, profile: app.currentProfileID).flatMap(MyListSort.init(rawValue:))
            sort = saved.flatMap { MyListSort.options(smart: isSmart).contains($0) ? $0 : nil } ?? .manual
        }
        rearrange()
        loaded = true
    }

    private func rearrange() {
        let next = MyListArrangement.arrange(recent, filter: .all, sort: sort, manual: manual)
        if next != shown { withAnimation(loaded ? Motion.snappy(reduceMotion) : nil) { shown = next } }
    }

    // MARK: Page

    private func page(width: CGFloat, inset: CGFloat) -> some View {
        let metrics = CardMetrics(containerWidth: width)
        let grid = FittedGrid(width: width - inset * 2, minimum: metrics.posterWidth, gap: Spacing.cardGap)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header(inset: inset)
                if !loaded {
                    LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.cardGap) {
                        ForEach(0..<(grid.count * 2), id: \.self) { _ in
                            SkeletonBlock(width: grid.itemWidth, height: grid.itemWidth * 1.5)
                        }
                    }
                    .shimmering()
                    .padding(.horizontal, inset)
                } else if shown.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.cardGap) {
                        ForEach(shown) { t in
                            TitleCardLink(t) {
                                PosterCard(title: t.name, url: app.imageURL(t.poster, width: grid.itemWidth), width: grid.itemWidth)
                            }
                        }
                    }
                    .padding(.horizontal, inset)
                }
            }
            .padding(.vertical, Spacing.l)
        }
        .reportsHeaderScroll()
    }

    @ViewBuilder private var emptyState: some View {
        if failed {
            StateMessage(.failed, title: "Couldn't open this list",
                         message: "Bluebox couldn't read the library on this device. Try again.",
                         actionTitle: "Try Again") { Task { await load() } }
        } else if case .smart(let s) = id {
            StateMessage(systemImage: s.symbol, title: "Nothing here yet", message: smartHint(s))
        } else {
            StateMessage(systemImage: "plus.rectangle.on.rectangle", title: "This list is empty",
                         message: "Press and hold + on any movie or show, or choose Add to List… from a poster's menu.")
        }
    }

    private func smartHint(_ s: SmartList) -> String {
        switch s {
        case .shortFilms: "Films on your lists that you haven't watched and that run under 100 minutes show up here."
        case .available4K: "Titles on your lists that a source offers in 4K show up here once Bluebox has seen the release."
        case .downloaded: "Films and shows you download show up here."
        case .continueWatching: "Films and episodes you start show up here."
        }
    }

    private func header(inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .bottom, spacing: Spacing.m) {
                ListCover(covers: Array(shown.prefix(4)), symbol: symbol, side: 96)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(name).font(Typography.pageTitle).foregroundStyle(Palette.textPrimary).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(ListPlayOrder.summary(count: recent.count, minutes: totalMinutes))
                        .font(Typography.meta).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if case .own = id { listMenu }
            }
            HStack(spacing: Spacing.s) {
                Button { Task { await app.playList(shown, shuffled: false) } } label: {
                    Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PlayButtonStyle(fullWidth: true))
                .accessibilityIdentifier("list.playAll")
                Button { Task { await app.playList(shown, shuffled: true) } } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("list.shuffle")
                if !isSmart {
                    Button("Edit") { beginEditing() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("list.edit")
                }
            }
            .disabled(shown.isEmpty)
            .frame(maxWidth: 520)
            HStack {
                Spacer(minLength: 0)
                sortMenu
            }
        }
        .padding(.horizontal, inset)
    }

    private var sortMenu: some View {
        BlueboxMenu("Sort") {
            BlueboxMenuSection("Sort By") {
                for s in MyListSort.options(smart: isSmart) {
                    BlueboxMenuButton(s.title(smart: isSmart), checked: sort == s) { sort = s }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sort.title(smart: isSmart)).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(Palette.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort: \(sort.title(smart: isSmart))")
        .accessibilityIdentifier("list.sort")
    }

    /// Rename or delete one of your lists.
    private var listMenu: some View {
        BlueboxMenu(name) {
            BlueboxMenuButton("Rename…", systemImage: "pencil") {
                if let list { app.listEditor = ListEditorRequest(list: list, adding: nil) }
            }
            BlueboxMenuSection {
                BlueboxMenuButton("Delete List", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 44, height: 44)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Palette.edge))
                .contentShape(Circle())
        }
        .accessibilityLabel("More for \(name)")
    }

    // MARK: Edit

    private func beginEditing() {
        editOrder = MyListArrangement.arrange(recent, filter: .all, sort: .manual, manual: manual)
        selection = []
        withAnimation(Motion.standard(reduceMotion)) { editing = true }
    }

    private func finishEditing() {
        let keys = editOrder.map(\.key)
        withAnimation(Motion.standard(reduceMotion)) { editing = false }
        guard keys != manual else { return }
        manual = keys
        sort = .manual
        rearrange()
        Task { await app.reorder(id, keys: keys) }
    }

    private func removeSelected() {
        let keys = Array(selection)
        let removed = editOrder.filter { selection.contains($0.key) }
        editOrder.removeAll { selection.contains($0.key) }
        selection = []
        Task { await app.remove(keys, titles: removed, from: id) }
    }

    private func editList(inset: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Button(selection.isEmpty ? "Remove" : "Remove (\(selection.count))", role: .destructive) { removeSelected() }
                    .buttonStyle(SecondaryButtonStyle())
                    .foregroundStyle(Palette.destructive)
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("list.removeSelected")
                Spacer(minLength: 0)
                Button("Done") { finishEditing() }
                    .buttonStyle(PlayButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("list.done")
            }
            .padding(.horizontal, inset).padding(.vertical, Spacing.m)
            Text("Drag to reorder. Select titles to remove them.")
                .font(.footnote).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset).padding(.bottom, Spacing.s)
            List(selection: $selection) {
                ForEach(editOrder, id: \.key) { t in
                    HStack(spacing: Spacing.m) {
                        ArtworkView(url: app.imageURL(t.poster, width: 40), fallbackTitle: t.name, kind: .poster,
                                    pixelWidth: 80, showsFallbackTitle: false)
                            .frame(width: 34, height: 51)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Text([t.year.map(String.init), t.kind == .movie ? "Film" : "Series"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .listRowBackground(selection.contains(t.key) ? Palette.wash : Palette.background)
                    .listRowSeparatorTint(Palette.separator)
                }
                .onMove { from, to in editOrder.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
    }
}

// MARK: - Add to List

/// What the Add to List card shows for one title. A reference, so a menu
/// (built when it opens, outside the view's body) reads what was loaded.
@MainActor final class AddToListState {
    var onMyList = false
    var lists: [UserList] = []
    var member: Set<String> = []

    /// Reads the ticks before the card opens, so they're right when it appears.
    func load(_ app: AppModel, _ title: Title) async {
        onMyList = (try? await app.store.isOnWatchlist(title.key)) ?? false
        lists = (try? await app.store.lists()) ?? []
        member = (try? await app.store.listIDs(containing: title.key)) ?? []
    }

    /// The card (decision 11): My List and your lists with ticks, and New List….
    /// - Parameter toggleMyList: replaces the default My List toggle (the
    ///   title page uses its own, which updates the tile at once).
    @BlueboxMenuBuilder
    func entries(_ app: AppModel, _ title: Title, toggleMyList: (@MainActor (Bool) -> Void)? = nil) -> [BlueboxMenuEntry] {
        BlueboxMenuTitle("Add to List", subtitle: title.name)
        BlueboxMenuSection {
            BlueboxMenuButton("My List", systemImage: "plus", checked: onMyList) { [onMyList] in
                if let toggleMyList { toggleMyList(!onMyList) } else { Task { await app.toggleWatchlistWithToast(title, adding: !onMyList) } }
            }
            for l in lists {
                BlueboxMenuButton(l.name, systemImage: l.symbol, checked: member.contains(l.id)) { [member] in
                    Task { await app.setOnList(title, list: l, !member.contains(l.id)) }
                }
            }
        }
        BlueboxMenuSection {
            BlueboxMenuButton("New List…", systemImage: "plus.rectangle.on.rectangle") {
                app.listEditor = ListEditorRequest(list: nil, adding: title)
            }
        }
    }
}

extension View {
    /// The Add to List card on its own anchor. Set `request` to true to open
    /// it. (Posters show it in their quick-action menu's place instead, so a
    /// grid doesn't get a second anchor per card.)
    func addToListMenu(_ title: Title, request: Binding<Bool>,
                       toggleMyList: (@MainActor (Bool) -> Void)? = nil) -> some View {
        modifier(AddToListMenu(title: title, request: request, toggleMyList: toggleMyList))
    }
}

private struct AddToListMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    let title: Title
    @Binding var request: Bool
    let toggleMyList: (@MainActor (Bool) -> Void)?
    @State private var open = false
    @State private var state = AddToListState()

    func body(content: Content) -> some View {
        content
            .blueboxMenu(isPresented: $open, title: "Add to List") { state.entries(app, title, toggleMyList: toggleMyList) }
            .onChange(of: request) { _, wanted in
                guard wanted else { return }
                request = false
                Task {
                    await state.load(app, title)
                    open = true
                }
            }
    }
}

// MARK: - New List / Edit List

extension View {
    /// Draws New List and Edit List over the window. Put it once, on the root view.
    func listEditorHost() -> some View { modifier(ListEditorHost()) }
}

private struct ListEditorHost: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if let request = app.listEditor {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture { app.listEditor = nil }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    ListEditorCard(request: request)
                        .id(request.id)
                        .transition(Motion.pop(reduceMotion, scale: 0.96))
                }
            }
            .animation(Motion.popover(reduceMotion), value: app.listEditor?.id)
        }
    }
}

/// The list editor: a name and a symbol, on the same solid panel as menus.
struct ListEditorCard: View {
    @Environment(AppModel.self) private var app
    let request: ListEditorRequest
    @State private var name = ""
    @State private var symbol = UserList.defaultSymbol
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    /// Plain symbols that read at a glance, no "AI" sparkles.
    static let symbols = [
        "list.bullet", "star.fill", "heart.fill", "moon.fill", "flame.fill", "film",
        "tv", "popcorn.fill", "theatermasks.fill", "person.2.fill", "house.fill", "airplane",
        "gift.fill", "leaf.fill", "snowflake", "sun.max.fill", "bolt.fill", "trophy.fill",
        "music.note", "book.fill", "pawprint.fill", "gamecontroller.fill", "graduationcap.fill", "clock.fill",
    ]

    private var isNew: Bool { request.list == nil }
    private var canSave: Bool { UserList.cleanName(name) != nil && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New List" : "Edit List").font(.headline).foregroundStyle(Palette.textPrimary)
                if let t = request.adding {
                    Text("Adds “\(t.name)”").font(.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                TextField("List name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: 44)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(nameFocused ? Palette.brand : Palette.edge, lineWidth: nameFocused ? 1.5 : 1))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("listEditor.name")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 6), spacing: Spacing.xs) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(symbol == s ? Palette.textPrimary : Palette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(symbol == s ? Palette.wash : .clear,
                                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(symbol == s ? Palette.brand : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(s.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(symbol == s ? .isSelected : [])
                }
            }
            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)
                Button("Cancel") { app.listEditor = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: save)
                    .buttonStyle(PlayButtonStyle())
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("listEditor.save")
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 380)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                shape.fill(Palette.surface)
                shape.strokeBorder(Palette.edge, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
        }
        .padding(Spacing.l)
        .environment(\.colorScheme, .dark)
        .onAppear {
            name = request.list?.name ?? ""
            symbol = request.list?.symbol ?? UserList.defaultSymbol
            nameFocused = true
        }
        .onKeyPress(.escape) { app.listEditor = nil; return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { app.listEditor = nil }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        Task {
            if let list = request.list {
                await app.updateList(list, name: name, symbol: symbol)
            } else {
                await app.createList(name: name, symbol: symbol, adding: request.adding)
            }
            app.listEditor = nil
        }
    }
}

// MARK: - The title page's My List tile

/// The title page's + tile (decision 11): a tap adds to or removes from My
/// List as before; press and hold, or right-click on Mac, opens Add to List.
struct MyListTile: View {
    @Environment(AppModel.self) private var app
    let model: TitleDetailModel
    @State private var listsRequest = false
    @State private var gate = QuickActionGate()

    var body: some View {
        Button {
            guard !gate.consumeHold() else { return }
            setOnMyList(!model.onList)
        } label: {
            Label("My List", systemImage: model.onList ? "checkmark" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            gate.held()
            listsRequest = true
        })
        #if os(macOS)
        .overlay { SecondaryClickCatcher { listsRequest = true } }
        #endif
        .addToListMenu(model.display, request: $listsRequest) { on in setOnMyList(on) }
        .accessibilityValue(model.onList ? "On My List" : "Not on My List")
        .accessibilityAction(named: "Add to List…") { listsRequest = true }
        .accessibilityIdentifier("watchlistButton")
        .keyboardShortcut("l", modifiers: .command)
        .help(model.onList ? "Remove from My List (⌘L). Hold for your other lists." : "Add to My List (⌘L). Hold for your other lists.")
    }

    /// Optimistic, so the tile flips at once and flips back if the save fails.
    private func setOnMyList(_ on: Bool) {
        let title = model.display, model = model
        Task {
            await app.optimistic(on ? "Couldn't add to My List" : "Couldn't remove from My List",
                                 from: !on, to: on, apply: { model.onList = $0 }) { try await app.setOnMyList(title, on) }
        }
    }
}
