import DesignSystem
import Domain
import Foundation
import MediaSources
import Metadata
import Observation
import Playback
import SkipSegments
import SwiftUI

/// Skip Intro, Recap and Credits for the session that's playing: looks the
/// segments up (chapters, Jellyfin, then the crowd databases), follows the
/// playhead, and says what the pill should offer.
@Observable
@MainActor
final class SkipController {
    private(set) var result: SkipSegmentResolver.Result?
    /// What the pill offers now.
    private(set) var offer: SkipSegmentPlanner.Offer?
    /// The segment behind `offer`, for "Wrong time?".
    private(set) var activeSegment: SkipSegment?
    /// Seconds left before Automatic credits move on, while counting down.
    private(set) var countdown: Int?
    /// The part the pill offers "Always for this show" for, the first time it
    /// comes up for a show (nil: don't offer).
    private(set) var alwaysPart: ShowSkipRules.Part?
    /// When Skip Intro or Skip Recap came up: the pill shows on its own for
    /// `shownAlone`, then only with the controls (nil: past that, or credits).
    private(set) var freshSince: Date?
    @ObservationIgnored var shownAlone: TimeInterval = 8

    /// Segments already skipped automatically or dismissed ("Watch Credits"):
    /// seeking back into one doesn't skip it again.
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var freshTask: Task<Void, Never>?
    @ObservationIgnored private var lastQuery: SkipSegmentQuery?

    static let resolver = SkipSegmentResolver.live(http: URLSessionHTTPClient())

    var usesCrowdSources: Bool { activeSegment?.source.isCrowdSourced ?? false }

    func reset() {
        result = nil; offer = nil; activeSegment = nil; settled = []; lastQuery = nil; alwaysPart = nil
        cancelCountdown(); endFresh()
    }

    /// Looks segments up for `query` (cheap to repeat: crowd answers are cached).
    func load(_ query: SkipSegmentQuery) async {
        guard query != lastQuery else { return }
        lastQuery = query
        let found = await Self.resolver.resolve(query)
        guard !Task.isCancelled, lastQuery == query else { return }
        result = found
    }

    enum Action: Equatable { case seek(TimeInterval), playNext }

    /// Follows the playhead. Returns what to do without a press (Automatic mode).
    func update(position: TimeInterval, duration: TimeInterval?, introMode: SkipSegmentPlanner.Mode,
                creditsMode: SkipSegmentPlanner.Mode, hasNext: Bool, enabled: Bool, isScrubbing: Bool) -> Action? {
        update(position: position, duration: duration,
               modes: .init(intro: introMode, recap: introMode, credits: creditsMode),
               hasNext: hasNext, autoplayNext: true, enabled: enabled, isScrubbing: isScrubbing)
    }

    /// Follows the playhead with a mode per part (the show's "always skip"
    /// rules applied). `offerAlways` is asked once per new offer whether to
    /// show "Always for this show" for its part (it records that it asked).
    func update(position: TimeInterval, duration: TimeInterval?, modes: SkipSegmentPlanner.Modes, hasNext: Bool,
                autoplayNext: Bool, enabled: Bool, isScrubbing: Bool,
                offerAlways: (ShowSkipRules.Part) -> Bool = { _ in false }) -> Action? {
        guard enabled, !isScrubbing, let segments = result?.segments, !segments.isEmpty else {
            clearOffer()
            return nil
        }
        let segment = SkipSegmentPlanner.active(at: position, in: segments, duration: duration)
        let id = segment.map(Self.id)
        guard let found = SkipSegmentPlanner.offer(at: position, segments: segments, duration: duration,
                                                   modes: modes, hasNextEpisode: hasNext, autoplayNext: autoplayNext),
              let segment, let id, !settled.contains(id) else {
            clearOffer()
            return nil
        }
        if activeSegment != segment {
            activeSegment = segment
            // Only beside a button: an automatic skip has nothing to add it to.
            // Credits with Autoplay off can't always move on, so don't promise it.
            let part = ShowSkipRules.Part(segment.kind)
            let promisable = !(part == .credits && hasNext && !autoplayNext)
            alwaysPart = !found.auto && promisable && offerAlways(part) ? part : nil
            if !found.auto, case .skip = found.0 { startFresh() } else { endFresh() }
        }
        if offer != found.0 { offer = found.0 }
        guard found.auto else { return nil }
        switch found.0 {
        case .skip(_, let to):
            settled.insert(id)
            offer = nil
            return .seek(to)
        case .nextEpisode:
            // Automatic credits count down on the pill, so there's a moment to stay.
            if countdown == nil, countdownTask == nil { startCountdown() }
            return nil
        }
    }

    private func clearOffer() {
        if offer != nil { offer = nil; activeSegment = nil }
        if alwaysPart != nil { alwaysPart = nil }
        cancelCountdown(); endFresh()
    }

    /// The pill was pressed.
    func accept() -> Action? {
        guard let offer else { return nil }
        if let s = activeSegment { settled.insert(Self.id(s)) }
        self.offer = nil
        alwaysPart = nil
        cancelCountdown(); endFresh()
        switch offer {
        case .skip(_, let to): return .seek(to)
        case .nextEpisode: return .playNext
        }
    }

    /// "Watch Credits": stay, and don't offer again for this segment.
    func dismiss() {
        if let s = activeSegment { settled.insert(Self.id(s)) }
        offer = nil
        activeSegment = nil
        alwaysPart = nil
        cancelCountdown(); endFresh()
    }

    /// Whether the pill shows: Next Episode until a choice is made; Skip Intro
    /// and Skip Recap for their first seconds, then while the controls show.
    /// Hidden, it stays in place (see-through), so Return still skips.
    func pillShown(controlsShown: Bool) -> Bool {
        guard let offer else { return false }
        return offer == .nextEpisode || freshSince != nil || controlsShown
    }

    private func startFresh() {
        freshTask?.cancel()
        freshSince = Date()
        freshTask = Task { [weak self] in
            guard let wait = self?.shownAlone else { return }
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.freshSince = nil
            self.freshTask = nil
        }
    }

    private func endFresh() {
        freshTask?.cancel(); freshTask = nil
        if freshSince != nil { freshSince = nil }
    }

    /// While true the countdown stands still: playback is paused, or the pill
    /// is hidden (a card is open), so nobody could see it or press "Watch Credits".
    @ObservationIgnored var holdsCountdown = false

    /// Set by the view: what to do when an automatic countdown reaches zero.
    @ObservationIgnored var onCountdownFinished: (() -> Void)?

    private func startCountdown() {
        countdown = 5
        countdownTask = Task { [weak self] in
            while let left = self?.countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if self.holdsCountdown { continue }
                self.countdown = left - 1
            }
            guard !Task.isCancelled, let self else { return }
            self.countdownTask = nil
            self.countdown = nil
            if let s = self.activeSegment { self.settled.insert(Self.id(s)) }
            self.offer = nil
            self.onCountdownFinished?()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        if countdown != nil { countdown = nil }
    }

    private static func id(_ s: SkipSegment) -> String { "\(s.kind.rawValue)@\(Int(s.start))" }

    func setResultForTesting(_ r: SkipSegmentResolver.Result) { result = r }
}

// MARK: - Query

extension AppModel {
    /// What the skip lookup needs about the session's item, or nil if nothing plays.
    func skipQuery(for session: PlayerSession) async -> SkipSegmentQuery? {
        guard let item = session.item else { return nil }
        let key = item.key
        let show = key.seriesKey ?? key
        var query = SkipSegmentQuery(
            chapters: session.snapshot.chapters.map { ChapterMark(title: $0.title, start: $0.start) },
            duration: session.snapshot.duration,
            tmdbID: show.tmdbID,
            season: key.episodeNumbers?.season, episode: key.episodeNumbers?.episode,
            allowsCrowdSources: settings.crowdSkipsAllowed(for: key))
        if query.allowsCrowdSources, show.tmdbID != nil {
            query.imdbID = try? await metadata.detail(for: show).imdbID
        }
        if let resource = session.currentResource,
           await registry.source(resource.variant.sourceID) is JellyfinSource {
            query.jellyfin = JellyfinItemRef(streamURL: resource.url, itemID: resource.variant.id)
        }
        return query
    }
}

// MARK: - Pill

/// Netflix's bottom-right button: white with black text for the main action,
/// a quieter outlined one beside it for "Watch Credits", and a small
/// "Wrong time?" under crowd timestamps. Skip Intro and Skip Recap show on
/// their own for 8 s, then only with the controls; Next Episode stays.
struct SkipPill: View {
    let skip: SkipController
    /// The player's controls are up: Skip Intro and Skip Recap show again with them.
    var controlsShown = false
    let onAccept: () -> Void
    let onWrongTime: () -> Void
    /// "Always for this show" (offered the first time a part comes up for a show).
    var onAlways: (ShowSkipRules.Part) -> Void = { _ in }

    var body: some View {
        if let offer = skip.offer {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: Spacing.s) {
                    if offer == .nextEpisode {
                        Button("Watch Credits") { skip.dismiss() }
                            .buttonStyle(SkipSecondaryStyle())
                            .accessibilityIdentifier("watchCredits")
                    }
                    Button(action: onAccept) {
                        HStack(spacing: 8) {
                            Image(systemName: offer == .nextEpisode ? "play.fill" : "forward.end.fill")
                                .font(.subheadline.weight(.bold))
                            Text(title(offer))
                                .contentTransition(.numericText(countsDown: true))
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(SkipPrimaryStyle())
                    .overlay(alignment: .bottom) {
                        if offer != .nextEpisode, let since = skip.freshSince { TimeLeftBar(since: since, duration: skip.shownAlone) }
                    }
                    .accessibilityIdentifier("skipSegment")
                    .keyboardShortcut(.return, modifiers: [])
                }
                if let part = skip.alwaysPart {
                    Button { onAlways(part) } label: {
                        Label("Always for this show", systemImage: "forward.end.alt")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .help("Skip the \(part.title.lowercased()) of every episode of this show without asking")
                    .accessibilityLabel("Always skip the \(part.title.lowercased()) for this show")
                    .accessibilityIdentifier("alwaysSkip")
                    .transition(.opacity)
                }
                if skip.usesCrowdSources, offer != .nextEpisode {
                    Button("Wrong time?", action: onWrongTime)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .help("Stop using community timestamps for this show")
                        .accessibilityHint("Stops using community timestamps for this show")
                }
            }
            .animation(.default, value: skip.countdown)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .animation(.easeInOut(duration: 0.35), value: shown)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    private var shown: Bool { skip.pillShown(controlsShown: controlsShown) }

    private func title(_ offer: SkipSegmentPlanner.Offer) -> String {
        let base = SkipSegmentPlanner.title(for: offer)
        if offer == .nextEpisode, let n = skip.countdown { return "\(base) in \(n)" }
        return base
    }
}

/// A thin bar along the bottom of Skip Intro running out over the seconds it
/// shows on its own.
private struct TimeLeftBar: View {
    let since: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let left = max(0, 1 - context.date.timeIntervalSince(since) / duration)
            GeometryReader { g in
                Rectangle().fill(.black.opacity(0.3))
                    .frame(width: g.size.width * left, height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SkipPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .background(.white.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

private struct SkipSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .background(Palette.surface.opacity(configuration.isPressed ? 0.95 : 0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.35)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
