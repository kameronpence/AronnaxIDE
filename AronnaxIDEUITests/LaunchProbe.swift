import XCTest

final class CopyShortcutTests: XCTestCase {
    /// Confirms the app launches cleanly WITH the copy-scrollback change and that pressing
    /// Cmd-Shift-C in the terminal is handled without crashing or backgrounding the app.
    func testCmdShiftCIsStable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app did not launch")

        // Give the workspace a moment to build its terminal pane.
        sleep(3)
        let win = app.windows.firstMatch
        XCTAssertTrue(win.waitForExistence(timeout: 10), "no window")

        // Focus the terminal area and fire Cmd-Shift-C a few times.
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.6)).click()
        usleep(400_000)
        for _ in 0..<3 {
            app.typeKey("c", modifierFlags: [.command, .shift])
            usleep(300_000)
        }

        // The app must still be alive and frontmost — the shortcut path didn't crash/hang.
        XCTAssertEqual(app.state, .runningForeground, "app not stable after Cmd-Shift-C")
    }
}
