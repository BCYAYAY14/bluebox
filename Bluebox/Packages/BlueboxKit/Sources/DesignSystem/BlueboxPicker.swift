import SwiftUI

/// One choice in a `BlueboxPicker`.
public struct BlueboxPickerOption<Value: Hashable> {
    public var value: Value
    public var title: String
    public var systemImage: String?
    /// Draws the option as a profile-style badge in this colour.
    public var color: Color?

    public init(_ title: String, value: Value, systemImage: String? = nil, color: Color? = nil) {
        self.title = title; self.value = value; self.systemImage = systemImage; self.color = color
    }
}

/// A form row that picks one value from a Bluebox menu: the title leading,
/// the current choice and an up-down chevron trailing. Use it where a `Picker`
/// would show as a system pop-up menu.
public struct BlueboxPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let groups: [[BlueboxPickerOption<Value>]]
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, selection: Binding<Value>, options: [BlueboxPickerOption<Value>]) {
        self.init(title, selection: selection, groups: [options])
    }

    /// Options in groups, with a separator between groups ("Off" above the languages, say).
    public init(_ title: String, selection: Binding<Value>, groups: [[BlueboxPickerOption<Value>]]) {
        self.title = title; _selection = selection; self.groups = groups
    }

    private var current: BlueboxPickerOption<Value>? {
        groups.lazy.flatMap { $0 }.first { $0.value == selection }
    }

    public var body: some View {
        LabeledContent {
            BlueboxMenu(title) {
                for group in groups {
                    BlueboxMenuSection {
                        for option in group { item(option) }
                    }
                }
            } label: {
                valueLabel
            }
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(current?.title ?? "")
        } label: {
            Text(title)
        }
    }

    private var valueLabel: some View {
        HStack(spacing: 6) {
            if let current {
                if let color = current.color {
                    Circle().fill(color).frame(width: 12, height: 12)
                } else if let symbol = current.systemImage {
                    Image(systemName: symbol)
                }
                Text(current.title)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
        }
        .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(isEnabled ? 0.1 : 0.05)))
        .contentShape(Rectangle())
    }

    private func item(_ option: BlueboxPickerOption<Value>) -> BlueboxMenuButton {
        let binding = $selection
        let value = option.value
        let checked = value == selection
        if let color = option.color {
            return BlueboxMenuButton(option.title, avatar: option.systemImage ?? "circle.fill", color: color, checked: checked) {
                binding.wrappedValue = value
            }
        }
        return BlueboxMenuButton(option.title, systemImage: option.systemImage, checked: checked) { binding.wrappedValue = value }
    }
}
