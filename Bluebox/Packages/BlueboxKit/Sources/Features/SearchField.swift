import DesignSystem
import Domain
import SwiftUI

/// The search field's text lives here, not in `SearchView`: each keystroke
/// redraws only the field, and the page gets the trimmed query once typing
/// pauses for `delay` (an emptied field and Return go through at once).
enum SearchDebounce {
    static let delay = Duration.milliseconds(250)

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// Run from `.task(id: text)`: a newer keystroke cancels it.
    @MainActor
    static func publish(_ text: String, to query: Binding<String>) async {
        let q = trimmed(text)
        guard q != query.wrappedValue else { return }
        if !q.isEmpty {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
        }
        query.wrappedValue = q
    }
}

/// The field under the top bar (Mac, iPad), where there's no navigation bar to hold one.
struct SearchQueryField: View {
    @Binding var query: String
    let results: PagedTitles
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
            TextField("Search shows, movies, genres", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .autocorrectionDisabled()
                .onSubmit(submit)
                .accessibilityIdentifier("searchField")
            if results.isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Searching")
            }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(height: 48)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(focused ? Palette.brand.opacity(0.8) : Palette.separator, lineWidth: focused ? 1.5 : 1))
        .frame(maxWidth: 640)
        .padding(.top, Spacing.s)
        .task(id: text) { await SearchDebounce.publish(text, to: $query) }
        // A recent search picked on the page fills the field.
        .onChange(of: query, initial: true) { _, q in if SearchDebounce.trimmed(text) != q { text = q } }
        .modifier(SearchFocusRequests(focused: $focused, focusOnFirstAppear: true))
    }

    private func submit() {
        let q = SearchDebounce.trimmed(text)
        query = q
        onSubmit(q)
    }
}

#if os(iOS)
/// The navigation bar's search field (iPhone), with its text kept here so
/// typing doesn't redraw the page it's attached to.
struct DebouncedSearchable: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search shows, movies, genres")
                .searchFocused($focused)
                .onSubmit(of: .search) {
                    let q = SearchDebounce.trimmed(text)
                    query = q
                    onSubmit(q)
                }
                .task(id: text) { await SearchDebounce.publish(text, to: $query) }
                .onChange(of: query, initial: true) { _, q in if SearchDebounce.trimmed(text) != q { text = q } }
                .modifier(SearchFocusRequests(focused: $focused, focusOnFirstAppear: false))
        } else {
            content
        }
    }
}
#endif

/// Focuses the field when Search is chosen again (or ⌘F), waiting out the
/// transition: focusing during a pop or a tab crossfade doesn't stick.
private struct SearchFocusRequests: ViewModifier {
    var focused: FocusState<Bool>.Binding
    /// The top-bar field also focuses when the page first opens.
    let focusOnFirstAppear: Bool
    @Environment(\.searchFocusRequest) private var focusRequest
    @State private var isVisible = false
    @State private var focusOnAppear = false

    func body(content: Content) -> some View {
        content
            .task {
                guard focusOnFirstAppear else { return }
                try? await Task.sleep(for: .milliseconds(350))
                focused.wrappedValue = true
            }
            .onAppear {
                isVisible = true
                if focusOnAppear { focusOnAppear = false; focusSoon() }
            }
            .onDisappear { isVisible = false }
            .onChange(of: focusRequest) {
                // Popped back from a title page: focus once it's on screen again.
                if isVisible { focusSoon() } else { focusOnAppear = true }
            }
    }

    private func focusSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            focused.wrappedValue = true
        }
    }
}

// MARK: - Recent searches

/// Recent searches as rows: the top result's picture, the query and what it
/// found. Tap to search again; × or a swipe left removes one; Clear All empties it.
struct RecentSearchesList: View {
    let recents: [RecentSearch]
    let onPick: (RecentSearch) -> Void
    let onRemove: (RecentSearch) -> Void
    let onClear: () -> Void
    /// The first few; the rest behind "Show More".
    @State private var expanded = false
    static let collapsedCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Searches").font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear All", action: onClear)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Spacing.l)], spacing: 0) {
                ForEach(expanded ? recents : Array(recents.prefix(Self.collapsedCount))) { r in
                    RecentSearchRow(recent: r, onPick: { onPick(r) }, onRemove: { onRemove(r) })
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            if recents.count > Self.collapsedCount {
                Button(expanded ? "Show Less" : "Show More") { withAnimation(Motion.standard(false)) { expanded.toggle() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 36)
            }
        }
    }
}

private struct RecentSearchRow: View {
    @Environment(AppModel.self) private var app
    let recent: RecentSearch
    let onPick: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false
    /// How far the row has been dragged left.
    @State private var offset: CGFloat = 0
    /// A drag this far left removes the row.
    static let removeDistance: CGFloat = 90

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button(action: onPick) {
                HStack(spacing: Spacing.m) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recent.query).font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        if let detail = recent.detail {
                            Text(detail).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(recent.query)
            .accessibilityValue(recent.detail ?? "")
            .accessibilityHint("Searches again")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hovering ? Palette.textPrimary : Palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Remove \(recent.query)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Spacing.xs)
        .background(hovering ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .offset(x: offset)
        .opacity(1 - Double(min(-offset, Self.removeDistance * 1.5) / (Self.removeDistance * 2)))
        #if os(iOS)
        // Swipe left to remove. Only a clearly sideways drag counts, so the page still scrolls.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { g in
                    guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                    offset = min(0, g.translation.width)
                }
                .onEnded { g in
                    if g.translation.width < -Self.removeDistance, abs(g.translation.width) > abs(g.translation.height) {
                        onRemove()
                    } else {
                        withAnimation(Motion.standard(false)) { offset = 0 }
                    }
                })
        #endif
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contextMenu {
            Button { onPick() } label: { Label("Search Again", systemImage: "magnifyingglass") }
            Button(role: .destructive) { onRemove() } label: { Label("Remove", systemImage: "xmark") }
        }
        .accessibilityAction(named: "Remove") { onRemove() }
    }

    /// The top result's poster or portrait; a magnifying glass until one is known.
    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
        if let art = recent.artwork {
            ArtworkView(url: app.imageURL(art, width: 40), fallbackTitle: recent.query,
                        kind: art.kind == .profile ? .profile : .poster, pixelWidth: 80, showsFallbackTitle: false)
                .frame(width: 40, height: 60)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.edge))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 40, height: 60)
                .background(Palette.surface, in: shape)
                .accessibilityHidden(true)
        }
    }
}
