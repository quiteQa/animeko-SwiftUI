import XCTest

final class NativeInterfaceTests: XCTestCase {
    @MainActor
    func testMainTabsAndSearchField() {
        let app = launchNativeApp()
        XCTAssertTrue(app.tabBars.buttons["Explore"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.navigationBars["Collection"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSheetDismissal() {
        let app = launchNativeApp()
        let explore = app.tabBars.buttons["Explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()

        let settings = app.buttons["native.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlaybackAndMediaSourcesFromSettings() {
        let app = launchNativeApp()
        let settings = app.buttons["native.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let playback = app.descendants(matching: .any)["native.settings.playback"].firstMatch
        reveal(playback, in: app)
        playback.tap()
        let playbackBar = app.navigationBars["Playback"]
        XCTAssertTrue(playbackBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Automatically Play Next Episode"].waitForExistence(timeout: 5))
        playbackBar.buttons.firstMatch.tap()

        let sources = app.descendants(matching: .any)["native.settings.sources"].firstMatch
        reveal(sources, in: app)
        sources.tap()
        XCTAssertTrue(app.navigationBars["Media Sources"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCustomSourceDraftCanBeDiscarded() {
        let app = launchNativeApp()
        let settings = app.buttons["native.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let sources = app.descendants(matching: .any)["native.settings.sources"].firstMatch
        reveal(sources, in: app)
        sources.tap()
        let actions = app.buttons["native.sources.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while !actions.isEnabled, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(actions.isEnabled)
        actions.tap()
        app.buttons["Add Custom Source"].tap()
        app.buttons["RSS"].tap()

        let editor = app.navigationBars["RSS"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let save = editor.buttons["native.sourceEditor.save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)

        let name = app.textFields["native.sourceEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" draft")
        editor.buttons["Cancel"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.navigationBars["Media Sources"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAiringScheduleNavigationAndAccountPresentation() {
        let app = launchNativeApp()
        let explore = app.tabBars.buttons["Explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()

        let schedule = app.buttons["Airing Schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        let scheduleBar = app.navigationBars["Airing Schedule"]
        XCTAssertTrue(scheduleBar.waitForExistence(timeout: 5))
        scheduleBar.buttons.firstMatch.tap()

        app.buttons["native.account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNotificationsAndHistoryFromAccount() {
        let app = launchNativeApp()
        let account = app.buttons["native.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        account.tap()

        app.buttons["native.account.notifications"].tap()
        let notifications = app.navigationBars["Notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["native.notifications.announcements"].firstMatch.exists)
        notifications.buttons.firstMatch.tap()

        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        app.buttons["native.account.history"].tap()
        let history = app.navigationBars["Playback History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.buttons.firstMatch.tap()
    }

    @MainActor
    private func launchNativeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AnimekoNativeUI", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
