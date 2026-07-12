import XCTest

final class StabilityTests: XCTestCase {
    /// Regression guard: the app launches cleanly with the drag-select build and stays
    /// stable when Cmd-C is pressed in the terminal (the copy path doesn't crash/hang).
    func testLaunchesAndCmdCStable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app did not launch")
        sleep(3)
        let win = app.windows.firstMatch
        XCTAssertTrue(win.waitForExistence(timeout: 10), "no window")
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.6)).click()
        usleep(400_000)
        app.typeKey("c", modifierFlags: [.command])
        usleep(500_000)
        XCTAssertEqual(app.state, .runningForeground, "app not stable after Cmd-C")
    }
}
