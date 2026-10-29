import DesignSystem
import SwiftUI

/// Timeline with buffered range, A–B loop marks and drag-to-scrub.
///
/// Positions are never animated: the thumb and the time bubble follow the
/// finger or pointer 1:1, and playback ticks move them without easing. Only
/// the grab affordance (the track thickening, the thumb growing, the bubble
/// fading) animates, scoped so it can't drag the position along with it.
///
/// While dragging, `onScrub` gets every position (the engine throttles and
/// chases); on release `onCommit` seeks exactly. Until playback reports the
/// new time, the thumb stays where it was dropped instead of jumping back.
struct Scrubber: View {
    let fraction: Double
    let buffered: Double
    let duration: TimeInterval
    /// What's downloaded of a streamed torrent, as fractions of the file (gaps
    /// and all). Drawn lighter than played; empty for other sources.
    var available: [ClosedRange<Double>] = []
    /// Loop start and end as fractions.
    var loop: (Double, Double?)?
    /// Where chapters begin, as fractions: drawn as gaps in the track.
    var chapterMarks: [Double] = []
    /// Waiting for data: the buffered end glows, so you see where it's filling.
    var stalled = false
    @Binding var scrubFraction: Double?
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    /// Preview frames above the bubble, when the video can provide them.
    var thumbnails: ScrubThumbnailer?
    /// The bubble (and its frame) is showing: dragging or hovering. Lets the
    /// player move other things out of the way (the Skip pill).
    var onPreviewing: ((Bool) -> Void)?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var hoverFraction: Double?
    @State private var scrubTick = 0
    /// Where the thumb was released, held until playback catches up.
    @State private var committed: Double?

    private static let thumbSize: CGFloat = 15
    private static let activeThumbSize: CGFloat = 22
    /// Wide enough for "0:20 / 0:52", or "1:02:20 / 2:10:52" for long films.
    private var bubbleWidth: CGFloat { duration >= 3600 ? 148 : duration >= 600 ? 116 : 104 }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let shown = clamp(scrubFraction ?? committed ?? fraction)
            let active = scrubFraction != nil
            let bubbleFraction = scrubFraction ?? hoverFraction
            ZStack(alignment: .leading) {
                track(width: w, shown: shown, active: active)
                thumb(active: active)
                    .offset(x: w * shown)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                // "0:20 / 0:52": where you'd land and the length, both counted from the start.
                bubble(Formatters.duration((bubbleFraction ?? shown) * duration) + " / " + Formatters.duration(duration))
                    .offset(x: min(max(w * (bubbleFraction ?? shown) - bubbleWidth / 2, 0), max(w - bubbleWidth, 0)), y: -28)
                    .animation(.easeOut(duration: 0.15)) { $0.opacity(bubbleFraction != nil && duration > 0 ? 1 : 0) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                // The frame sits over the bubble and follows it 1:1; it only
                // shows once a frame for that spot exists, never a placeholder.
                if let f = bubbleFraction, duration > 0, let image = thumbnails?.image(near: f) {
                    let tw = thumbnailWidth, th = thumbnailWidth * 9 / 16
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tw, height: th)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.25)))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .offset(x: min(max(w * f - tw / 2, 0), max(w - tw, 0)), y: -28 - th - 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard duration > 0 else { return }
                    let f = clamp(v.location.x / w)
                    // A tick every 2% of the film while dragging, like a detent.
                    let tick = Int(f * 50)
                    if tick != scrubTick { scrubTick = tick }
                    committed = nil
                    scrubFraction = f
                    thumbnails?.request(f)
                    onScrub(f)
                }
                .onEnded { v in
                    guard duration > 0 else { scrubFraction = nil; return }
                    let f = clamp(v.location.x / w)
                    committed = f
                    scrubFraction = nil
                    onCommit(f)
                })
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hoverFraction = clamp(p.x / w)
                    thumbnails?.request(clamp(p.x / w))
                } else {
                    hoverFraction = nil
                }
            }
            .selectionHaptic(scrubTick)
            // Positions must never inherit an animation from whatever changed them.
            .transaction { $0.animation = nil }
        }
        .frame(height: 32)
        .onChange(of: scrubFraction != nil || hoverFraction != nil) { _, showing in onPreviewing?(showing) }
        #if DEBUG
        .task(id: thumbnails == nil) {
            guard let f = AppModel.debugPreviewFraction else { return }
            hoverFraction = f
            while !Task.isCancelled, thumbnails?.image(near: f) == nil {
                thumbnails?.request(f)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #endif
        .onChange(of: fraction) { _, now in
            // Release the held position once playback is there (within ~1 s).
            if let c = committed, abs(now - c) * max(duration, 1) < 1.5 { committed = nil }
        }
        .task(id: committed) {
            guard committed != nil else { return }
            try? await Task.sleep(for: .seconds(3))  // a seek that never lands mustn't pin the thumb
            committed = nil
        }
    }

    private func track(width w: CGFloat, shown: Double, active: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(.white.opacity(0.45)).frame(width: w * clamp(buffered))
            if stalled, buffered > 0.005 {
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                    .offset(x: max(w * clamp(buffered) - 12, 0))
            }
            // Downloaded pieces of a torrent stream: where you can jump without waiting.
            ForEach(Array(available.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(.white.opacity(0.45))
                    .frame(width: max(1, w * (clamp(r.upperBound) - clamp(r.lowerBound))))
                    .offset(x: w * clamp(r.lowerBound))
            }
            Capsule().fill(Palette.brand).frame(width: w * shown)
            if let (a, b) = loop {
                Rectangle().fill(Palette.brandBright.opacity(0.55))
                    .frame(width: max(2, w * (clamp(b ?? a) - clamp(a))))
                    .offset(x: w * clamp(a))
                // A and B ticks, so the loop reads even when it's short.
                Capsule().fill(.white).frame(width: 2, height: 12).offset(x: w * clamp(a) - 1)
                if let b { Capsule().fill(.white).frame(width: 2, height: 12).offset(x: w * clamp(b) - 1) }
            }
        }
        // Chapters cut 2 pt gaps through the whole track.
        .mask {
            ZStack(alignment: .leading) {
                Rectangle()
                ForEach(chapterMarks.filter { $0 > 0.002 && $0 < 0.998 }, id: \.self) { m in
                    Rectangle().frame(width: 2).offset(x: w * m - 1).blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
        .animation(.snappy(duration: 0.2)) { $0.frame(height: active ? 7 : 4) }
    }

    /// The thumb is centred on a zero-width anchor, so growing it never shifts it.
    private func thumb(active: Bool) -> some View {
        Color.clear.frame(width: 0, height: 0)
            .overlay {
                Circle().fill(Palette.brand)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .animation(.snappy(duration: 0.2)) {
                        $0.frame(width: active ? Self.activeThumbSize : Self.thumbSize,
                                 height: active ? Self.activeThumbSize : Self.thumbSize)
                    }
            }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold)).monospacedDigit()
            .lineLimit(1)
            .frame(width: bubbleWidth, height: 24)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.2)))
    }

    /// 160 pt on Mac and iPad, 120 on iPhone.
    private var thumbnailWidth: CGFloat {
        #if os(iOS)
        sizeClass == .compact ? 120 : 160
        #else
        160
        #endif
    }

    private func clamp(_ v: Double) -> Double { min(max(v.isFinite ? v : 0, 0), 1) }
}
