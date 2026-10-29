import DesignSystem
import Domain
import SwiftUI

/// The season's download line, under "Season 2 ▾" on a show's page:
///
/// - nothing saved yet: **Download Season** · "8 episodes · about 9.6 GB",
///   and **Unwatched** when some are already watched;
/// - downloading: a bar filling with the season ("3 of 8 · 41%") with Pause
///   and Cancel;
/// - all saved: "Season 2 downloaded · 9.4 GB".
///
/// Downloading a season lives here only; the ⋯ beside the picker marks it
/// watched, and the show's Download Rules card holds Smart Downloads. When
/// an add-on has the season as one torrent, a season pack is offered under
/// the buttons with both sizes.
struct SeasonDownloadBar: View {
    struct Offer: Equatable {
        let count: Int
        let sizeLabel: String
    }

    let seasonName: String
    let status: SeasonDownloadStatus
    /// Every episode not downloaded yet; nil when none can be.
    let all: Offer?
    /// Unwatched episodes not downloaded yet, when that's fewer than `all`.
    let unwatched: Offer?
    /// What to look a season pack up for, beside Download Season.
    var pack: SeasonPackRequest? = nil
    let downloadAll: () -> Void
    let downloadUnwatched: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if status.inProgress || status.isStopped {
                progressCard.transition(.opacity)
            } else if let all {
                offers(all).transition(.opacity)
            } else if status.isComplete {
                doneLine.transition(.opacity)
            }
        }
        .animation(Motion.snappy(reduceMotion), value: status.inProgress)
        .animation(Motion.snappy(reduceMotion), value: status.isComplete)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seasonDownloadBar")
    }

    // MARK: Not started

    /// Side by side when both fit untruncated (iPad, Mac), else stacked (iPhone).
    private func offers(_ all: Offer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { offerButtons(all, stretch: false) }
                VStack(alignment: .leading, spacing: Spacing.s) { offerButtons(all, stretch: true) }
            }
            if let pack { SeasonPackOfferRow(request: pack) }
        }
        .foregroundStyle(Palette.textPrimary)
    }

    @ViewBuilder private func offerButtons(_ all: Offer, stretch: Bool) -> some View {
        Group {
            Button(action: downloadAll) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "arrow.down.circle").font(.body.weight(.semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.completed > 0 ? "Download Rest of Season" : "Download \(seasonName)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(episodes(all.count)) · \(all.sizeLabel)")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    if stretch { Spacer(minLength: 0) }
                }
                .padding(.horizontal, Spacing.m)
                .frame(maxWidth: stretch ? .infinity : nil, minHeight: 48)
                .background(Palette.glassFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PressableStyle(haptic: true))
            .accessibilityLabel("Download \(seasonName), \(episodes(all.count)), \(all.sizeLabel)")
            .accessibilityIdentifier("downloadSeason")
            if let unwatched {
                Button(action: downloadUnwatched) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unwatched Only").font(.subheadline.weight(.semibold))
                        Text("\(episodes(unwatched.count)) · \(unwatched.sizeLabel)")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Spacing.m)
                    .frame(maxWidth: stretch ? .infinity : nil, minHeight: 48, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PressableStyle(haptic: true))
                .accessibilityLabel("Download unwatched episodes, \(episodes(unwatched.count)), \(unwatched.sizeLabel)")
                .accessibilityIdentifier("downloadRemaining")
            }
        }
    }

    // MARK: Downloading

    private var progressCard: some View {
        let title = status.inProgress ? "Downloading \(seasonName)" : status.failed > 0 && status.paused == 0
            ? "\(seasonName) stopped" : "\(seasonName) paused"
        return HStack(spacing: Spacing.m) {
            ProgressRing(fraction: status.preparing == status.total ? 0 : status.fraction,
                         tint: status.inProgress ? Palette.brand : Palette.textSecondary)
                .frame(width: 26, height: 26)
                .overlay {
                    if status.preparing == status.total {
                        // Releases are being found: a turning arc, not a bar stuck at 0.
                        SpinningArc().frame(width: 26, height: 26)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if status.inProgress {
                iconButton("pause.fill", label: "Pause \(seasonName) downloads", id: "pauseSeason", action: pause)
                    .disabled(status.downloading + status.queued == 0)
            } else {
                iconButton("arrow.down", label: "Resume \(seasonName) downloads", id: "resumeSeason", action: resume)
            }
            iconButton("xmark", label: "Cancel \(seasonName) downloads", id: "cancelSeason", action: cancel)
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .frame(minHeight: 52)
        .background(alignment: .leading) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Palette.surface
                    (status.inProgress ? Palette.brand.opacity(0.18) : Color.white.opacity(0.06))
                        .frame(width: geo.size.width * status.fraction)
                        .animation(.easeOut(duration: 0.4), value: status.fraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .foregroundStyle(Palette.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.detail)")
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
        .help(label)
    }

    // MARK: Done

    private var doneLine: some View {
        HStack(spacing: Spacing.s) {
            CheckDot(size: 18)
            Text("\(seasonName) downloaded").font(.subheadline.weight(.semibold))
            Text("· " + episodes(status.total) + (status.knownBytes > 0 ? " · \(Formatters.bytes(status.knownBytes))" : ""))
                .font(.subheadline).foregroundStyle(Palette.textSecondary)
        }
        .lineLimit(1)
        .foregroundStyle(Palette.textPrimary)
        .accessibilityElement(children: .combine)
    }

    private func episodes(_ n: Int) -> String { n == 1 ? "1 episode" : "\(n) episodes" }
}

/// A short arc turning in a circle: "working on it" with no amount to show.
struct SpinningArc: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Palette.brandBright, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Season packs

/// What to look a season pack up for: the episodes Download Season would get.
struct SeasonPackRequest: Equatable {
    let series: MediaKey
    let season: Int
    let episodes: [Episode]
    let seriesName: String
    /// The page's estimate for downloading them one by one.
    let separateBytes: Int64
    /// Looked up again when the season or what's left of it changes.
    var id: String { "\(series.rawValue)#\(season)#\(episodes.count)" }
}

/// "Download as a Season Pack": one torrent for the season, with its size
/// against downloading the episodes one by one. Shown only when an add-on
/// has a healthy pack; the lookup is the add-ons' cached answer for the
/// season's first episode.
struct SeasonPackOfferRow: View {
    @Environment(AppModel.self) private var app
    let request: SeasonPackRequest
    @State private var offer: SeasonPackOffer?

    var body: some View {
        Group {
            if let offer {
                Button {
                    Task { await app.downloadSeasonPack(offer, seriesKey: request.series, seriesName: request.seriesName) }
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "shippingbox").font(.body.weight(.semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Download as a Season Pack").font(.subheadline.weight(.semibold))
                            Text(offer.label).font(.caption).foregroundStyle(Palette.textSecondary)
                            Text(offer.comparison).font(.caption).foregroundStyle(Palette.textTertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PressableStyle(haptic: true))
                .accessibilityLabel("Download as a season pack, \(offer.label), \(offer.comparison)")
                .accessibilityIdentifier("downloadSeasonPack")
                .padding(.top, Spacing.s)
                .transition(.opacity)
            } else {
                // An empty Group has no view to hang `.task` on.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: request.id) {
            offer = await app.seasonPackOffer(series: request.series, season: request.season, episodes: request.episodes,
                                              separateBytes: request.separateBytes)
        }
    }
}
