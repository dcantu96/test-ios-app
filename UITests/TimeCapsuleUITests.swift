import XCTest

/// End-to-end: the real app, in the Simulator, talking to the real API and Postgres.
///
/// Nothing here races the clock: the "too early" check uses a capsule sealed for a year, so it can't open
/// however slow the CI machine is, and the 10-second capsule is sealed first so its countdown runs while the
/// other checks happen.
final class TimeCapsuleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSealKnockEarlyWaitThenReveal() throws {
        let tag = String(UUID().uuidString.prefix(6))
        let secret = "Dear future me, remember tonight (\(tag))"
        let letter = "Open this next year (\(tag))"
        app = launchApp()

        // 1. The compose card is up and the vault (API) is reachable.
        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "compose field never appeared")
        XCTAssertFalse(app.staticTexts["errorBanner"].exists, "app couldn't reach the API")
        snap("1 Launched")

        // 2. Seal a message for 10 seconds; its countdown runs during the next steps.
        seal(secret, for: "10s", field: field)
        let quick = rows.firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10), "sealed capsule never showed up")
        XCTAssertFalse(rowShowing(secret).exists, "a sealed capsule must not show its message")
        snap("2 Sealed for 10 seconds")

        // 3. Seal a letter for a year, and try to open it: the server refuses (HTTP 423) and the app says so.
        //    Knocking only ever happens on this capsule: it can't unlock during the test, however slow CI is.
        seal(letter, for: "1y", field: field)
        let yearLong = rows.firstMatch
        XCTAssertTrue(waitFor(rows, count: 2), "second capsule never showed up")
        XCTAssertEqual(yearLong.value as? String, "sealed")
        yearLong.tap()
        // The banner shows for 4 s: wait for the banner with the right text in one query, not exists-then-read.
        XCTAssertTrue(lockedBanner("Knock #1").waitForExistence(timeout: 10), "server didn't refuse an early open as knock #1")
        snap("3 Server refused to open the year-long capsule") // first: the banner only shows for 4 s
        XCTAssertFalse(rowShowing(letter).exists, "a refused capsule must not show its message")

        // 4. Knock again: the server counts it, and the sealed row says so.
        yearLong.tap()
        XCTAssertTrue(lockedBanner("Knock #2").waitForExistence(timeout: 10), "the second knock wasn't counted")
        XCTAssertTrue(rowShowing("Knocked 2 times").waitForExistence(timeout: 10), "the sealed row doesn't show the knocks")
        snap("4 Second knock counted")

        // 5. The 10-second capsule (now second in the list) unlocks; open it and read it. Nobody knocked on it.
        let ten = rows.element(boundBy: 1)
        let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: ten)
        wait(for: [ready], timeout: 30)
        snap("5 Ready to open")
        ten.tap()
        let revealed = app.staticTexts["revealedMessage"]
        XCTAssertTrue(revealed.waitForExistence(timeout: 10), "message was never revealed")
        XCTAssertEqual(revealed.label, secret)
        XCTAssertEqual(app.staticTexts["knockVerdict"].label, "No knocks. You waited.")
        sleep(1) // let the crack-open animation settle for the screenshot
        snap("6 Seal cracked, message revealed")

        // 6. Kill and relaunch: both capsules come back from Postgres, the opened one with its message,
        //    the year-long one still sealed, still without its message, and still counting its two knocks.
        app.terminate()
        app = launchApp()
        XCTAssertTrue(rowShowing(secret).waitForExistence(timeout: 20), "opened capsule didn't survive a relaunch")
        XCTAssertTrue(waitFor(rows, count: 2), "a capsule went missing after the relaunch")
        XCTAssertEqual(rows.firstMatch.value as? String, "sealed")
        XCTAssertTrue(rowShowing("Knocked 2 times").waitForExistence(timeout: 10), "the knocks weren't kept in Postgres")
        XCTAssertFalse(rowShowing(letter).exists, "the year-long capsule leaked its message after a relaunch")
        snap("7 After relaunch, loaded from Postgres")
    }

    // MARK: - Helpers

    @MainActor
    private var rows: XCUIElementQuery { app.buttons.matching(identifier: "capsuleRow") }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_URL"] = ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787"
        app.launch()
        return app
    }

    @MainActor
    private func seal(_ text: String, for duration: String, field: XCUIElement) {
        field.tap()
        field.typeText(text)
        app.buttons[duration].tap()
        app.buttons["sealButton"].tap()
    }

    @MainActor
    private func waitFor(_ query: XCUIElementQuery, count: Int, timeout: TimeInterval = 10) -> Bool {
        let e = expectation(for: NSPredicate(format: "count >= %d", count), evaluatedWith: query)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    @MainActor
    private func lockedBanner(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'lockedBanner' AND label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func rowShowing(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'capsuleRow' AND label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
