import SwiftUI

// Bluebox's own dropdown menus: a solid grey panel anchored under its button,
// in place of the stock system `Menu`.
//
//     BlueboxMenu("Profile") {
//         BlueboxMenuSection("Who's Watching") {
//             for p in profiles {
//                 BlueboxMenuButton(p.name, avatar: p.symbol, color: p.color, checked: p.id == current) { … }
//             }
//         }
//         BlueboxMenuButton("Settings…", systemImage: "gearshape", shortcut: "⌘,") { … }
//         BlueboxMenuNote("Library on this device")
//     } label: { Avatar() }
//
// For a trigger you draw yourself (a split button, say) use
// `.blueboxMenu(isPresented:) { … }` on it.
//
// Panels draw in a layer installed once near the root with `.blueboxMenuHost()`,
// so they float over the top bar and everything else and can't be clipped.
// Without a host (a sheet, another window) the panel falls back to a popover.
//
// Mac: hover highlights, ↑/↓ and Home/End move, Return or Space picks, typing
// a letter jumps, Esc or a click outside closes. iOS: press highlight and a
// light haptic on open and pick. VoiceOver reads it as a modal group of buttons.

// MARK: - Content

/// One line of a menu.
public enum BlueboxMenuEntry {
    case item(BlueboxMenuItem)
    /// Starts a group: a separator above it (unless it's first) and an optional small header.
    case section(String?)
    case divider
    /// Non-interactive text, such as a status line.
    case note(String)
    /// What the menu is about, at its top: a title in full weight and a line
    /// of detail ("Sintel" / "2010 · Film · 15 min").
    case title(String, subtitle: String?)
    /// A highlighted status block: a symbol, a headline, an explanation and
    /// an optional fix, e.g. "Not syncing since 14:02 … Sign In Again".
    case alert(BlueboxMenuAlert)
    /// A row of big avatars, one click each (the profile menu's switcher).
    case avatars([BlueboxMenuAvatar])
}

/// One avatar in a menu's avatar row.
public struct BlueboxMenuAvatar: Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    public var color: Color
    public var isCurrent: Bool
    public var isLocked: Bool
    /// Shown in the tooltip ("⌃⌘2").
    public var shortcut: String?
    public var action: @MainActor () -> Void

    public init(id: String, title: String, symbol: String, color: Color, isCurrent: Bool, isLocked: Bool = false,
                shortcut: String? = nil, action: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.symbol = symbol; self.color = color
        self.isCurrent = isCurrent; self.isLocked = isLocked; self.shortcut = shortcut; self.action = action
    }
}

public struct BlueboxMenuAvatarRow: BlueboxMenuElement {
    let avatars: [BlueboxMenuAvatar]
    public init(_ avatars: [BlueboxMenuAvatar]) { self.avatars = avatars }
    public var entries: [BlueboxMenuEntry] { avatars.isEmpty ? [] : [.avatars(avatars)] }
}

/// A status block at the top of a menu, with one fix.
public struct BlueboxMenuAlert {
    public var systemImage: String
    public var title: String
    public var message: String?
    public var actionTitle: String?
    public var action: (@MainActor () -> Void)?

    public init(systemImage: String = "exclamationmark.circle.fill", title: String, message: String? = nil,
                actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.systemImage = systemImage; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }
}

/// The menu's subject: a title and a line of detail.
public struct BlueboxMenuTitle: BlueboxMenuElement {
    let title: String
    let subtitle: String?
    public init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    public var entries: [BlueboxMenuEntry] { [.title(title, subtitle: subtitle)] }
}

public struct BlueboxMenuAlertBlock: BlueboxMenuElement {
    let alert: BlueboxMenuAlert
    public init(_ alert: BlueboxMenuAlert) { self.alert = alert }
    public var entries: [BlueboxMenuEntry] { [.alert(alert)] }
}

public struct BlueboxMenuItem {
    public enum Leading {
        case none
        case symbol(String)
        /// A profile-style badge: a rounded square in `color` with a symbol.
        case avatar(symbol: String, color: Color)
    }

    public var title: String
    public var subtitle: String?
    public var leading: Leading
    public var isChecked: Bool
    public var isDestructive: Bool
    public var isDisabled: Bool
    /// Shown trailing, for reference only ("⌘,"). The real shortcut lives in the app's commands.
    public var shortcut: String?
    public var action: @MainActor () -> Void
}

/// Anything that can sit in a `BlueboxMenu` builder.
public protocol BlueboxMenuElement {
    var entries: [BlueboxMenuEntry] { get }
}

extension BlueboxMenuEntry: BlueboxMenuElement {
    public var entries: [BlueboxMenuEntry] { [self] }
}

/// A menu item.
public struct BlueboxMenuButton: BlueboxMenuElement {
    let item: BlueboxMenuItem
    public var entries: [BlueboxMenuEntry] { [.item(item)] }

    public init(_ title: String, systemImage: String? = nil, subtitle: String? = nil, checked: Bool = false,
                role: ButtonRole? = nil, disabled: Bool = false, shortcut: String? = nil,
                action: @escaping @MainActor () -> Void) {
        item = BlueboxMenuItem(title: title, subtitle: subtitle, leading: systemImage.map { .symbol($0) } ?? .none,
                               isChecked: checked, isDestructive: role == .destructive, isDisabled: disabled,
                               shortcut: shortcut, action: action)
    }

    /// An item led by a profile-style badge.
    public init(_ title: String, avatar symbol: String, color: Color, subtitle: String? = nil, checked: Bool = false,
                action: @escaping @MainActor () -> Void) {
        item = BlueboxMenuItem(title: title, subtitle: subtitle, leading: .avatar(symbol: symbol, color: color),
                               isChecked: checked, isDestructive: false, isDisabled: false, shortcut: nil, action: action)
    }
}

/// A group of items with an optional header; separated from what's above it.
public struct BlueboxMenuSection: BlueboxMenuElement {
    public let entries: [BlueboxMenuEntry]
    public init(_ title: String? = nil, @BlueboxMenuBuilder _ content: () -> [BlueboxMenuEntry]) {
        entries = [.section(title)] + content()
    }
}

public struct BlueboxMenuDivider: BlueboxMenuElement {
    public init() {}
    public var entries: [BlueboxMenuEntry] { [.divider] }
}

public struct BlueboxMenuNote: BlueboxMenuElement {
    let text: String
    public init(_ text: String) { self.text = text }
    public var entries: [BlueboxMenuEntry] { [.section(nil), .note(text)] }
}

@resultBuilder
public enum BlueboxMenuBuilder {
    public static func buildExpression(_ e: some BlueboxMenuElement) -> [BlueboxMenuEntry] { e.entries }
    public static func buildExpression(_ e: [BlueboxMenuEntry]) -> [BlueboxMenuEntry] { e }
    public static func buildBlock(_ parts: [BlueboxMenuEntry]...) -> [BlueboxMenuEntry] { parts.flatMap { $0 } }
    public static func buildOptional(_ e: [BlueboxMenuEntry]?) -> [BlueboxMenuEntry] { e ?? [] }
    public static func buildEither(first e: [BlueboxMenuEntry]) -> [BlueboxMenuEntry] { e }
    public static func buildEither(second e: [BlueboxMenuEntry]) -> [BlueboxMenuEntry] { e }
    public static func buildArray(_ parts: [[BlueboxMenuEntry]]) -> [BlueboxMenuEntry] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ e: [BlueboxMenuEntry]) -> [BlueboxMenuEntry] { e }
}

// MARK: - Trigger

/// A button that opens a Bluebox menu. Drop-in for SwiftUI's `Menu`.
public struct BlueboxMenu<Label: View>: View {
    let title: String
    let content: @MainActor () -> [BlueboxMenuEntry]
    let label: Label
    @State private var isPresented = false

    /// - Parameter title: names the menu for VoiceOver.
    public init(_ title: String, @BlueboxMenuBuilder content: @escaping @MainActor () -> [BlueboxMenuEntry],
                @ViewBuilder label: () -> Label) {
        self.title = title; self.content = content; self.label = label()
    }

    public var body: some View {
        Button { isPresented.toggle() } label: { label }
            .buttonStyle(MenuTriggerStyle(isOpen: isPresented))
            .blueboxMenu(isPresented: $isPresented, title: title, content: content)
            .accessibilityHint("Opens a menu")
    }
}

/// Dims a trigger while pressed or while its menu is open.
private struct MenuTriggerStyle: ButtonStyle {
    let isOpen: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : isOpen ? 0.8 : 1)
            #if os(iOS)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            #endif
            .animation(Motion.press, value: configuration.isPressed)
    }
}

public extension View {
    /// Shows a Bluebox menu anchored to this view while `isPresented` is true.
    func blueboxMenu(isPresented: Binding<Bool>, title: String = "Menu",
                     @BlueboxMenuBuilder content: @escaping @MainActor () -> [BlueboxMenuEntry]) -> some View {
        modifier(BlueboxMenuAnchor(isPresented: isPresented, title: title, content: content))
    }

    /// Installs the layer menus draw in. Put it once, outermost, on each window's root view.
    func blueboxMenuHost() -> some View { modifier(BlueboxMenuHost()) }
}

// MARK: - Presentation

@MainActor @Observable
final class BlueboxMenuPresenter {
    struct Active {
        let id: UUID
        var anchor: CGRect
        let title: String
        let content: @MainActor () -> [BlueboxMenuEntry]
        let onDismiss: @MainActor () -> Void
    }

    var active: Active?

    func present(_ a: Active) {
        if let old = active, old.id != a.id { old.onDismiss() }
        active = a
    }

    func dismiss(_ id: UUID? = nil) {
        guard let a = active, id == nil || a.id == id else { return }
        active = nil
        a.onDismiss()
    }

    func move(_ id: UUID, to anchor: CGRect) {
        if active?.id == id, active?.anchor != anchor { active?.anchor = anchor }
    }
}

extension EnvironmentValues {
    @Entry var blueboxMenuPresenter: BlueboxMenuPresenter? = nil
}

/// Not observable on purpose: writing it never re-renders anything.
final class AnchorBox { var frame: CGRect = .zero }

private struct BlueboxMenuAnchor: ViewModifier {
    @Environment(\.blueboxMenuPresenter) private var presenter
    @Binding var isPresented: Bool
    let title: String
    let content: @MainActor () -> [BlueboxMenuEntry]
    @State private var id = UUID()
    /// Where the anchor is, in a plain box: it changes on every frame of a
    /// scroll, and keeping it in `@State` invalidated every card each frame.
    @State private var box = AnchorBox()

    func body(content view: Content) -> some View {
        if let presenter {
            view
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
                    box.frame = new
                    if presenter.active?.id == id { presenter.move(id, to: new) }
                }
                .onChange(of: isPresented) { _, open in
                    if open {
                        presenter.present(.init(id: id, anchor: box.frame, title: title, content: content,
                                                onDismiss: { isPresented = false }))
                    } else {
                        presenter.dismiss(id)
                    }
                }
                .onDisappear { presenter.dismiss(id) }
        } else {
            view.popover(isPresented: $isPresented, arrowEdge: .bottom) {
                BlueboxMenuPanel(title: title, entries: content(), dismiss: { isPresented = false }, inPopover: true)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

private struct BlueboxMenuHost: ViewModifier {
    @State private var presenter = BlueboxMenuPresenter()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.blueboxMenuPresenter, presenter)
            .overlay {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .global).origin
                    ZStack {
                        if let active = presenter.active {
                            // Clicks outside close the menu (and, like a system menu, go no further).
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { close() }
                                .accessibilityHidden(true)
                            MenuPlacement(anchor: active.anchor.offsetBy(dx: -origin.x, dy: -origin.y)) {
                                BlueboxMenuPanel(title: active.title, entries: active.content(), dismiss: close)
                                    .id(active.id)
                                    .transition(transition(for: active, in: proxy.size.height, originY: origin.y))
                            }
                        }
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: presenter.active?.id)
                }
                .ignoresSafeArea()
            }
            #if os(iOS)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: presenter.active?.id) { _, new in new != nil }
            #endif
    }

    private func close() { presenter.dismiss() }

    private func transition(for a: BlueboxMenuPresenter.Active, in height: CGFloat, originY: CGFloat) -> AnyTransition {
        if reduceMotion { return .opacity }
        let opensUp = a.anchor.midY - originY > height * 0.6
        return .asymmetric(insertion: .scale(scale: 0.94, anchor: opensUp ? .bottom : .top).combined(with: .opacity),
                           removal: .opacity)
    }
}

/// Places the panel under its anchor (or above, if there's more room there),
/// aligned to the anchor's leading edge, or trailing edge on the right half,
/// and kept inside the window.
private struct MenuPlacement: Layout {
    let anchor: CGRect
    let margin: CGFloat = 8
    let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let below = bounds.maxY - anchor.maxY - gap - margin
        let above = anchor.minY - bounds.minY - gap - margin
        let natural = panel.sizeThatFits(.init(width: nil, height: max(below, above)))
        let opensUp = natural.height > below && above > below
        let height = min(natural.height, opensUp ? above : below)
        let width = min(natural.width, bounds.width - margin * 2)
        let size = panel.sizeThatFits(.init(width: width, height: height))
        var x = anchor.midX > bounds.midX ? anchor.maxX - size.width : anchor.minX
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        let y = opensUp ? anchor.minY - gap - size.height : anchor.maxY + gap
        panel.place(at: CGPoint(x: x, y: y), proposal: .init(size))
    }
}

// MARK: - Panel

struct BlueboxMenuPanel: View {
    let title: String
    let entries: [BlueboxMenuEntry]
    let dismiss: @MainActor () -> Void
    var inPopover = false

    @State private var highlighted: Int?
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    static let radius: CGFloat = 12
    static let inset: CGFloat = 6

    var body: some View {
        let rows = layout
        ViewThatFits(in: .vertical) {
            list(rows)
            ScrollView { list(rows) }.scrollIndicators(.automatic)
        }
        .frame(minWidth: 220, maxWidth: 340)
        .fixedSize(horizontal: true, vertical: false)
        .background { if !inPopover { surface } }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.home) { highlighted = selectable.first; return .handled }
        .onKeyPress(.end) { highlighted = selectable.last; return .handled }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(phases: .down) { press in jump(to: press.characters) }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
    }

    /// A solid panel (the OLED finish has no glass): opaque grey, a faint
    /// edge, and a soft shadow to lift it off black.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return ZStack {
            shape.fill(Palette.surface)
            shape.strokeBorder(contrast == .increased ? Color.white.opacity(0.35) : Palette.edge, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
    }

    // MARK: Rows

    private enum Row {
        case item(Int, BlueboxMenuItem)
        case header(String)
        case separator
        case note(String)
        case title(String, String?)
        case alert(BlueboxMenuAlert)
        case avatars([BlueboxMenuAvatar])
    }

    /// Entries cleaned up: no separator first, last or doubled.
    private var layout: [Row] {
        var out: [Row] = []
        var pendingSeparator = false
        for (i, e) in entries.enumerated() {
            switch e {
            case .section(let title):
                if !out.isEmpty { pendingSeparator = true }
                if let title {
                    if pendingSeparator { out.append(.separator); pendingSeparator = false }
                    out.append(.header(title))
                }
            case .divider:
                if !out.isEmpty { pendingSeparator = true }
            case .item(let item):
                if pendingSeparator { out.append(.separator); pendingSeparator = false }
                out.append(.item(i, item))
            case .note(let text):
                if pendingSeparator { out.append(.separator); pendingSeparator = false }
                out.append(.note(text))
            case .title(let title, let subtitle):
                if pendingSeparator { out.append(.separator); pendingSeparator = false }
                out.append(.title(title, subtitle))
                pendingSeparator = true  // the subject stands apart from the actions
            case .alert(let alert):
                if pendingSeparator { out.append(.separator); pendingSeparator = false }
                out.append(.alert(alert))
            case .avatars(let avatars):
                if pendingSeparator { out.append(.separator); pendingSeparator = false }
                out.append(.avatars(avatars))
                pendingSeparator = true
            }
        }
        return out
    }

    private var showsLeadingColumn: Bool {
        entries.contains { entry in
            guard case .item(let i) = entry else { return false }
            if case .none = i.leading { return false }
            return true
        }
    }

    private var showsCheckColumn: Bool {
        entries.contains { if case .item(let i) = $0 { i.isChecked } else { false } }
    }

    private func list(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .item(let index, let item):
                    MenuRow(item: item, highlighted: highlighted == index,
                            leadingColumn: showsLeadingColumn, checkColumn: showsCheckColumn) {
                        activate(item)
                    }
                    .onHover { inside in
                        if inside, !item.isDisabled { highlighted = index } else if highlighted == index { highlighted = nil }
                    }
                case .header(let text):
                    Text(text)
                        .font(Self.headerFont)
                        .foregroundStyle(Palette.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.horizontal, 10)
                        .padding(.top, 6).padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                case .separator:
                    Rectangle().fill(Palette.separator).frame(height: 1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .accessibilityHidden(true)
                case .note(let text):
                    Text(text)
                        .font(Self.noteFont)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .fixedSize(horizontal: false, vertical: true)
                case .title(let title, let subtitle):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(Palette.textPrimary).lineLimit(2)
                        if let subtitle {
                            Text(subtitle).font(Self.noteFont).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                case .alert(let alert):
                    MenuAlertRow(alert: alert, dismiss: dismiss)
                case .avatars(let avatars):
                    MenuAvatarRow(avatars: avatars, dismiss: dismiss)
                }
            }
        }
        .padding(Self.inset)
    }

    #if os(macOS)
    static let headerFont = Font.caption2.weight(.semibold)
    static let noteFont = Font.caption
    #else
    static let headerFont = Font.caption.weight(.semibold)
    static let noteFont = Font.footnote
    #endif

    // MARK: Keyboard

    private var selectable: [Int] {
        entries.indices.filter { if case .item(let i) = entries[$0] { !i.isDisabled } else { false } }
    }

    private func step(_ delta: Int) {
        let list = selectable
        guard !list.isEmpty else { return }
        guard let current = highlighted, let at = list.firstIndex(of: current) else {
            highlighted = delta > 0 ? list.first : list.last
            return
        }
        highlighted = list[(at + delta + list.count) % list.count]
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let h = highlighted, case .item(let item) = entries[h] else { return .ignored }
        activate(item)
        return .handled
    }

    /// Typing a letter highlights the next item starting with it.
    private func jump(to characters: String) -> KeyPress.Result {
        guard let c = characters.lowercased().first, c.isLetter || c.isNumber else { return .ignored }
        let list = selectable
        let start = highlighted.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let ordered = Array(list[start...] + list[..<start])
        if let hit = ordered.first(where: { if case .item(let i) = entries[$0] { i.title.lowercased().first == c } else { false } }) {
            highlighted = hit
            return .handled
        }
        return .ignored
    }

    private func activate(_ item: BlueboxMenuItem) {
        guard !item.isDisabled else { return }
        dismiss()
        item.action()
    }
}

private struct MenuRow: View {
    let item: BlueboxMenuItem
    let highlighted: Bool
    let leadingColumn: Bool
    let checkColumn: Bool
    let action: () -> Void

    #if os(macOS)
    private let minHeight: CGFloat = 28
    private let font = Font.body.weight(.medium)
    private let iconWidth: CGFloat = 18
    #else
    private let minHeight: CGFloat = 44
    private let font = Font.body
    private let iconWidth: CGFloat = 24
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if leadingColumn { leading.frame(width: iconWidth) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(font).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.l)
                if let shortcut = item.shortcut {
                    Text(shortcut).font(.callout).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                }
                if checkColumn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Palette.brandBright)
                        .opacity(item.isChecked ? 1 : 0)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(item.isDestructive ? Palette.destructive : Palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, item.subtitle == nil ? 2 : 5)
            .frame(minHeight: minHeight)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted))
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.4 : 1)
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: highlighted)
        #endif
    }

    @ViewBuilder private var leading: some View {
        switch item.leading {
        case .none: Color.clear.frame(height: 1)
        case .symbol(let name):
            Image(systemName: name)
                .font(.body.weight(.medium))
                .foregroundStyle(item.isDestructive ? Palette.destructive : Palette.textSecondary)
                .accessibilityHidden(true)
        case .avatar(let symbol, let color):
            let side = iconWidth + 2
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(color)
                .frame(width: side, height: side)
                .overlay(Image(systemName: symbol).font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white))
                .accessibilityHidden(true)
        }
    }
}

/// Inner radius is concentric with the panel: 12 − 6 = 6. Hover and keyboard
/// highlight is a blue wash; a press deepens it.
private struct MenuRowStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: BlueboxMenuPanel.radius - BlueboxMenuPanel.inset, style: .continuous)
                    .fill(configuration.isPressed ? Palette.brand.opacity(0.32) : highlighted ? Palette.wash : .clear)
            }
            .animation(.easeOut(duration: 0.1), value: highlighted)
    }
}

/// The profile menu's switcher: a row of avatars with names under them. The
/// current one has a white ring; locked ones show a padlock by the name.
private struct MenuAvatarRow: View {
    let avatars: [BlueboxMenuAvatar]
    let dismiss: @MainActor () -> Void

    #if os(macOS)
    private let side: CGFloat = 40
    #else
    private let side: CGFloat = 48
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(avatars) { a in
                MenuAvatarButton(avatar: a, side: side) {
                    dismiss()
                    a.action()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6).padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who's Watching")
        .accessibilityIdentifier("menuAvatars")
    }
}

private struct MenuAvatarButton: View {
    let avatar: BlueboxMenuAvatar
    let side: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                    .fill(LinearGradient(colors: [avatar.color, avatar.color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side, height: side)
                    .overlay(Image(systemName: avatar.symbol).font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white))
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.2 + 3, style: .continuous)
                            .strokeBorder(.white.opacity(avatar.isCurrent ? 1 : hovering ? 0.5 : 0), lineWidth: 2)
                            .padding(-3)
                    }
                HStack(spacing: 3) {
                    if avatar.isLocked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
                    Text(avatar.title).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(avatar.isCurrent || hovering ? Palette.textPrimary : Palette.textSecondary)
            }
            .frame(width: side + 22)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(avatar.shortcut.map { "\(avatar.title) (\($0))" } ?? avatar.title)
        .accessibilityLabel(avatar.isLocked ? "\(avatar.title), locked" : avatar.title)
        .accessibilityAddTraits(avatar.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("menuAvatar.\(avatar.title)")
    }
}

/// A status block in a menu: amber symbol, headline, explanation, and one
/// fix as a blue text button. Picking the fix closes the menu.
private struct MenuAlertRow: View {
    let alert: BlueboxMenuAlert
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.caution)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = alert.message {
                    Text(message).font(.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let title = alert.actionTitle, let action = alert.action {
                    Button {
                        dismiss()
                        action()
                    } label: {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brandBright)
                            .frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menuAlert.action")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Palette.caution.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: BlueboxMenuPanel.radius - BlueboxMenuPanel.inset, style: .continuous))
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menuAlert")
    }
}

public extension Palette {
    /// Destructive menu items and buttons: a soft red that passes 4.5:1 on the menu surface.
    static let destructive = Color(red: 1.0, green: 0.45, blue: 0.45)
    /// Something needs attention but nothing is broken (sync paused): amber,
    /// the one warm colour, used sparingly.
    static let caution = Color(red: 0.91, green: 0.71, blue: 0.36)
}
