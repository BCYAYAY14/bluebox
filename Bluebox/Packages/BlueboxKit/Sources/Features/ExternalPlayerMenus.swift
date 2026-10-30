import DesignSystem
import SwiftUI

// Open In…: the installed external players, in the player, on the title
// page, in the release picker and in Downloads.

extension ExternalPlayer {
    var symbol: String { self == .shareSheet ? "square.and.arrow.up" : "arrow.up.forward.app" }

    /// Said wherever an app can be picked: none of them reports back.
    static let progressNote = "Progress isn't tracked in other apps."
}

/// "Open In" for a Bluebox menu: one item per installed app, then the note
/// that progress isn't tracked there. Nothing when none is installed.
struct ExternalPlayerMenuSection: BlueboxMenuElement {
    let players: [ExternalPlayer]
    let open: @MainActor (ExternalPlayer) -> Void

    var entries: [BlueboxMenuEntry] {
        guard !players.isEmpty else { return [] }
        return [.section("Open In")]
            + players.flatMap { player in BlueboxMenuButton(player.name, systemImage: player.symbol) { open(player) }.entries }
            + [.note(ExternalPlayer.progressNote)]
    }
}

/// "Open In" as a submenu of a system context menu.
struct ExternalPlayerContextMenu: View {
    let players: [ExternalPlayer]
    let open: @MainActor (ExternalPlayer) -> Void

    var body: some View {
        if !players.isEmpty {
            Menu {
                ForEach(players) { player in
                    Button { open(player) } label: { Label(player.name, systemImage: player.symbol) }
                }
                Section(ExternalPlayer.progressNote) {}
            } label: {
                Label("Open In", systemImage: "arrow.up.forward.app")
            }
        }
    }
}
