import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The account screens' look: Netflix's sign-in and Account pages on Bluebox's
/// OLED-black palette. Greys and text come from `Palette`; blue is only for
/// links and focus.
enum AccountTheme {
    /// Input fill: the raised grey surface.
    static var fieldFill: Color { Palette.elevated }
    static let fieldBorder = Color.white.opacity(0.22)
    static let fieldBorderFocused = Color.white
    static let error = Color(red: 0.92, green: 0.24, blue: 0.27)
    static let cardFill = Color.black.opacity(0.78)
    static let cardRadius: CGFloat = 8
    static let fieldRadius: CGFloat = 6
    static let fieldHeight: CGFloat = 56
    static let buttonHeight: CGFloat = 50
    static let cardMaxWidth: CGFloat = 440
    static let listMaxWidth: CGFloat = 680
}

// MARK: - Page chrome

/// Full-bleed dark backdrop with the wordmark top-left and the content centred.
struct AccountScreen<Content: View>: View {
    /// A card (sign-in, connect) or a plain column (the Account page).
    var card = true
    @ViewBuilder let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var scrolled = false

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BlueboxWordmark(size: compact ? 26 : 30)
                    .padding(.bottom, compact ? Spacing.xl : Spacing.xxl)
                Group {
                    if card {
                        VStack(alignment: .leading, spacing: 0) { content }
                            .padding(.horizontal, compact ? 0 : 44)
                            .padding(.vertical, compact ? 0 : 40)
                            .frame(maxWidth: compact ? .infinity : AccountTheme.cardMaxWidth + 88, alignment: .leading)
                            .background {
                                if !compact {
                                    RoundedRectangle(cornerRadius: AccountTheme.cardRadius, style: .continuous)
                                        .fill(AccountTheme.cardFill)
                                        .overlay(RoundedRectangle(cornerRadius: AccountTheme.cardRadius, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.07)))
                                }
                            }
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 0) { content }
                            .frame(maxWidth: AccountTheme.listMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, compact ? 24 : 40)
            .padding(.top, Spacing.l)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollDismissesKeyboard(.interactively)
        #if DEBUG
        // Screenshots: `-account-scroll-bottom` opens the page scrolled to the end.
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-account-scroll-bottom") ? .bottom : nil)
        #endif
        .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top > 4 } action: { _, now in
            scrolled = now
        }
        .background { AccountBackdrop().ignoresSafeArea() }
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.brand)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Clear over the backdrop at the top; solid black once the page scrolls,
        // so the steps don't run under the close button and the clock.
        .toolbarBackground(Palette.background, for: .navigationBar)
        .toolbarBackgroundVisibility(scrolled ? .visible : .hidden, for: .navigationBar)
        #endif
    }
}

/// Black, with a faint blue light from the top so the card has something to sit on.
struct AccountBackdrop: View {
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(colors: [Palette.brand.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 520)
            LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
        }
    }
}

/// A big bold title and an optional grey line under it.
struct AccountTitle: View {
    let title: String
    var subtitle: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ui: title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Spacing.xl)
    }
}

// MARK: - Inputs

/// A tall input with a label that floats up when focused or filled, a 1 pt
/// border that turns white on focus, and red error text underneath.
struct FloatingField<Trailing: View>: View {
    let label: String
    @Binding var text: String
    var secure = false
    var error: String?
    var contentType: TextContentTypeValue = .none
    var submitLabel: SubmitLabel = .done
    var onSubmit: () -> Void = {}
    /// Lets the form move focus here (Return in the field above).
    var isFocused: Binding<Bool>? = nil
    @ViewBuilder var trailing: Trailing

    @FocusState private var focused: Bool

    enum TextContentTypeValue { case none, email, url, username, password }

    private var floating: Bool { focused || !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                ZStack(alignment: .leading) {
                    Text(ui: label)
                        .font(floating ? .caption.weight(.medium) : .body)
                        .foregroundStyle(Palette.textSecondary)
                        .offset(y: floating ? -12 : 0)
                        .accessibilityHidden(true)
                    input
                        .font(.body)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(submitLabel)
                        .onSubmit(onSubmit)
                        .padding(.top, floating ? 16 : 0)
                        .opacity(floating ? 1 : 0.02)
                        .accessibilityLabel(label)
                }
                // A tap anywhere on the box (but not on the trailing buttons) focuses the field.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                trailing
            }
            .padding(.horizontal, Spacing.l)
            .frame(height: AccountTheme.fieldHeight)
            .background(AccountTheme.fieldFill, in: RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous)
                    .strokeBorder(error != nil ? AccountTheme.error : focused ? AccountTheme.fieldBorderFocused : AccountTheme.fieldBorder,
                                  lineWidth: focused || error != nil ? 1.5 : 1)
            }
            .animation(.snappy(duration: 0.18), value: floating)
            .animation(.snappy(duration: 0.18), value: focused)

            if let error { AccountErrorText(text: error) }
        }
        .onChange(of: isFocused?.wrappedValue ?? false) { _, want in if want != focused { focused = want } }
        .onChange(of: focused) { _, now in if let isFocused, isFocused.wrappedValue != now { isFocused.wrappedValue = now } }
    }

    @ViewBuilder private var input: some View {
        if secure {
            SecureField("", text: $text)
                .textContentType(contentType == .password ? .password : nil)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            switch contentType {
            case .username:
                TextField("", text: $text)
                    .textContentType(.username)
                    #if os(iOS)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    #endif
            case .password:
                TextField("", text: $text)
                    .textContentType(.password)
                    #if os(iOS)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    #endif
            case .email:
                TextField("", text: $text)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
            case .url:
                TextField("", text: $text)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            case .none:
                TextField("", text: $text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        }
    }
}

extension FloatingField where Trailing == EmptyView {
    init(_ label: String, text: Binding<String>, secure: Bool = false, error: String? = nil,
         contentType: TextContentTypeValue = .none, submitLabel: SubmitLabel = .done, isFocused: Binding<Bool>? = nil,
         onSubmit: @escaping () -> Void = {}) {
        self.init(label: label, text: text, secure: secure, error: error, contentType: contentType,
                  submitLabel: submitLabel, onSubmit: onSubmit, isFocused: isFocused) { EmptyView() }
    }
}

/// The eye button that shows or hides a secret field's text.
struct RevealButton: View {
    @Binding var revealed: Bool
    var noun = "Password"

    var body: some View {
        Button { revealed.toggle() } label: {
            Image(systemName: revealed ? "eye.slash" : "eye")
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(revealed ? "Hide \(noun)" : "Show \(noun)")
    }
}

/// The system paste button (no "Allow Paste?" prompt), small, as a field's trailing control.
struct FieldPasteButton: View {
    let set: @MainActor (String) -> Void

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in set(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.capsule)
        .tint(Color.white.opacity(0.14))
        .controlSize(.small)
        .fixedSize()
    }
}

/// Red error text with an icon, under a field or a button.
struct AccountErrorText: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.circle").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.footnote)
        .foregroundStyle(AccountTheme.error)
        .accessibilityElement(children: .combine)
    }
}

/// Small grey helper text, or a positive check in the same size.
struct AccountHelperText: View {
    let text: String
    var ok = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if ok { Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Palette.textSecondary)
    }
}

// MARK: - Buttons

/// Full-width solid primary button: white with black bold text, like Play.
struct AccountPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PrimaryBody(configuration: configuration) }

    private struct PrimaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: AccountTheme.buttonHeight)
                .background(isEnabled ? Color.white.opacity(configuration.isPressed ? 0.8 : 1) : Palette.elevated,
                            in: RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous))
                .foregroundStyle(isEnabled ? Color.black : Palette.textTertiary)
                .contentShape(RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous))
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// The primary button with a spinner while it works.
struct AccountPrimaryButton: View {
    let title: String
    let workingTitle: String
    let working: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if working { ProgressView().controlSize(.small).tint(.black) }
                Text(working ? workingTitle : title)
            }
        }
        .buttonStyle(AccountPrimaryButtonStyle())
        .disabled(disabled || working)
        .keyboardShortcut(.defaultAction)
    }
}

/// A plain text button: white and semibold, or blue for links out of the app.
struct AccountTextButton: View {
    let title: String
    var systemImage: String?
    var link = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, link: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.link = link; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(ui: title)
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(link ? Palette.brand : Palette.textPrimary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }
}

/// "Open in Supabase ↗": a blue link to a dashboard page.
struct DashboardLink: View {
    let title: String
    let url: URL
    @Environment(\.openURL) private var openURL

    init(_ title: String, _ url: URL) { self.title = title; self.url = url }

    var body: some View {
        AccountTextButton(title, systemImage: "arrow.up.right", link: true) { openURL(url) }
            .help(url.absoluteString)
    }
}

/// A text button that copies, and says "Copied" for a moment.
struct CopyButton: View {
    let title: String
    let text: () -> String
    @State private var copied = false

    init(_ title: String, text: @autoclosure @escaping () -> String) { self.title = title; self.text = text }

    var body: some View {
        AccountTextButton(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc", link: true) {
            Clipboard.copy(text())
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
        }
    }
}

// MARK: - Account page rows

/// Plain grey section header, Netflix Account style.
struct AccountSectionHeader: View {
    let title: String
    var body: some View {
        Text(ui: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.textSecondary)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A full-width hairline.
struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.separator).frame(height: 1).accessibilityHidden(true) }
}

/// A row: title, optional detail under it, value on the right.
struct AccountInfoRow<Value: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui: title).font(.body)
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.m)
                value.font(.body).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, Spacing.l)
            Hairline()
        }
        .accessibilityElement(children: .combine)
    }
}

extension AccountInfoRow where Value == EmptyView {
    init(_ title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// A tappable row with a right-aligned chevron.
struct AccountActionRow: View {
    let title: String
    var detail: String?
    var destructive = false
    var working = false
    var external = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui: title).font(.body).foregroundStyle(destructive ? AccountTheme.error : Palette.textPrimary)
                        if let detail {
                            Text(detail).font(.subheadline).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Spacing.m)
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: external ? "arrow.up.right" : "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, Spacing.l)
                .padding(.horizontal, Spacing.s)
                .background(hovering ? Color.white.opacity(0.05) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, -Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(working)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            Hairline()
        }
    }
}

// MARK: - Clipboard

enum Clipboard {
    @MainActor static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
