#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI

/// Bluebox › About Bluebox on the Mac: the icon and drawn wordmark on black,
/// the version and build, a line on what Bluebox is, Acknowledgements and
/// Licence, and the copyright. The app shows it in a fixed-size window with a
/// hidden title bar (`BlueboxApp`), in place of the stock About panel.
public struct AboutWindowView: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            BlueboxWordmark(size: 30)
                .padding(.top, Spacing.xs)

            Text("Version \(AppVersion.display)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .padding(.top, Spacing.xxs)

            Text(Self.summary)
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.l)

            HStack(spacing: Spacing.s) {
                Button("Acknowledgements") { openWindow(id: AboutDocument.windowID, value: AboutDocument.acknowledgements) }
                Button("Licence") { openWindow(id: AboutDocument.windowID, value: AboutDocument.licence) }
            }
            .buttonStyle(AboutButtonStyle())
            .padding(.top, Spacing.xl)

            Text(Self.copyright)
                .font(.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, Spacing.l)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xs)  // the hidden title bar (traffic lights) is above, in the safe area
        .padding(.bottom, Spacing.xl)
        .frame(width: 340)
        .containerBackground(Palette.background, for: .window)
        .preferredColorScheme(.dark)
    }

    /// What Bluebox is, in a line.
    static let summary = "A personal movie and TV player for your own sources: add-ons, torrents, debrid services, Jellyfin and your files."
    static let copyright = "© 2026 BCYAYAY14"
}

/// Raised grey pill buttons, as the rest of Bluebox draws secondary actions
/// (`Palette.glassFill`), so the window stays black and grey.
private struct AboutButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Spacing.m)
            .frame(height: 28)
            .background(Capsule().fill(configuration.isPressed ? Palette.glassFillPressed
                                       : hovering ? Palette.elevated.opacity(0.8) : Palette.glassFill))
            .overlay(Capsule().strokeBorder(Palette.edge))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

// MARK: - Acknowledgements and Licence

/// A text bundled with the Mac app (project.yml copies both into its
/// resources): the third-party notices and Bluebox's own licence.
public enum AboutDocument: String, Codable, Hashable, Sendable {
    case acknowledgements, licence

    /// The window group that shows one (`BlueboxApp`).
    public static let windowID = "about-document"

    public var title: String {
        switch self {
        case .acknowledgements: "Acknowledgements"
        case .licence: "Licence"
        }
    }

    /// THIRD-PARTY-NOTICES.md and LICENSE, from the app bundle.
    var text: String {
        let (name, ext): (String, String?) = switch self {
        case .acknowledgements: ("THIRD-PARTY-NOTICES", "md")
        case .licence: ("LICENSE", nil)
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This build doesn't include the \(title.lowercased()) text."
        }
        return text
    }
}

/// Shows an `AboutDocument`: the notices' Markdown headings, paragraphs and
/// code blocks (the licence texts) as styled blocks; the licence as plain text.
public struct AboutDocumentView: View {
    let document: AboutDocument

    public init(document: AboutDocument) { self.document = document }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(Array(Self.blocks(document.text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(Palette.background, for: .window)
        .preferredColorScheme(.dark)
        .navigationTitle(document.title)
        .frame(minWidth: 420, minHeight: 320)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.weight(.bold) : .headline)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, level == 1 ? 0 : Spacing.s)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.body)
                .foregroundStyle(Palette.textSecondary)
                .tint(Palette.brandBright)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
        case .rule:
            Rectangle().fill(Palette.separator).frame(height: 1).padding(.vertical, Spacing.xs)
        }
    }

    enum Block: Equatable {
        case heading(Int, String), paragraph(String), code(String), rule
    }

    /// Splits Markdown into the few block kinds the notices use. Text with no
    /// Markdown (the licence) comes out as paragraphs, keeping its line breaks.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
            } else if code != nil {
                code?.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.allSatisfy({ $0 == "-" }) && line.count >= 3 {
                flush()
                blocks.append(.rule)
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Inline Markdown (code spans, links, emphasis), keeping line breaks.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
#endif
