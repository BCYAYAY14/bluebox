import DesignSystem
import Domain
import SwiftUI

/// The season's download button, beside "Season 2 ▾" on a show's page. It
/// opens one menu: Download Season ("8 episodes · about 9.6 GB"), Unwatched
/// Only when some are watched, As One Season Pack when an add-on has the
/// season as one healthy torrent, and Download Rules…. While the season
/// downloads the arrow becomes a ring, and `SeasonDownloadBar` shows one
/// thin progress line under the picker.
struct SeasonDownloadButton: View {
    @Environment(AppModel.self) private var app
    let seasonName: String
    let status: SeasonDownloadStatus
    /// Every episode not downloaded yet; nil when none can be.
    let all: SeasonDownloadBar.Offer?
    /// Unwatched episodes not downloaded yet, when that's fewer than `all`.
    let unwatched: SeasonDownloadBar.Offer?
    /// What to look a season pack up for.
    let pack: SeasonPackRequest?
    /// The show's rules in one line, under Download Rules….
    let rulesSummary: String
    let downloadAll: () -> Void
    let downloadUnwatched: () -> Void
    let editRules: () -> Void
    @State private var open = false
    @State private var offer: SeasonPackOffer?

    var body: some View {
        Button { open.toggle() } label: {
            icon
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .blueboxMenu(isPresented: $open, title: "Download \(seasonName)") { entries }
        .fixedSize()
        .help("Download \(seasonName)")
        .accessibilityLabel("Download \(seasonName)")
        .accessibilityValue(status.inProgress ? status.detail : status.isComplete && all == nil ? "Downloaded" : "")
        .accessibilityIdentifier("downloadSeason")
        #if DEBUG
        // Screenshots: `-open-season-download` opens the menu once the page settles.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-open-season-download") else { return }
            try? await Task.sleep(for: .seconds(2.5))
            open = true
        }
        #endif
        .task(id: pack?.id) {
            offer = nil
            guard let pack else { return }
            offer = await app.seasonPackOffer(series: pack.series, season: pack.season, episodes: pack.episodes,
                                              separateBytes: pack.separateBytes)
        }
    }

    @ViewBuilder private var icon: some View {
        if status.inProgress {
            ProgressRing(fraction: status.preparing == status.total ? 0 : status.fraction, tint: Palette.brand)
                .frame(width: 18, height: 18)
        } else if status.isComplete && all == nil {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.brandBright)
        } else {
            Image(systemName: "arrow.down").font(.system(size: 15, weight: .bold))
        }
    }

    @BlueboxMenuBuilder private var entries: [BlueboxMenuEntry] {
        BlueboxMenuSection {
            if let all {
                BlueboxMenuButton(status.completed > 0 ? "Download Rest of Season" : "Download \(seasonName)",
                                  systemImage: "arrow.down.circle", subtitle: "\(episodes(all.count)) · \(all.sizeLabel)") {
                    downloadAll()
                }
            }
            if let unwatched {
                BlueboxMenuButton("Unwatched Only", systemImage: "eye.slash",
                                  subtitle: "\(episodes(unwatched.count)) · \(unwatched.sizeLabel)") { downloadUnwatched() }
            }
            if let offer, let pack {
                BlueboxMenuButton("As One Season Pack", systemImage: "shippingbox", subtitle: offer.menuSubtitle) {
                    Task { await app.downloadSeasonPack(offer, seriesKey: pack.series, seriesName: pack.seriesName) }
                }
            }
        }
        BlueboxMenuSection {
            BlueboxMenuButton("Download Rules…", systemImage: "arrow.triangle.2.circlepath", subtitle: rulesSummary) { editRules() }
        }
    }

    private func episodes(_ n: Int) -> String { n == 1 ? "1 episode" : "\(n) episodes" }
}

private extension SeasonPackOffer {
    /// "1080p · BluRay · 184 seeders · about 34 GB".
    var menuSubtitle: String {
        ([release.resolution, release.info.source?.title, release.seeders.map { "\($0) seeders" }].compactMap { $0 }
         + [packBytes.map { SeasonActionPlan.sizeLabel($0) }].compactMap { $0 }).joined(separator: " · ")
    }
}

/// The season's download line under "Season 2 ▾", only while there's
/// something to show:
///
/// - downloading: "Downloading Season 2 · 3 of 8 · 41%" over a thin bar,
///   with Pause and Cancel;
/// - all saved: "Season 2 downloaded · 9.4 GB".
///
/// Starting a download is the ↓ button's menu (`SeasonDownloadButton`).
struct SeasonDownloadBar: View {
    struct Offer: Equatable {
        let count: Int
        let sizeLabel: String
    }

    let seasonName: String
    let status: SeasonDownloadStatus
    /// True when every episode there is to get is saved.
    let allSaved: Bool
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if status.inProgress || status.isStopped {
                progressLine.transition(.opacity)
            } else if status.isComplete && allSaved {
                doneLine.transition(.opacity)
            }
        }
        .animation(Motion.snappy(reduceMotion), value: status.inProgress)
        .animation(Motion.snappy(reduceMotion), value: status.isComplete)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seasonDownloadBar")
    }

    // MARK: Downloading

    private var progressLine: some View {
        let title = status.inProgress ? "Downloading \(seasonName)" : status.failed > 0 && status.paused == 0
            ? "\(seasonName) stopped" : "\(seasonName) paused"
        return HStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text(status.detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(.numericText())
                }
                .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.elevated)
                        Capsule().fill(status.inProgress ? Palette.brand : Palette.textTertiary)
                            .frame(width: max(geo.size.width * status.fraction, status.fraction > 0 ? 3 : 0))
                            .animation(.easeOut(duration: 0.4), value: status.fraction)
                    }
                }
                .frame(height: 3)
            }
            if status.inProgress {
                iconButton("pause.fill", label: "Pause \(seasonName) downloads", id: "pauseSeason", action: pause)
                    .disabled(status.downloading + status.queued == 0)
            } else {
                iconButton("arrow.down", label: "Resume \(seasonName) downloads", id: "resumeSeason", action: resume)
            }
            iconButton("xmark", label: "Cancel \(seasonName) downloads", id: "cancelSeason", action: cancel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.detail)")
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 36, height: 36)
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
            CheckDot(size: 16)
            Text("\(seasonName) downloaded").font(.footnote.weight(.semibold))
            Text("· " + episodes(status.total) + (status.knownBytes > 0 ? " · \(Formatters.bytes(status.knownBytes))" : ""))
                .font(.footnote).foregroundStyle(Palette.textSecondary)
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
