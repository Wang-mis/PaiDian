import XCTest

/// Explicitly enabled captures of the installed app; does not create playlists or start playback.
@MainActor final class ReleaseScreenshotTests: XCTestCase {
    func testCaptureReleaseScreenshots() throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_RELEASE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("仅在 Screenshots Scheme 中获取发布截图")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["好"].waitForExistence(timeout: 2) {
            springboard.alerts.buttons["好"].tap(); app.activate()
        }
        XCTAssertTrue(app.buttons["createPlaylist"].waitForExistence(timeout: 30))
        capture("01-library")
        let miniPlayer = app.buttons["miniPlayer"]
        if miniPlayer.exists {
            miniPlayer.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
            capture("02-player")
            app.otherElements["playerViewport"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
            capture("03-lyrics")
            app.buttons["收起播放器"].tap()
        }
        app.buttons["音源管理"].tap()
        XCTAssertTrue(app.navigationBars["音源管理"].waitForExistence(timeout: 5))
        capture("04-sources")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
