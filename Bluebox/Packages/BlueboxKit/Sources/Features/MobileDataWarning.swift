import DesignSystem
import SwiftUI

extension View {
    /// Presents "You're on mobile data" when Play asks first (Settings › Mobile
    /// Data › Streaming: Ask First). Put it once on the app's root view.
    public func mobileDataPlayWarning() -> some View { modifier(MobileDataWarningHost()) }
}

struct MobileDataWarningHost: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { app.settings.mobileDataPrompt },
                                    set: { if $0 == nil, app.settings.mobileDataPrompt != nil { app.answerMobileDataPrompt(.cancel) } })) { prompt in
            MobileDataWarningSheet(prompt: prompt)
                .environment(app)
        }
        #if DEBUG
        .task {
            // Screenshots: `-preview-mobile-data-sheet` shows the sheet without a cellular connection.
            guard ProcessInfo.processInfo.arguments.contains("-preview-mobile-data-sheet") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            app.settings.mobileDataPrompt = MobileDataPrompt(
                title: "Harbor Lights", subtitle: "S2·E3", quality: "1080p", bytes: 1_180_000_000,
                dataSaverQuality: "720p", dataSaverBytes: 520_000_000, minutes: 52, canDownload: true)
        }
        #endif
    }
}

/// The sheet: what's about to play, its quality and roughly how much data it
/// takes, then Play / Play in Data Saver / Download on Wi‑Fi Later. Cancel is
/// the close button and dragging the sheet away; "Don't ask again" is a switch.
/// The sheet is as tall as its content (scrolling at large text sizes).
struct MobileDataWarningSheet: View {
    @Environment(AppModel.self) private var app
    let prompt: MobileDataPrompt
    @State private var dontAskAgain = false
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.height(contentHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.surface)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityHidden(true)
                Spacer(minLength: Spacing.m)
                Button { answer(.cancel) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.elevated))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, -Spacing.s)
                .padding(.trailing, -Spacing.s)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("mobileData.cancel")
            }
            .padding(.bottom, Spacing.s)

            Text("You're on mobile data")
                .font(.title2.weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s)
                .accessibilityAddTraits(.isHeader)
            Text(prompt.subtitle.map { "\(prompt.title) · \($0)" } ?? prompt.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.estimate(quality: prompt.quality, bytes: prompt.bytes, minutes: prompt.minutes))
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, Spacing.xl)

            VStack(spacing: Spacing.s) {
                Button { answer(.play) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(SheetButtonStyle(prominent: true))
                .accessibilityIdentifier("mobileData.play")

                if showsDataSaver {
                    Button { answer(.playInDataSaver) } label: {
                        VStack(spacing: 1) {
                            Text("Play in Data Saver")
                            if let saver = dataSaverDetail {
                                Text(saver).font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SheetButtonStyle(prominent: false))
                }

                if prompt.canDownload {
                    Button { answer(.downloadLater) } label: {
                        Label("Download on Wi‑Fi Later", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SheetButtonStyle(prominent: false))
                }
            }

            Toggle("Don't ask again this session", isOn: $dontAskAgain)
                .font(.subheadline)
                .toggleStyle(SettingsSwitchStyle())
                .frame(minHeight: 44)
                .padding(.top, Spacing.m)
                .accessibilityIdentifier("mobileData.dontAskAgain")
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    /// Pointless when mobile data already plays in Data Saver.
    private var showsDataSaver: Bool { app.settings.mobileData.quality != .dataSaver }

    private var dataSaverDetail: String? {
        guard prompt.dataSaverBytes != nil || prompt.dataSaverQuality != nil else { return "Up to 720p, smallest file" }
        return Self.estimate(quality: prompt.dataSaverQuality, bytes: prompt.dataSaverBytes, minutes: prompt.minutes)
    }

    private func answer(_ choice: MobileDataChoice) {
        app.answerMobileDataPrompt(choice, dontAskAgain: dontAskAgain)
    }

    /// "1080p · about 1.1 GB for 52 min".
    static func estimate(quality: String?, bytes: Int64?, minutes: Int?) -> String {
        var parts: [String] = []
        if let quality { parts.append(quality == "2160p" ? "4K" : quality) }
        if let bytes, bytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            parts.append(minutes.map { "about \(size) for \($0) min" } ?? "about \(size)")
        } else {
            parts.append("Size unknown")
        }
        return parts.joined(separator: " · ")
    }
}

/// Play is white with black text; the others solid raised grey.
private struct SheetButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(prominent ? Color.black : Palette.textPrimary)
            .padding(.vertical, 10)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Color.white : Palette.elevated))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
