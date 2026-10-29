import DesignSystem
import Domain
import Playback
import SwiftUI

/// A card in the middle of the player that stops playback until you choose:
/// the error card (Try Again, Try Another Release, Play Download, Close) and
/// the end-of-film card (Watch Again, Back to Browse). The video's controls
/// hide behind it.
struct PlayerMessageCard: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        var symbol: String?
        var primary = false
        let perform: () -> Void
    }

    var symbol: String?
    var eyebrow: String?
    let title: String
    var message: String?
    let actions: [Action]

    var body: some View {
        GeometryReader { geo in
            // Phones in landscape are short: no symbol, buttons two to a row.
            let short = geo.size.height < 500
            card(short: short)
                .frame(maxWidth: short ? 560 : 440)
                .padding(.horizontal, Spacing.l)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .transition(.opacity)
    }

    private func card(short: Bool) -> some View {
        VStack(alignment: .center, spacing: Spacing.m) {
            if let symbol, !short {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Palette.elevated, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(spacing: Spacing.xs) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.heavy)).tracking(1.4)
                        .foregroundStyle(Palette.textTertiary)
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            buttons(short: short)
                .padding(.top, Spacing.xs)
        }
        .padding(short ? Spacing.l : Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Stacked full-width buttons; two to a row when the card is short.
    @ViewBuilder private func buttons(short: Bool) -> some View {
        if short && actions.count > 2 {
            let rows = stride(from: 0, to: actions.count, by: 2).map { Array(actions[$0..<min($0 + 2, actions.count)]) }
            VStack(spacing: Spacing.s) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: Spacing.s) {
                        ForEach(rows[i]) { button($0) }
                    }
                }
            }
        } else if short {
            HStack(spacing: Spacing.s) { ForEach(actions) { button($0) } }
        } else {
            VStack(spacing: Spacing.s) { ForEach(actions) { button($0) } }
        }
    }

    @ViewBuilder private func button(_ a: Action) -> some View {
        let label = Group {
            if let symbol = a.symbol { Label(a.title, systemImage: symbol) } else { Text(a.title) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        if a.primary {
            Button(action: a.perform) { label }
                .buttonStyle(PlayButtonStyle(fullWidth: true))
                .accessibilityIdentifier("playerCard.\(a.id)")
        } else {
            Button(action: a.perform) { label }
                .buttonStyle(GlassButtonStyle(fullWidth: true))
                .accessibilityIdentifier("playerCard.\(a.id)")
        }
    }
}

/// Words for a playback failure: what happened, in plain language, without
/// the networking stack's sentence.
enum PlayerErrorText {
    static func title(for item: NowPlayingItem?) -> String {
        guard let item else { return "Can't play this video" }
        return item.key.episodeNumbers != nil ? "Can't play this episode" : "Can't play “\(item.title)”"
    }

    static func message(for error: PlaybackError, offline: Bool, canTryAnother: Bool) -> String {
        if offline { return "You're offline. Connect to the internet, or play a download." }
        let next = canTryAnother ? "Try again, or try another release." : "Check your connection and try again."
        switch error {
        case .unreachable:
            return "Couldn't reach the server for this video. " + next
        case .unsupportedFormat(let format):
            let f = format.isEmpty ? "" : " (\(format.uppercased()))"
            return "This video's format\(f) doesn't play on this device." + (canTryAnother ? " Try another release." : "")
        case .decodeFailed:
            return "The video stopped because part of it couldn't be read. " + next
        case .source(let e):
            return UserFacingError.message(for: e, context: .playback)
        }
    }
}
