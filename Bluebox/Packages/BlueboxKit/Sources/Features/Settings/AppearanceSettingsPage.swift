import CoreImage
import DesignSystem
import Domain
import os
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Appearance

/// Settings › Appearance: the theme colour, which recolours the accent
/// everywhere (selection, progress, links), the wordmark, and the app icon.
/// The app's language is on Settings › Language.
struct AppearanceSettingsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var theme = ThemeStore.shared
        SettingsForm(.appearance) {
            ThemePreview(accent: theme.accent)
        } content: {
            Section {
                ThemeSwatches(selection: Binding {
                    theme.accent
                } set: { accent in
                    withAnimation(Motion.standard(reduceMotion)) { theme.accent = accent }
                    ThemeIcon.apply(accent)
                })
                .padding(.vertical, Spacing.s)
                .settingsRow("Theme Colour")
            } header: {
                Text("Theme Colour")
            } footer: {
                #if os(macOS)
                Text("Colours highlights, progress, the Bluebox logo and the Dock icon. Finder keeps showing the blue icon.")
                #else
                Text("Colours highlights, progress, the Bluebox logo and the app icon on your Home Screen.")
                #endif
            }
            Section {
                SettingsPageLink("Language", page: .languages, value: AppLanguage.current.title)
            } footer: {
                Text("The app's language, and the audio and subtitle languages you prefer.")
            }
        }
    }
}

/// The app icon and wordmark in the chosen colour, with a few of the
/// controls the accent appears on.
private struct ThemePreview: View {
    let accent: ThemeAccent

    var body: some View {
        HStack(spacing: Spacing.xl) {
            Image("ThemeIcon-\(accent.rawValue.capitalized)", bundle: .main)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.edge))
                .shadow(color: accent.brand.opacity(0.35), radius: 14, y: 4)
                .id(accent)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.m) {
                BlueboxWordmark(size: 26)
                HStack(spacing: Spacing.s) {
                    Capsule().fill(Palette.elevated).frame(width: 120, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(Palette.brand).frame(width: 78, height: 4) }
                    Text("New").font(.caption2.weight(.heavy)).textCase(.uppercase)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.brand, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brandBright)
                }
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .background(
            RadialGradient(colors: [accent.deep.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 320),
            in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(Palette.edge))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview in \(accent.title)")
    }
}

/// The colours as round swatches, the chosen one ringed and ticked.
private struct ThemeSwatches: View {
    @Binding var selection: ThemeAccent

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Spacing.s)], alignment: .leading, spacing: Spacing.m) {
            ForEach(ThemeAccent.allCases) { accent in
                Swatch(accent: accent, selected: accent == selection) { selection = accent }
            }
        }
    }

    private struct Swatch: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let accent: ThemeAccent
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [accent.bright, accent.deep], startPoint: .top, endPoint: .bottom))
                            .frame(width: 34, height: 34)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                            .scaleEffect(selected ? 1 : 0.4)
                            .opacity(selected ? 1 : 0)
                    }
                    .padding(4)
                    .overlay(Circle().strokeBorder(selected ? accent.bright : hovering ? Palette.separator : .clear, lineWidth: 2))
                    .scaleEffect(hovering && !selected ? 1.06 : 1)
                    Text(ui: accent.title)
                        .font(.caption)
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(minWidth: 64, minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.snappy(reduceMotion), value: selected)
            .accessibilityLabel(Text(ui: accent.title))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: - App icon

/// Puts the app icon in the theme colour. Mac: the Dock icon, redrawn from the
/// blue one at launch and on each change. iPhone and iPad: the alternate
/// icons in the asset catalog (tools/make-theme-icons.swift); iOS says so
/// with its own alert.
@MainActor
public enum ThemeIcon {
    public static func apply(_ accent: ThemeAccent) {
        #if os(macOS)
        NSApp.applicationIconImage = accent == .blue ? nil : tintedDockIcon(accent)
        #else
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != accent.alternateIconName else { return }
        app.setAlternateIconName(accent.alternateIconName) { error in
            if let error { Logger(subsystem: Log.subsystem, category: "appearance").error("Couldn't change the app icon: \(error.localizedDescription, privacy: .public)") }
        }
        #endif
    }

    /// At launch (Mac): the Dock shows the bundle's blue icon until told otherwise.
    public static func applyAtLaunch() {
        #if os(macOS)
        let accent = ThemeStore.shared.accent
        if accent != .blue { apply(accent) }
        #endif
    }

    #if os(macOS)
    private static func tintedDockIcon(_ accent: ThemeAccent) -> NSImage? {
        guard let icon = NSImage(named: NSImage.applicationIconName),
              let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var image = CIImage(cgImage: cg)
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: accent.iconHueRotation * .pi / 180])
        if accent.iconSaturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: accent.iconSaturation])
        }
        guard let out = CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        else { return nil }
        return NSImage(cgImage: out, size: icon.size)
    }
    #endif
}

// MARK: - App language

/// The language Bluebox's own words are in. "Same as System" follows the
/// device. A change takes effect when Bluebox next opens: the choice is
/// written to the app's `AppleLanguages`, which Foundation reads at launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt-BR"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language in its own words, so it can be found whatever the app is in.
    var title: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português (Brasil)"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chinese: "简体中文"
        }
    }

    static let key = "bluebox.appLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The language the app opened in (what's on screen now).
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Saves the choice for the next launch.
    static func choose(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: key)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Whether what's on screen already matches the choice.
    static var isApplied: Bool {
        let chosen = current
        guard chosen != .system else { return true }
        return running.lowercased().hasPrefix(chosen.rawValue.lowercased().prefix(2))
    }
}

/// Settings › Language › App Language. Choosing one asks straight away
/// whether to relaunch (Mac) or says when it takes effect (iPhone, iPad);
/// "Later" leaves the button below for when it suits.
struct AppLanguageSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice = AppLanguage.current
    @State private var pending = !AppLanguage.isApplied
    @State private var asking = false

    var body: some View {
        Section {
            SettingsPicker("App Language", selection: Binding {
                choice
            } set: { new in
                guard new != choice else { return }
                choice = new
                AppLanguage.choose(new)
                withAnimation(Motion.standard(reduceMotion)) { pending = !AppLanguage.isApplied }
                asking = pending
            }, options: AppLanguage.allCases.map { .init($0.title, value: $0) })
                .settingsRow("App Language")
                .alert(Self.askTitle(choice), isPresented: $asking) {
                    #if os(macOS)
                    Button("Relaunch", action: Self.relaunch)
                    Button("Later", role: .cancel) {}
                    #else
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Button("OK", role: .cancel) {}
                    #endif
                } message: {
                    #if os(macOS)
                    Text("Downloads and what's playing are saved first.")
                    #else
                    Text("Bluebox switches language the next time it opens. iOS can also set it, under Bluebox › Language.")
                    #endif
                }
            if pending {
                #if os(macOS)
                Button("Relaunch Bluebox Now", action: Self.relaunch)
                #else
                Button("Open Language in iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            }
        } header: {
            SettingsScopeHeader("Bluebox", scope: .everyone)
        } footer: {
            if pending {
                #if os(macOS)
                Text("Bluebox switches language when it next opens. Downloads pick up where they left off.")
                #else
                Text("Bluebox switches language the next time it opens. iOS can also set it, under Bluebox › Language.")
                #endif
            } else {
                Text("Menus, buttons and messages. Titles and descriptions come from the catalog, in its language.")
            }
        }
    }

    /// "Relaunch Bluebox in Français?" (Mac), "Français next time Bluebox opens" (iOS).
    private static func askTitle(_ language: AppLanguage) -> String {
        let name = language == .system ? String(localized: "your system's language") : language.title
        #if os(macOS)
        return String(localized: "Relaunch Bluebox in \(name)?")
        #else
        return String(localized: "\(name) next time Bluebox opens")
        #endif
    }

    #if os(macOS)
    /// Opens a new copy once this one has quit (it saves first, see AppDelegate).
    private static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to exit, then opens the app again.
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundle.path)\""]
        do {
            try task.run()
        } catch {
            // Couldn't start the helper: open a second copy now; this one quits right after.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: config)
        }
        NSApp.terminate(nil)
    }
    #endif
}
