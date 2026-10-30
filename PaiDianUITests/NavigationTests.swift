import XCTest

final class NavigationTests: XCTestCase {
    func testCreatePlaylistAndNavigate() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["createPlaylist"].waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["mineTab"].exists)
        app.buttons["createPlaylist"].tap()
        let input = app.alerts.textFields.firstMatch; XCTAssertTrue(input.waitForExistence(timeout:3)); input.tap(); input.typeText("UI 测试歌单"); app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.staticTexts["UI 测试歌单"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["歌单还是空的"].exists)
    }
    func testNoSourceSearchState() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let search = app.buttons["搜索"].firstMatch; XCTAssertTrue(search.waitForExistence(timeout:15)); search.tap()
        XCTAssertTrue(app.staticTexts["尚无可用音源"].waitForExistence(timeout:5))
    }
}
