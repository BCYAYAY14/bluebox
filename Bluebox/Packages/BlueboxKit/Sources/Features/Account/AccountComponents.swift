import DesignSystem
import SwiftUI
import Sync

/// Text buttons in a row that wrap onto more lines when they don't fit.
struct WrappingButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        AccountFlowLayout(spacing: Spacing.l) { content }
    }
}

/// Lays subviews out left to right at their ideal size, starting a new line
/// when the next one doesn't fit.
struct AccountFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                let w = min(size.width, bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(width: w, height: size.height))
                x += w + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// One numbered step in the setup guide: a number, a title, a line, links.
struct AccountStep<Links: View>: View {
    let number: Int
    let title: String
    let detail: Text?
    var done = false
    /// In progress: a spinner instead of the number.
    var active = false
    var steps: AccountSubSteps? = nil
    @ViewBuilder let links: Links

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.headline.weight(.bold))
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(number)").font(.title2.weight(.heavy)).monospacedDigit()
                }
            }
            .foregroundStyle(done ? Palette.brand : Palette.textTertiary)
            .frame(width: 22, alignment: .leading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(ui: title).font(.headline.weight(.bold))
                if let detail {
                    detail.font(.subheadline).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let steps { steps }
                WrappingButtons { links }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : active ? ", in progress" : "")")
    }
}

extension AccountStep where Links == EmptyView {
    init(number: Int, title: String, detail: Text?, done: Bool = false, active: Bool = false, steps: AccountSubSteps? = nil) {
        self.init(number: number, title: title, detail: detail, done: done, active: active, steps: steps) { EmptyView() }
    }
}

/// The exact clicks inside a setup step: "1. Open …", "2. Paste …", in small
/// grey type under the step's line. Accepts Markdown (bold for buttons and
/// menus, `code` for values to type).
struct AccountSubSteps: View {
    let items: [LocalizedStringKey]
    init(_ items: LocalizedStringKey...) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(Palette.textTertiary)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.textSecondary)
        .padding(.top, 2)
    }
}

/// A warning box for the service-role key: red, impossible to miss.
struct AccountDangerBox: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(AccountTheme.error).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .padding(Spacing.m)
        .background(AccountTheme.error.opacity(0.14), in: RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous)
            .strokeBorder(AccountTheme.error.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A small spinner and a line of grey text.
struct AccountWorkingText: View {
    let text: String
    var body: some View {
        HStack(spacing: Spacing.s) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(Palette.textSecondary)
    }
}

/// Fixes for "run setup.sql": copy it, open the SQL Editor.
struct SetupSQLActions: View {
    let ref: String?
    var body: some View {
        CopyButton("Copy setup.sql", text: SupabaseSetupFiles.setupSQL)
        DashboardLink("Open SQL Editor", SupabaseDashboard.url(.sqlEditor, ref: ref))
    }
}

