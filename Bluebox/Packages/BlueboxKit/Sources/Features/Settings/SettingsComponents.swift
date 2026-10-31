import DesignSystem
import Domain
import SwiftUI

// Settings' look: Netflix's account pages on Bluebox's OLED-black finish.
// A big heavy title, plain rows separated by hairlines (no inset cards),
// grey uppercase section headers, short grey footers, values right-aligned
// in grey with a chevron, blue switches. Pages keep writing ordinary
// `Section { … } header: { … } footer: { … }` blocks; `SettingsForm` lays
// them out in this style (custom container sections, iOS 18 / macOS 15).

// MARK: - Metrics

enum SettingsMetrics {
    #if os(macOS)
    static let rowHeight: CGFloat = 40
    static let rowPadding: CGFloat = 9
    static let sectionGap: CGFloat = 34
    static let pageInset: CGFloat = 40
    static let titleFont = Font.system(size: 30, weight: .heavy)
    static let rowFont = Font.system(size: 14)
    #else
    static let rowHeight: CGFloat = 50
    static let rowPadding: CGFloat = 12
    static let sectionGap: CGFloat = 36
    static let pageInset: CGFloat = 20
    static let titleFont = Font.largeTitle.weight(.heavy)
    static let rowFont = Font.body
    #endif
    static let maxWidth: CGFloat = 760
    static let hairline = Palette.separator
    static let destructive = Color(red: 0.92, green: 0.24, blue: 0.27)
}

// MARK: - Search reveal

/// Which setting a search hit asked to show. The page holding it scrolls to
/// the row and flashes it.
@MainActor @Observable
final class SettingsReveal {
    var target: SettingsSearchIndex.Entry?
}

extension EnvironmentValues {
    @Entry var settingsReveal: SettingsReveal? = nil
}

extension ContainerValues {
    /// The search index title of a row, so search can scroll to it.
    @Entry var settingsRowID: String? = nil
}

extension View {
    /// Names a row for Settings search (`SettingsSearchIndex.Entry.title`).
    func settingsRow(_ title: String) -> some View { containerValue(\.settingsRowID, title) }
}

// MARK: - Page

/// A settings page: big title, an optional live preview, then the sections.
/// iPhone pins the preview above the scrolling list; iPad and Mac show it under the title.
struct SettingsForm<Content: View, Preview: View>: View {
    let title: String
    let page: SettingsPage?
    /// A page one level down from `page` ("Torrent Engine"), for search hits there.
    var subpage: String?
    let preview: Preview?
    @ViewBuilder let content: Content

    @Environment(\.settingsReveal) private var reveal
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var highlighted: String?
    @State private var position = ScrollPosition(edge: .top)
    @State private var rowFrames = SettingsRowFrames()
    @State private var scrolledPastTitle = false

    init(_ page: SettingsPage, @ViewBuilder content: () -> Content) where Preview == EmptyView {
        self.title = page.title; self.page = page; self.preview = nil; self.content = content()
    }
    init(title: String, @ViewBuilder content: () -> Content) where Preview == EmptyView {
        self.title = title; self.page = nil; self.preview = nil; self.content = content()
    }
    /// A sub-page that search can reveal rows on (`SettingsSearchIndex.Entry.subpage`).
    init(_ page: SettingsPage, subpage: String, @ViewBuilder content: () -> Content) where Preview == EmptyView {
        self.title = subpage; self.page = page; self.subpage = subpage; self.preview = nil; self.content = content()
    }
    init(_ page: SettingsPage, @ViewBuilder preview: () -> Preview, @ViewBuilder content: () -> Content) {
        self.title = page.title; self.page = page; self.preview = preview(); self.content = content()
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact, let preview {
                // iPhone: the title and preview stay put while the controls scroll under them.
                VStack(alignment: .leading, spacing: Spacing.m) {
                    pageTitle
                    preview
                }
                .padding(.horizontal, SettingsMetrics.pageInset)
                .padding(.bottom, Spacing.m)
                .background(Palette.background)
                .overlay(alignment: .bottom) { Rectangle().fill(SettingsMetrics.hairline).frame(height: 1) }
                .zIndex(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if compact, preview != nil {
                        Spacer().frame(height: Spacing.l)
                    } else {
                        pageTitle
                            .padding(.top, Spacing.s)
                            .padding(.bottom, Spacing.xl)
                    }
                    if !compact, let preview {
                        preview.padding(.bottom, Spacing.xl)
                    }
                    SettingsSections(highlighted: highlighted, frames: rowFrames) { content }
                }
                .coordinateSpace(.named(SettingsRowFrames.space))
                .frame(maxWidth: SettingsMetrics.maxWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pageInset)
                .padding(.bottom, Spacing.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top > 44 } action: { _, past in
                scrolledPastTitle = past && !(compact && preview != nil)
            }
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
        }
        .task(id: reveal?.target?.id) { await revealTarget() }
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.brand)
        .toggleStyle(SettingsSwitchStyle())
        .labeledContentStyle(SettingsLabeledContentStyle())
        .buttonStyle(SettingsActionStyle())
        .textFieldStyle(SettingsFieldStyle())
        .navigationTitle(LocalizedStringKey(title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The big title is in the page; the bar's small one fades in once it scrolls away.
            ToolbarItem(placement: .principal) {
                Text(ui: title).font(.headline).opacity(scrolledPastTitle ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: scrolledPastTitle)
                    .accessibilityHidden(!scrolledPastTitle)
            }
        }
        .toolbarBackground(Palette.background, for: .navigationBar)
        #endif
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ui: title)
                .font(SettingsMetrics.titleFont)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            // A category page says what's on it; its sub-pages don't.
            if subpage == nil, let page, page.title == title {
                Text(ui: page.summary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Scrolls to the row a search hit named and flashes it. The target is
    /// cleared only at the end: clearing it changes this task's id, which
    /// would cancel the task midway.
    private func revealTarget() async {
        guard let reveal, let target = reveal.target, target.page == page, target.subpage == subpage else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))  // let the page lay out first
            if let y = rowFrames.minY[target.title] {
                withAnimation(.smooth(duration: 0.45)) { position.scrollTo(y: max(0, y - 160)) }
            }
            withAnimation(.easeOut(duration: 0.2)) { highlighted = target.title }
            try await Task.sleep(for: .seconds(1.6))
        } catch {}
        withAnimation(.easeInOut(duration: 0.6)) { highlighted = nil }
        if reveal.target == target { reveal.target = nil }
    }
}

/// Lays out `Section`s as Netflix-style groups.
/// Where each searchable row sits in its page's content, for search to scroll to.
/// Not observed: writing a frame never redraws the page.
@MainActor
final class SettingsRowFrames {
    static let space = "settings.content"
    var minY: [String: CGFloat] = [:]
}

struct SettingsSections<Content: View>: View {
    var highlighted: String?
    var frames: SettingsRowFrames?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            ForEach(sections: content) { section in
                VStack(alignment: .leading, spacing: 0) {
                    if !section.header.isEmpty {
                        VStack(alignment: .leading, spacing: 0) { section.header }
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.bottom, Spacing.s)
                            .accessibilityAddTraits(.isHeader)
                    }
                    let first = section.content.first?.id
                    ForEach(section.content) { row in
                        let id = row.containerValues.settingsRowID
                        VStack(spacing: 0) {
                            if row.id != first { Rectangle().fill(SettingsMetrics.hairline).frame(height: 1) }
                            row
                                .font(SettingsMetrics.rowFont)
                                .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
                                .padding(.vertical, SettingsMetrics.rowPadding / 2)
                        }
                        .background {
                            if let id, id == highlighted {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.wash)
                                    .padding(.horizontal, -Spacing.s)
                                    .transition(.opacity)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(SettingsRowFrames.space)).minY } action: { y in
                            if let id { frames?.minY[id] = y }
                        }
                    }
                    if !section.footer.isEmpty {
                        VStack(alignment: .leading, spacing: 4) { section.footer }
                            .font(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Spacing.s)
                    }
                }
            }
        }
    }
}

// MARK: - Row styles

/// Text fields as Netflix draws them: a filled box with a faint edge.
struct SettingsFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            #if os(macOS)
            .frame(minHeight: 30)
            #else
            .frame(minHeight: 44)
            #endif
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }
}

/// The title leading, the value trailing in grey.
struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Spacing.l) {
            configuration.label
                .foregroundStyle(Palette.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 0)
            configuration.content
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

/// A blue switch at the trailing edge; the whole row toggles it.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration)
    }

    private struct SettingsSwitch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        #if os(macOS)
        private let size = CGSize(width: 38, height: 22)
        #else
        private let size = CGSize(width: 51, height: 31)
        #endif

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: Spacing.l) {
                    configuration.label
                        .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Capsule()
                        .fill(configuration.isOn ? Palette.brand : Color(white: 0.24))
                        .frame(width: size.width, height: size.height)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white)
                                .padding(2)
                                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        }
                        .opacity(isEnabled ? 1 : 0.45)
                        .animation(Motion.snappy(reduceMotion), value: configuration.isOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 1))
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

/// Action rows ("Save Key", "Clear All Caches"): blue text, red when destructive.
struct SettingsActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(configuration: configuration)
    }

    private struct ActionLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .foregroundStyle(!isEnabled ? Palette.textTertiary
                                 : configuration.role == .destructive ? SettingsMetrics.destructive : Palette.brandBright)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.5 : 1)
        }
    }
}

/// A row that pushes a sub-page: title, the value in grey, and a chevron.
struct SettingsLink<Destination: View>: View {
    let title: String
    var value: String?
    @ViewBuilder let destination: () -> Destination

    init(_ title: String, value: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title; self.value = value; self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: Spacing.l) {
                Text(ui: title).foregroundStyle(Palette.textPrimary).layoutPriority(1)
                Spacer(minLength: 0)
                if let value {
                    Text(value).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
    }
}

/// Opens another page of Settings, as choosing it in the sidebar would: iPad
/// and Mac switch the sidebar's selection, iPhone pushes the page. Set by
/// `SettingsView`; elsewhere (a page drawn on its own) it does nothing.
struct SelectSettingsPageAction {
    let action: @MainActor @Sendable (SettingsPage) -> Void
    @MainActor func callAsFunction(_ page: SettingsPage) { action(page) }
}

extension EnvironmentValues {
    @Entry var selectSettingsPage = SelectSettingsPageAction { _ in }
}

/// A row that opens another sidebar page ("Language" on Appearance): looks
/// like `SettingsLink`, but goes there through `selectSettingsPage` rather
/// than pushing a copy of the page inside this one, so the sidebar, the
/// page's title and its back button stay right.
struct SettingsPageLink: View {
    let title: String
    let page: SettingsPage
    var value: String?
    @Environment(\.selectSettingsPage) private var select

    init(_ title: String, page: SettingsPage, value: String? = nil) {
        self.title = title; self.page = page; self.value = value
    }

    var body: some View {
        Button { select(page) } label: {
            HStack(spacing: Spacing.l) {
                Text(ui: title).foregroundStyle(Palette.textPrimary).layoutPriority(1)
                Spacer(minLength: 0)
                if let value {
                    Text(ui: value).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
    }
}

/// A section header that also says whose settings the section holds, drawn
/// the same way on every page: the topic leading, then "Only for Brian" with
/// the profile's badge, or "Everyone on this Mac". With no topic, the scope
/// is the whole header (a section that's there only to hold the profile's own switches).
struct SettingsScopeHeader: View {
    enum Scope {
        case profile(Profile)
        case everyone
    }

    var title: String?
    let scope: Scope

    init(_ title: String? = nil, scope: Scope) {
        self.title = title; self.scope = scope
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let title {
                Text(ui: title)
                Spacer(minLength: Spacing.s)
            }
            HStack(spacing: 5) {
                switch scope {
                case .profile(let profile):
                    ProfileBadge(symbol: profile.symbol, color: profile.color, size: 14)
                    Self.onlyFor(profile)
                case .everyone:
                    Image(systemName: "person.2.fill").font(.caption2)
                    Text(ui: SettingsPage.everyoneTitle)
                }
            }
            // The topic reads first; the scope is a quieter tag beside it.
            .foregroundStyle(title == nil ? Palette.textSecondary : Palette.textTertiary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settingsScopeHeader")
    }

    /// "Only for Brian", or "Only for You" for the profile that's still called "Me"
    /// (`HomeRowTitles.name`), as whole phrases so each translates on its own.
    static func onlyFor(_ profile: Profile) -> Text {
        HomeRowTitles.name(profile) == profile.name ? Text("Only for \(profile.name)") : Text("Only for You")
    }
}

/// A row that picks one value from a short list on its own page: the title,
/// the current value in grey and a chevron, like iOS Settings. Use it inside a
/// navigation stack, where a ⇅ pop-up menu would be cramped.
struct SettingsChoiceLink<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [BlueboxPickerOption<Value>]
    var footer: String?

    init(_ title: String, selection: Binding<Value>, options: [BlueboxPickerOption<Value>], footer: String? = nil) {
        self.title = title; _selection = selection; self.options = options; self.footer = footer
    }

    var body: some View {
        SettingsLink(title, value: options.first { $0.value == selection }?.title) {
            SettingsChoicePage(title: title, selection: $selection, options: options, footer: footer)
        }
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }
}

/// The list a `SettingsChoiceLink` opens: a check by the current value; a tap picks and goes back.
struct SettingsChoicePage<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [BlueboxPickerOption<Value>]
    let footer: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsForm(title: title) {
            Section {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        HStack(spacing: Spacing.l) {
                            Text(ui: option.title).foregroundStyle(Palette.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Palette.brandBright)
                                .opacity(option.value == selection ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowPressStyle())
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }
}

struct SettingsChevron: View {
    var symbol = "chevron.right"
    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Plain rows that dim while pressed.
struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Picks one value from a Bluebox menu: the title leading, the choice in grey
/// trailing with an up-down chevron. The panel anchors to the value.
struct SettingsPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let groups: [[BlueboxPickerOption<Value>]]
    @State private var open = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, selection: Binding<Value>, options: [BlueboxPickerOption<Value>]) {
        self.init(title, selection: selection, groups: [options])
    }

    init(_ title: String, selection: Binding<Value>, groups: [[BlueboxPickerOption<Value>]]) {
        self.title = title; _selection = selection; self.groups = groups
    }

    private var current: BlueboxPickerOption<Value>? { groups.lazy.flatMap { $0 }.first { $0.value == selection } }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Spacing.l) {
                Text(ui: title)
                    .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let color = current?.color { Circle().fill(color).frame(width: 10, height: 10) }
                    Text(ui: current?.title ?? "").lineLimit(1)
                    SettingsChevron(symbol: "chevron.up.chevron.down")
                }
                .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                .blueboxMenu(isPresented: $open, title: title) { menu }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "")
        .accessibilityHint("Opens a menu")
    }

    @BlueboxMenuBuilder private var menu: [BlueboxMenuEntry] {
        for group in groups {
            BlueboxMenuSection {
                for option in group { item(option) }
            }
        }
    }

    private func item(_ option: BlueboxPickerOption<Value>) -> BlueboxMenuButton {
        let binding = $selection
        let value = option.value
        let checked = value == selection
        if let color = option.color {
            return BlueboxMenuButton(option.title, avatar: option.systemImage ?? "circle.fill", color: color, checked: checked) {
                binding.wrappedValue = value
            }
        }
        return BlueboxMenuButton(option.title, systemImage: option.systemImage, checked: checked) { binding.wrappedValue = value }
    }
}

/// A slider row: title and value on one line, the slider under it.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         format: @escaping (Double) -> String) {
        self.title = title; _value = value; self.range = range; self.step = step; self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(ui: title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(Palette.textSecondary)
            }
            // Bluebox blue on Mac too, where AppKit's slider ignores `.tint`.
            BrandSlider(value: $value, range: range, step: step)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// A status line under a control: icon plus text.
struct SettingsStatus: View {
    let ok: Bool
    let message: String

    var body: some View {
        Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(ok ? Palette.brandBright : Palette.warning)
    }
}

/// One search hit: setting name and where it lives.
struct SettingsSearchRow: View {
    let entry: SettingsSearchIndex.Entry

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(entry.location).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            SettingsChevron()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The search field at the top of the category list.
struct SettingsSearchField: View {
    @Binding var text: String
    var prompt = "Search settings"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Palette.textTertiary))
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .accessibilityIdentifier("settings.search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 1))
                .accessibilityLabel("Clear search")
            }
        }
        .font(SettingsMetrics.rowFont)
        .padding(.horizontal, 10)
        #if os(macOS)
        .frame(height: 30)
        #else
        .frame(height: 40)
        #endif
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Color.white.opacity(0.35) : Palette.edge))
    }
}

enum ByteText {
    /// Settings' one word for nothing stored or counted, on every page.
    static let zero = "None"

    /// A size on disk, or "None".
    static func string(_ bytes: Int64) -> String {
        bytes <= 0 ? zero : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Languages offered for audio and subtitles, as ISO 639-1 codes.
enum SettingsLanguages {
    static let codes = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "hu", "ro", "el",
                        "ru", "uk", "tr", "ar", "he", "hi", "th", "vi", "id", "ja", "ko", "zh"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Sorted by display name, so the menu reads alphabetically in any locale.
    static var sorted: [String] { codes.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending } }

    /// The languages as picker options, for a `String?` selection.
    static var options: [BlueboxPickerOption<String?>] { sorted.map { .init(name($0), value: $0) } }
}

extension String {
    var capitalizedSentence: String {
        let spaced = replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }
}
