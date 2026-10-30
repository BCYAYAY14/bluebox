import DesignSystem
import SwiftUI

/// A short message at the top of the player ("Volume 60%", "Skipped intro",
/// "Saved to Pictures"), optionally with one action (Undo). On the cards'
/// surface (`playerNoticeSurface`), with a symbol, and a level bar for values
/// that have one.
struct PlayerNotice: Equatable {
    enum Style: Equatable { case normal, warning }

    var message: String
    var symbol: String?
    /// 0…1, drawn as a bar (volume, how far through).
    var level: Double?
    var style: Style = .normal
    var actionTitle: String?
    /// Notices of the same kind (pressing volume up again) replace each other
    /// in place, without coming in again.
    var kind: String
    var id = UUID()

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.message == b.message && a.level == b.level && a.symbol == b.symbol
            && a.actionTitle == b.actionTitle && a.style == b.style
    }
}

struct PlayerNoticeView: View {
    let notice: PlayerNotice
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = notice.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(notice.style == .warning ? Palette.warning : Palette.brandBright)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.message)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                if let level = notice.level {
                    LevelBar(value: level).frame(width: 140)
                }
            }
            if let title = notice.actionTitle, let action {
                Divider().frame(height: 20).overlay(Palette.edge)
                Button(action: action) {
                    Text(ui: title)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(Palette.brandBright)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("toastAction")
            }
        }
        .padding(.leading, notice.symbol == nil ? 16 : 12)
        .padding(.trailing, notice.actionTitle == nil ? 16 : 8)
        .padding(.vertical, notice.level == nil ? 10 : 9)
        .frame(minHeight: 40)
        .playerNoticeSurface()
        .frame(maxWidth: 420)
        .allowsHitTesting(notice.actionTitle != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// A slim bar for a level, filled in the brand colour.
private struct LevelBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(Palette.brandBright)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.snappy(duration: 0.18), value: value)
        .accessibilityHidden(true)
    }
}

/// A label in a notice: the symbol in the brand colour beside the words.
struct NoticeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Palette.brandBright)
            configuration.title.foregroundStyle(Palette.textPrimary)
        }
    }
}

extension View {
    /// The player's notices and floating buttons: the cards' raised grey and
    /// hairline edge (not a translucent black pill), rounded to match them.
    func playerNoticeSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: PlayerCardMetrics.radius, style: .continuous)
        return self
            .background(shape.fill(Palette.surface))
            .overlay(shape.strokeBorder(Palette.edge))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .environment(\.colorScheme, .dark)
    }
}
