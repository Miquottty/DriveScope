import XCTest

/// Two end-to-end flows on the simulator (CLAUDE.md test budget). Scripted drives need no permissions.
final class DriveScopeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func app(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITest", "-DriveSim", "akagi", "-DriveSimSpeed", "20", "-appLanguage", "en"] + extra
        return app
    }

    /// START → record → MARK → hold STOP → Session Detail → Replay → play.
    @MainActor
    func testRecordStopReplay() throws {
        let app = app()
        app.launch()
        app.buttons["startButton"].tap()

        XCTAssertTrue(app.buttons["stopButton"].waitForExistence(timeout: 10))
        sleep(4)
        app.buttons["markButton"].tap()
        sleep(2)
        app.buttons["stopButton"].press(forDuration: 1.5)

        let replay = app.buttons["replayButton"]
        XCTAssertTrue(replay.waitForExistence(timeout: 15), "Session Detail should open after STOP")
        replay.tap()
        let play = app.buttons["replayPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Replay should open")
        play.tap()
        sleep(2)
        XCTAssertTrue(app.sliders["replayScrubber"].exists)

        // Back to Detail → Export a GPX file.
        app.buttons["replayPlayButton"].tap()
        app.buttons["Back"].tap()
        let export = app.buttons["exportButton"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        let gpx = app.buttons["exportGPX"]
        XCTAssertTrue(gpx.waitForExistence(timeout: 10))
        gpx.tap()
        XCTAssertTrue(app.buttons["shareGPX"].waitForExistence(timeout: 20), "GPX export should finish")
    }

    /// A recording killed mid-drive is offered for recovery on the next launch and opens as RECOVERED.
    @MainActor
    func testKilledRecordingIsRecovered() throws {
        let first = app(["-UITestKeepData", "-UITestFresh"])
        first.launch()
        first.buttons["startButton"].tap()
        XCTAssertTrue(first.buttons["stopButton"].waitForExistence(timeout: 10))
        sleep(5) // > 2 s flush interval
        first.terminate()

        let second = app(["-UITestKeepData"])
        second.launch()
        let recover = second.buttons["recoverButton"]
        XCTAssertTrue(recover.waitForExistence(timeout: 10), "Recovery sheet should appear")
        recover.tap()
        XCTAssertTrue(second.staticTexts["RECOVERED"].waitForExistence(timeout: 10))
    }
}
