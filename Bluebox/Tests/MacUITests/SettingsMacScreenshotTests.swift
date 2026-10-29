import XCTest

/// Walks every Settings page on the Mac and saves screenshots for design
/// review. Runs a copy of the app given by /tmp/bluebox-settings-shots/app-path
/// (re-signed with its own bundle ID, so a Bluebox you're using isn't touched).
/// Skipped unless that file exists.
@MainActor
final class SettingsMacScreenshotTests: XCTestCase {
    private let folder = "/tmp/bluebox-settings-shots"
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let pathFile = "\(folder)/app-path"
        guard let path = try? String(contentsOfFile: pathFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw XCTSkip("Screenshots only on request")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.activate()
    }

    override func tearDown() async throws { app?.terminate() }

    func testScreenshotEverySettingsPage() {
        sleep(3)
        app.typeKey(",", modifierFlags: .command)
        let first = app.buttons["settings.account"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        let pages = ["account", "profiles", "playback", "subtitles", "picture", "torrents", "sources", "catalog",
                     "downloads", "storage", "notifications", "advanced", "about"]
        for (i, page) in pages.enumerated() {
            let row = app.buttons["settings.\(page)"].firstMatch
            guard row.waitForExistence(timeout: 3) else { continue }
            row.click()
            sleep(2)
            save(String(format: "%02d-%@-a", i + 1, page))
            app.scrollViews.element(boundBy: app.scrollViews.count - 1).scroll(byDeltaX: 0, deltaY: -600)
            sleep(1)
            save(String(format: "%02d-%@-b", i + 1, page))
        }
        // Search: type, pick a hit, and catch the row it scrolls to.
        let field = app.textFields["settings.search"].firstMatch
        if field.waitForExistence(timeout: 2) {
            field.click()
            field.typeText("buffer")
            sleep(1)
            save("90-search-results")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buffer at Most")).firstMatch.click()
            usleep(1_300_000)
            save("91-search-reveal")
        }
    }

    private func save(_ name: String) {
        let window = app.windows.element(boundBy: 0)
        let data = window.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(folder)/mac-\(name).png"))
    }
}
