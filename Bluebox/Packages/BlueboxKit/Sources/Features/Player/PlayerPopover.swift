import DesignSystem
import SwiftUI

/// Panels that float over the video above the tool row: Audio & Subtitles
/// and Episodes. A solid surface (the OLED finish has no glass), concentric
/// row highlights, 44 pt rows on touch and compact rows on the Mac.
enum PlayerPopoverMetrics {
    static let radius: CGFloat = 12
    static let inset: CGFloat = 6
    /// Concentric with the card: 12 − 6.
    static var rowRadius: CGFloat { radius - inset }
    #if os(macOS)
    static let rowHeight: CGFloat = 28
    static let rowFont = Font.body
    #else
    static let rowHeight: CGFloat = 44
    static let rowFont = Font.body
    #endif
}

extension View {
    func playerPopoverSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: PlayerPopoverMetrics.radius, style: .continuous)
        return self
            .background(shape.fill(Palette.surface))
            .overlay(shape.strokeBorder(Palette.edge))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
            .environment(\.colorScheme, .dark)
    }
}

/// Rows highlight on hover (Mac) and press (both).
struct PopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PopoverRow(configuration: configuration)
    }

    private struct PopoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.06 : 0))
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct PlayerPopoverCloseButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: Circle())
                .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A footer action: symbol and title, quiet until hovered or pressed.
struct PopoverFooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: PanelMetrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowStyle())
        .foregroundStyle(Palette.textPrimary)
    }
}
