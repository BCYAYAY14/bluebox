import XCTest

/// Walks every Settings page and saves screenshots for design review. Skipped
/// unless /tmp/bluebox-settings-shots exists (create it to run this).
@MainActor
final class SettingsScreenshotTests: XCTestCase {
    private let folder = "/tmp/bluebox-settings-shots"
    private var app: XCUIApplication!
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder), "Screenshots only on request")
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
    }

    func testScreenshotEverySettingsPage() {
        app.launch()
        openSettings()
        save("00-root")
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let pages = ["account", "profiles", "playback", "subtitles", "picture", "torrents", "sources", "catalog",
                     "mobileData", "downloads", "storage", "notifications", "advanced", "about"]
        for (i, page) in pages.enumerated() {
            let row = app.buttons["settings.\(page)"].firstMatch
            if !isPad { scrollTo(row) }
            guard row.waitForExistence(timeout: 3) else { continue }
            row.tap()
            sleep(2)
            save(String(format: "%02d-%@-a", i + 1, page))
            if page == "account", !isPad {
                // Signed out on iPhone: a full-screen cover.
                let close = app.buttons["Close"].firstMatch
                if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }
                continue
            }
            app.swipeUp(velocity: .slow)
            sleep(1)
            save(String(format: "%02d-%@-b", i + 1, page))
            if !isPad {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                sleep(1)
            }
        }
    }

    func testSearchScrollsToTheSetting() {
        app.launch()
        openSettings()
        let field = app.textFields["settings.search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("countdown")
        sleep(1)
        save("90-search-results")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Countdown'")).firstMatch.tap()
        usleep(900_000)
        save("91-search-reveal")
        usleep(900_000)
        save("92-search-reveal-later")
    }

    private func openSettings() {
        let profile = app.buttons["profileMenu"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings")).firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.profiles"].waitForExistence(timeout: 5))
        sleep(1)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeDown() }
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(folder)/\(device)-\(name).png"))
    }
}
