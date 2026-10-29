import DesignSystem
import Subtitles
import SwiftUI

/// Places primary (and optional secondary) subtitles over the visible video.
///
/// The text can be moved anywhere on the picture by dragging it (finger or
/// mouse); it snaps to the centre line and to the usual distance from the top
/// or bottom. Pinching it resizes. Both are saved in the subtitle style when
/// the gesture ends, so the overlay doesn't write preferences every frame.
struct SubtitleOverlay: View {
    let primary: String?
    let secondary: String?
    @Binding var style: SubtitleStyle
    /// The visible picture, in the overlay's coordinates.
    let videoRect: CGRect
    let controlsVisible: Bool
    /// How far bottom subtitles move up while the controls show.
    var controlsInset: CGFloat = 100
    /// False for previews: no gestures.
    var editable = true
    /// Drawn when there's no line on screen, so style changes show live.
    var placeholder: String?
    /// Called with true when a drag or pinch on the text starts, false when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var pinch: Double = 1
    @State private var pinching = false
    @State private var blockSize: CGSize = .zero
    @State private var candidate: SubtitlePlacement?
    @State private var showsReset = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let w = Double(max(videoRect.width, 1)), h = Double(max(videoRect.height, 1))
        var shown = style
        shown.relativeSize = SubtitleStyle.clampSize(style.relativeSize * pinch)
        let primaryLine = primary ?? (secondary == nil ? placeholder : nil)
        let restMargin = restingMargin(h: h)
        let offset = blockOffset(w: w, h: h)

        return ZStack(alignment: Alignment(horizontal: horizontal(style.alignment), vertical: style.anchor == .bottom ? .bottom : .top)) {
            Color.clear
            if dragging || pinching { guides(w: w, h: h) }
            if primaryLine != nil || secondary != nil {
                // The padded ZStack proposes the width between the side margins;
                // the block hugs its text, so it can be dragged sideways.
                block(primary: primaryLine, style: shown, h: h)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { blockSize = $0 }
                    .overlay {
                        if dragging || pinching {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .padding(-6)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: style.anchor == .bottom ? .top : .bottom) {
                        if showsReset, !dragging, !style.isDefaultPosition { resetButton(above: style.anchor == .bottom) }
                    }
                    .contentShape(Rectangle().inset(by: -8))
                    .gesture(dragGesture(w: w, h: h), including: editable ? .all : .subviews)
                    .simultaneousGesture(pinchGesture, including: editable ? .all : .subviews)
                    #if os(macOS)
                    .pointerStyle(editable ? (dragging ? .grabActive : .grabIdle) : nil)
                    #endif
                    .offset(x: offset.width, y: (style.anchor == .bottom ? -restMargin : restMargin) + offset.height)
                    .animation(dragging ? nil : .easeOut(duration: 0.2), value: restMargin)
                    .accessibilityAction(named: "Reset Subtitle Position") { commitReset() }
            }
        }
        .padding(.horizontal, style.horizontalMargin * w)
        .frame(width: videoRect.width, height: videoRect.height)
        .position(x: videoRect.midX, y: videoRect.midY)
        .selectionHaptic(candidate?.snappedX == true)
        .selectionHaptic(candidate?.snappedY == true)
    }

    private func block(primary: String?, style: SubtitleStyle, h: Double) -> some View {
        VStack(alignment: horizontal(style.alignment), spacing: style.pointSize(forHeight: h) * 0.25) {
            // Secondary sits on the far side from the edge, so the main line stays where the eye expects it.
            if style.anchor == .bottom {
                if let secondary { SubtitleText(text: secondary, style: style, videoHeight: h, secondary: true) }
                if let primary { SubtitleText(text: primary, style: style, videoHeight: h) }
            } else {
                if let primary { SubtitleText(text: primary, style: style, videoHeight: h) }
                if let secondary { SubtitleText(text: secondary, style: style, videoHeight: h, secondary: true) }
            }
        }
    }

    // MARK: Geometry

    /// Distance from the anchored edge in points. Bottom subtitles near the edge
    /// move up while the controls show; ones placed higher stay put.
    private func restingMargin(h: Double) -> Double {
        let m = style.verticalMargin * h
        let bump = style.anchor == .bottom && style.avoidControls && controlsVisible ? Double(controlsInset) : 0
        return m < bump ? m + bump : m
    }

    /// The block's offset from its aligned spot: the saved sideways shift
    /// (kept on the picture), plus the live drag, snapped.
    private func blockOffset(w: Double, h: Double) -> CGSize {
        let bw = Double(blockSize.width) / w
        let saved = SubtitlePlacement.clampedOffset(style.horizontalOffset, blockWidth: bw, alignment: style.alignment,
                                                    horizontalMargin: style.horizontalMargin) * w
        guard dragging, let candidate else { return CGSize(width: saved, height: 0) }
        // Where the snapped drop would put the block, relative to where it rests now.
        let rest = restingRect(w: w, h: h)
        let target = rect(for: candidate, w: w, h: h)
        return CGSize(width: saved + (target.minX - rest.minX) * w, height: (target.minY - rest.minY) * h)
    }

    /// The block's frame at rest, in unit coordinates.
    private func restingRect(w: Double, h: Double) -> CGRect {
        let bw = Double(blockSize.width) / w, bh = Double(blockSize.height) / h
        let offset = SubtitlePlacement.clampedOffset(style.horizontalOffset, blockWidth: bw, alignment: style.alignment,
                                                     horizontalMargin: style.horizontalMargin)
        let midX = SubtitlePlacement.restingMidX(blockWidth: bw, alignment: style.alignment, horizontalMargin: style.horizontalMargin) + offset
        let m = restingMargin(h: h) / h
        let minY = style.anchor == .bottom ? 1 - m - bh : m
        return CGRect(x: midX - bw / 2, y: minY, width: bw, height: bh)
    }

    /// The block's frame for a placement, in unit coordinates (controls ignored:
    /// a drop is where the user let go).
    private func rect(for p: SubtitlePlacement, w: Double, h: Double) -> CGRect {
        let bw = Double(blockSize.width) / w, bh = Double(blockSize.height) / h
        let midX = SubtitlePlacement.restingMidX(blockWidth: bw, alignment: style.alignment, horizontalMargin: style.horizontalMargin) + p.horizontalOffset
        let minY = p.anchor == .bottom ? 1 - p.verticalMargin - bh : p.verticalMargin
        return CGRect(x: midX - bw / 2, y: minY, width: bw, height: bh)
    }

    // MARK: Gestures

    private func dragGesture(w: Double, h: Double) -> some Gesture {
        // Global space: the block moves under the finger, so a local translation
        // would shrink as it moves and the text would trail at half speed.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                if !dragging { begin(); dragging = true }
                let rest = restingRect(w: w, h: h)
                let moved = rest.offsetBy(dx: v.translation.width / w, dy: v.translation.height / h)
                candidate = SubtitlePlacement.dropping(block: moved, alignment: style.alignment, horizontalMargin: style.horizontalMargin)
            }
            .onEnded { _ in
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) {
                    if let candidate { style.place(candidate) }
                    candidate = nil
                    dragging = false
                }
                end()
                flashReset()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if !pinching { begin(); pinching = true }
                pinch = v.magnification
            }
            .onEnded { _ in
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) {
                    style.relativeSize = SubtitleStyle.clampSize(style.relativeSize * pinch)
                    pinch = 1
                    pinching = false
                }
                end()
            }
    }

    private func begin() {
        resetTask?.cancel()
        showsReset = false
        onEditingChanged(true)
    }

    private func end() {
        if !dragging && !pinching { onEditingChanged(false) }
    }

    private func flashReset() {
        resetTask?.cancel()
        guard !style.isDefaultPosition else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsReset = true }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { showsReset = false }
        }
    }

    private func commitReset() {
        withAnimation(Motion.standard(reduceMotion)) { style.resetPosition() }
        showsReset = false
    }

    private func resetButton(above: Bool) -> some View {
        Button(action: commitReset) {
            Label("Reset Position", systemImage: "arrow.uturn.backward")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                .foregroundStyle(.white)
        }
        .buttonStyle(PressableStyle())
        .fixedSize()
        .offset(y: above ? -36 : 36)
        .transition(.opacity)
    }

    /// Snap lines: the centre line and the usual distance from the edge.
    private func guides(w: Double, h: Double) -> some View {
        let snapX = candidate?.snappedX == true, snapY = candidate?.snappedY == true
        let edgeY = candidate?.anchor == .top ? SubtitleStyle.defaultMargin * h : h - SubtitleStyle.defaultMargin * h
        return Canvas { ctx, size in
            var centre = Path(); centre.move(to: CGPoint(x: w / 2, y: 0)); centre.addLine(to: CGPoint(x: w / 2, y: h))
            var edge = Path(); edge.move(to: CGPoint(x: 0, y: edgeY)); edge.addLine(to: CGPoint(x: w, y: edgeY))
            let dash = StrokeStyle(lineWidth: 1, dash: [6, 6])
            ctx.stroke(centre, with: .color(snapX ? Palette.brandBright : .white.opacity(0.25)), style: dash)
            ctx.stroke(edge, with: .color(snapY ? Palette.brandBright : .white.opacity(0.25)), style: dash)
        }
        .frame(width: w, height: h)
        .padding(.horizontal, -style.horizontalMargin * w)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func horizontal(_ a: SubtitleStyle.Alignment) -> HorizontalAlignment {
        switch a { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}
