import XCTest

final class LocalFileDietUITests: XCTestCase {
    @MainActor
    func testHomeScreenLoads() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Import from Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Local File Diet"].exists)
    }
}
