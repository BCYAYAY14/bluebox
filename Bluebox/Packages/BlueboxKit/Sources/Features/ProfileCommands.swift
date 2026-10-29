#if os(macOS)
import Domain
import SwiftUI

/// The Mac's Profiles menu: every profile with a check on the current one and
/// ⌃⌘1–4 on the first four, then Who's Watching and Manage Profiles. The
/// menu bar is where the shortcuts can be found (rule 20).
public struct ProfileCommands: Commands {
    let model: AppModel?
    @Environment(\.openSettings) private var openSettings
    @AppStorage("bluebox.settingsPage") private var settingsPage: SettingsPage = .account

    public init(model: AppModel?) { self.model = model }

    public var body: some Commands {
        CommandMenu("Profiles") {
            if let model {
                let profiles = model.profiles.filter { !$0.isRemoved }
                ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                    let toggle = Toggle(isOn: Binding(get: { p.id == model.currentProfileID },
                                                      set: { on in if on { model.requestProfileSwitch(to: p.id) } })) {
                        Text(model.isLocked(p.id) ? "\(p.name) (Locked)" : p.name)
                    }
                    if i < ProfileShortcuts.count {
                        toggle.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.control, .command])
                    } else {
                        toggle
                    }
                }
                Divider()
                Button("Who's Watching?") { model.profilePickerRequest += 1 }
                    .disabled(profiles.count < 2)
                Button("Manage Profiles…") {
                    settingsPage = .profiles
                    openSettings()
                }
                if model.featureSwitches.statistics {
                    Button("My Bluebox…") {
                        settingsPage = .statistics
                        openSettings()
                    }
                }
            } else {
                Button("Who's Watching?") {}.disabled(true)
            }
        }
    }
}
#endif
