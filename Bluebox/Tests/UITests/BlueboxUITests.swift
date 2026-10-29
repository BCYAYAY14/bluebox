import XCTest

/// Runs against the deterministic demo model (`-ui-testing`): sample catalog,
/// in-memory library, seeded progress. No network credentials required.
@MainActor
final class BlueboxUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
    }

    func testLaunchShowsHomeRows() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Trending Now"].exists)
    }

    func testTabNavigation() {
        app.launch()
        for tab in ["Search", "My Library", "Downloads", "Home"] {
            go(tab)
        }
        XCTAssertTrue(app.staticTexts["Trending Now"].waitForExistence(timeout: 5))
    }

    func testSearchFindsTitleAndOpensDetail() {
        app.launch()
        go("Search")
        let field = searchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("steel")
        let result = app.buttons["Tears of Steel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
    }

    /// Choosing Search again from a title opened from the results goes back to
    /// the results, with the query kept and the field focused.
    func testSearchAgainReturnsFromATitleToTheField() {
        app.launch()
        go("Search")
        let field = searchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("steel")
        let result = app.buttons["Tears of Steel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
        go("Search")
        XCTAssertTrue(app.buttons["Tears of Steel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["playButton"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "The search field isn't focused")
    }

    func testSearchEmptyState() {
        app.launch()
        go("Search")
        let field = searchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zzzzqqq")
        XCTAssertTrue(app.staticTexts["No results for “zzzzqqq”"].waitForExistence(timeout: 5))
    }

    func testWatchlistToggleAppearsInLibrary() {
        app.launch()
        go("Search")
        let field = searchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Small Hours")
        app.buttons["Small Hours"].firstMatch.tap()
        let list = app.buttons["watchlistButton"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()
        go("My Library")
        XCTAssertTrue(app.buttons["Small Hours"].waitForExistence(timeout: 5))
    }

    func testUnavailableTitleExplainsWhy() {
        app.launch()
        go("Search")
        let field = searchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Velocity")
        app.buttons["Velocity Ward"].firstMatch.tap()
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        // Availability resolves asynchronously; poll until the button settles disabled.
        let deadline = Date().addingTimeInterval(5)
        while play.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(play.isEnabled)
        XCTAssertTrue(app.staticTexts["Unavailable"].exists || app.buttons["playButton"].label.contains("Unavailable"))
    }

    func testEmptyLibraryStates() {
        app.launchArguments.append("-empty-library")
        app.launch()
        go("My Library")
        XCTAssertTrue(app.staticTexts["Your list is empty"].waitForExistence(timeout: 5))
    }

    func testSettingsShowsSourcesAndAttribution() {
        app.launch()
        openSettings()
        app.buttons["settings.sources"].tap()
        XCTAssertTrue(app.staticTexts["Open Movies"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollTo(app.buttons["settings.about"]))
        app.buttons["settings.about"].tap()
        XCTAssertTrue(scrollTo(app.staticTexts["This product uses the TMDB API but is not endorsed or certified by TMDB."]))
    }

    /// Settings opens from the profile menu (top right of Home).
    private func openSettings() {
        let profile = app.buttons["profileMenu"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings")).firstMatch.tap()  // "Settings" on iOS
        XCTAssertTrue(app.buttons["settings.profiles"].waitForExistence(timeout: 5))
    }

    /// Settings is a lazy form: rows exist only once scrolled near.
    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 15) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 2)
    }

    /// iPad only: the top bar shows the library tabs, a Sources menu and the profile menu.
    func testIPadTopNav() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Top bar is iPad and Mac only")
        app.launch()
        XCTAssertTrue(app.staticTexts["Trending Now"].waitForExistence(timeout: 10))
        for id in ["topNav.My List", "topNav.New & Hot", "topNav.Downloads", "topNav.Search", "profileMenu"] {
            XCTAssertTrue(app.buttons[id].firstMatch.waitForExistence(timeout: 3), "\(id) missing")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ipad-topnav"; shot.lifetime = .keepAlways
        add(shot)
        openSource("Open Movies")
        XCTAssertTrue(app.staticTexts["Tears of Steel"].waitForExistence(timeout: 5))
        let shot2 = XCTAttachment(screenshot: app.screenshot())
        shot2.name = "ipad-source"; shot2.lifetime = .keepAlways
        add(shot2)
    }

    /// iPad only: open a film, open the Tools card and its Picture page, and capture them.
    func testIPadPlayerTools() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Screenshot test for iPad")
        app.launch()
        XCTAssertTrue(app.staticTexts["Trending Now"].waitForExistence(timeout: 10))
        openSource("Open Movies")
        let play = app.buttons["Play Sintel"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let tools = app.buttons["playerToolsButton"]
        if !tools.waitForExistence(timeout: 8) { app.tap() }
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolsPanel"].firstMatch.waitForExistence(timeout: 5))
        for name in ["Tools", "Picture"] {
            let tile = app.buttons[name].firstMatch
            if name != "Tools", tile.exists { tile.tap() }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "player-\(name)"; shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func openSource(_ name: String) {
        app.buttons["topNavSources"].firstMatch.tap()
        app.buttons[name].firstMatch.tap()
    }

    /// A tab on iPhone; the matching top bar item on iPad.
    private func go(_ tab: String) {
        let bar = app.tabBars.buttons[tab]
        if bar.waitForExistence(timeout: 2) { bar.tap(); return }
        let top = tab == "My Library" ? "My List" : tab
        let item = app.buttons["topNav.\(top)"].firstMatch
        if top == "Home" && !item.exists { app.buttons["Bluebox, Home"].firstMatch.tap(); return }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "No navigation item for \(tab)")
        item.tap()
    }

    /// The system search field on iPhone; the page's own field under the top bar.
    private func searchField() -> XCUIElement {
        app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields["searchField"].firstMatch
    }
}
