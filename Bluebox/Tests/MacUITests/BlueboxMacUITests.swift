import XCTest

/// macOS smoke tests against the demo model (`-ui-testing`). Navigation is the
/// top bar; Settings is its own window (⌘,).
@MainActor
final class BlueboxMacUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.activate()
    }

    override func tearDown() async throws { app.terminate() }

    /// Switches tabs with their keyboard shortcuts. The top bar sits in the
    /// title bar region, where XCUITest's synthesized clicks don't reach the
    /// buttons (a real click does), so the tests use the shortcuts instead.
    private func open(_ tab: String) {
        XCTAssertTrue(app.buttons["topNav.\(tab)"].firstMatch.waitForExistence(timeout: 3), "No top bar item for \(tab)")
        let keys = ["Home": "1", "TV Shows": "2", "Movies": "3", "New & Hot": "4", "My List": "5", "Downloads": "6", "Search": "f"]
        guard let key = keys[tab] else { return XCTFail("No shortcut for \(tab)") }
        app.typeKey(key, modifierFlags: .command)
    }

    private func openSettings(_ page: String) {
        app.typeKey(",", modifierFlags: .command)
        let row = app.outlines.staticTexts[page].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No settings page \(page)")
        row.click()
    }

    /// Home's hero. Row titles are headings, and lower rows are lazy, only
    /// existing once scrolled near.
    private func waitForHome() -> Bool {
        app.buttons["More Info"].firstMatch.waitForExistence(timeout: 10)
    }

    private func heading(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND elementType != %d",
                                                             title, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    func testLaunchShowsHomeRows() {
        XCTAssertTrue(waitForHome())
        XCTAssertTrue(heading("Continue Watching").exists)
        let trending = heading("Trending Now")
        for _ in 0..<8 where !trending.exists { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(trending.waitForExistence(timeout: 3))
    }

    func testTopNavigation() {
        XCTAssertTrue(waitForHome())
        open("Downloads")
        XCTAssertTrue(heading("Downloads").waitForExistence(timeout: 5))
        open("My List")
        open("Home")
        XCTAssertTrue(waitForHome())
    }

    func testSearchOpensDetail() {
        XCTAssertTrue(waitForHome())
        open("Search")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("steel")
        let result = app.buttons["Tears of Steel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
    }

    func testProfilesCanBeAddedAndSwitched() {
        XCTAssertTrue(waitForHome())
        openSettings("Profiles")
        let add = app.buttons["addProfileButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let name = app.textFields["profileNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Kids")
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Kids"].waitForExistence(timeout: 5))
    }
}
