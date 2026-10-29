import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A slider in Bluebox blue. iOS honours `.tint`; macOS draws AppKit's slider
/// in the system accent whatever the tint, so there it's drawn here: a grey
/// track, a blue fill and a white knob, with arrow keys and VoiceOver
/// adjusting it like the system one.
struct BrandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?

    var body: some View {
        #if os(macOS)
        MacBrandSlider(value: $value, range: range, step: step)
        #else
        Group {
            if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
        }
        .tint(Palette.brand)
        #endif
    }
}

#if os(macOS)
private struct MacBrandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    @State private var dragging = false
    @FocusState private var focused: Bool

    private let knob: CGFloat = 18
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            let x = CGFloat(fraction) * usable
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.elevated).frame(height: track)
                Capsule().fill(Palette.brand).frame(width: x + knob / 2, height: track)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(focused ? Palette.brand : .clear, lineWidth: 2))
                    .scaleEffect(dragging ? 1.1 : 1)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    set(fraction: Double((g.location.x - knob / 2) / usable))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: Double { span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0 }

    private func set(fraction f: Double) {
        var v = range.lowerBound + min(max(f, 0), 1) * span
        if let step, step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double) {
        let amount = step ?? span / 20
        value = min(max(value + direction * amount, range.lowerBound), range.upperBound)
    }
}
#endif

/// The "custom colour" swatch. On macOS the system colour well rings itself in
/// the system accent; this is a plain swatch that opens the colour panel.
struct BrandColorWell: View {
    let title: String
    @Binding var color: Color
    var supportsOpacity = true

    var body: some View {
        #if os(macOS)
        MacColorWell(title: title, color: $color, supportsOpacity: supportsOpacity)
        #else
        ColorPicker(title, selection: $color, supportsOpacity: supportsOpacity).labelsHidden()
        #endif
    }
}

#if os(macOS)
private struct MacColorWell: View {
    let title: String
    @Binding var color: Color
    let supportsOpacity: Bool
    @State private var panel = ColorPanelLink()
    @State private var hovering = false

    var body: some View {
        Button {
            panel.open(color: color, supportsOpacity: supportsOpacity) { color = $0 }
        } label: {
            ZStack {
                // Checks under the colour show its opacity.
                Image(systemName: "checkerboard.rectangle").resizable().foregroundStyle(.white.opacity(0.25))
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color)
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(panel.isOpen ? Palette.brand : (hovering ? Palette.textSecondary : Palette.edge),
                              lineWidth: panel.isOpen ? 2 : 1))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .onDisappear { panel.detach() }
        .help("Choose a colour")
        .accessibilityLabel("\(title), custom colour")
    }
}

/// Points the shared colour panel at one swatch while it's open.
@Observable
@MainActor
private final class ColorPanelLink: NSObject {
    private(set) var isOpen = false
    @ObservationIgnored private var onChange: ((Color) -> Void)?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    func open(color: Color, supportsOpacity: Bool, onChange: @escaping (Color) -> Void) {
        let panel = NSColorPanel.shared
        if let previous = Self.owner, previous !== self { previous.isOpen = false; previous.onChange = nil }
        Self.owner = self
        self.onChange = nil  // setting the colour below shouldn't echo back
        panel.showsAlpha = supportsOpacity
        panel.color = NSColor(color)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        isOpen = true
        panel.orderFront(nil)
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            }
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }

    func detach() {
        isOpen = false
        onChange = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if Self.owner === self {
            Self.owner = nil
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
    }

    /// The swatch the shared panel reports to (one at a time).
    private static weak var owner: ColorPanelLink?
}
#endif
