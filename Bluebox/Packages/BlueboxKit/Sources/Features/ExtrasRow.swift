import DesignSystem
import Domain
import SwiftUI

/// A row of trailer and extras thumbnails. Tapping one plays it in a sheet
/// (or calls `onSelect` when given).
///
///     ExtrasRow(videos: videos)                 // you have the videos
///     ExtrasSection(key: title.key)             // loads them for a title
public struct ExtrasRow: View {
    let videos: [TitleVideo]
    let inset: CGFloat
    let onSelect: ((TitleVideo) -> Void)?
    @State private var playing: TitleVideo?

    public init(videos: [TitleVideo], inset: CGFloat = 16, onSelect: ((TitleVideo) -> Void)? = nil) {
        self.videos = videos; self.inset = inset; self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            let width = Self.cardWidth(for: geo.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.cardGap) {
                    ForEach(videos) { video in
                        Button { select(video) } label: { ExtraCard(video: video, width: width) }
                            .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, inset)
            }
        }
        .frame(height: Self.rowHeight)
        .sheet(item: $playing) { TrailerSheet(video: $0) }
    }

    static let rowHeight: CGFloat = 200
    static func cardWidth(for available: CGFloat) -> CGFloat { min(max(available * 0.42, 200), 280) }

    private func select(_ video: TitleVideo) {
        if let onSelect { onSelect(video) } else { playing = video }
    }
}

/// "Trailers & More" for a title (or one season): loads the videos and shows
/// the heading and row, or nothing when there are none.
public struct ExtrasSection: View {
    @Environment(AppModel.self) private var app
    let key: MediaKey
    let season: Int?
    let inset: CGFloat
    /// Off under a "Trailers & More" tab, which already says it.
    let showsTitle: Bool
    @State private var videos: [TitleVideo] = []

    public init(key: MediaKey, season: Int? = nil, inset: CGFloat = 16, showsTitle: Bool = true) {
        self.key = key; self.season = season; self.inset = inset; self.showsTitle = showsTitle
    }

    public var body: some View {
        // A stack, not a Group: an empty Group has nothing to run `.task` on, so it never loaded.
        VStack(alignment: .leading, spacing: 0) {
            if !videos.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if showsTitle {
                        Text("Trailers & More")
                            .font(Typography.rowTitle).foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, inset)
                    }
                    ExtrasRow(videos: videos, inset: inset)
                }
            }
        }
        .task(id: "\(key.rawValue)-\(season ?? -1)") { videos = await app.videos(for: key, season: season) }
    }
}

private struct ExtraCard: View {
    let video: TitleVideo
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ArtworkView(url: video.thumbnailURL, fallbackTitle: video.name, kind: .still, pixelWidth: 480)
                    .frame(width: width, height: width * 9 / 16)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    .scaleEffect(hovering ? 1.08 : 1)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            Text(video.name)
                .font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                .lineLimit(2).multilineTextAlignment(.leading)
            Text(video.kind.label)
                .font(Typography.caption).foregroundStyle(Palette.textSecondary)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(video.kind.label): \(video.name)")
        .accessibilityAddTraits(.isButton)
    }
}
