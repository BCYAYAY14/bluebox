import DesignSystem
import SwiftUI

/// Settings › Notifications: new-episode alerts and the global auto-download
/// default. Per-show overrides live on title pages.
struct NotificationsSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsForm(.notifications) {
            Section {
                Toggle("New Episodes", isOn: binding(\.notify))
                    .settingsRow("New Episodes")
                Toggle("Download New Episodes Automatically", isOn: binding(\.autoDownloadByDefault))
                    .settingsRow("Download New Episodes Automatically")
            } header: {
                Text("New Episodes")
            } footer: {
                Text("For shows in My List or that you're watching. Turn either on or off for one show from its page.")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NewEpisodeSettings, Bool>) -> Binding<Bool> {
        Binding { app.newEpisodeSettings[keyPath: keyPath] } set: { value in
            var s = app.newEpisodeSettings
            s[keyPath: keyPath] = value
            app.newEpisodeSettings = s
        }
    }
}
