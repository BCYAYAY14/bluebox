@testable import Addons
import Domain
import Foundation
import Testing

/// Asks the real presets about openly licensed films. Opt in:
///
///     BLUEBOX_LIVE_ADDONS=1 swift test --filter LiveAddonTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LIVE_ADDONS"] == "1"))
struct LiveAddonTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["tt1727587", "tt2285752", "tt1254207"])
    func presetsFindOpenFilms(_ imdb: String) async throws {
        var settings = AddonSettings()
        settings.addons = [.preset(.torrentio), .preset(.stremthru), .preset(.comet)]
        let source = StremioSource(settings: settings, debridKey: "", imdbID: { _ in imdb }, choices: MemoryShowChoiceStore())
        let started = Date()
        let ranked = try await source.releases(for: .movie(tmdbID: 1))
        let elapsed = Date().timeIntervalSince(started)
        print("LIVE \(imdb): \(ranked.count) releases in \(String(format: "%.2f", elapsed)) s")
        for r in ranked.prefix(5) {
            print("LIVE   \(r.resolution ?? "?") \(r.sizeText ?? "?") 👤\(r.seeders.map(String.init) ?? "–") "
                  + "[\(r.addonName ?? "?")\(r.alsoFrom.isEmpty ? "" : " +" + r.alsoFrom.joined(separator: ","))] "
                  + "\(r.info.tags.joined(separator: " ")) group=\(r.group ?? "-") \(r.fileName)")
        }
        let health = await source.addonHealth()
        for (id, h) in health.sorted(by: { $0.key < $1.key }) { print("LIVE   health \(id): \(h.summary())") }
        #expect(!ranked.isEmpty)
        #expect(Set(ranked.map(\.id)).count == ranked.count)
    }
}
