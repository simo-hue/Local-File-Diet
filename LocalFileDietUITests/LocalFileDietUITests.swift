import XCTest

final class LocalFileDietUITests: XCTestCase {
    func testHomeScreenLoads() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Local File Diet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import from Files"].exists)
    }
}
