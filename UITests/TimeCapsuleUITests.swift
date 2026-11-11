import XCTest

/// End-to-end: the real app, in the Simulator, talking to the real API and Postgres.
final class TimeCapsuleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSealRefuseEarlyOpenWaitThenReveal() throws {
        let secret = "Dear future me, remember tonight (\(UUID().uuidString.prefix(6)))"
        app = launchApp()

        // 1. The compose card is up and the vault (API) is reachable.
        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "compose field never appeared")
        XCTAssertFalse(app.staticTexts["errorBanner"].exists, "app couldn't reach the API")
        snap("1 Launched")

        // 2. Write a message and seal it for 10 seconds.
        field.tap()
        field.typeText(secret)
        app.buttons["10s"].tap()
        snap("2 Message written")
        app.buttons["sealButton"].tap()

        // 3. The newest capsule is sealed and its message is nowhere on screen.
        let row = app.buttons.matching(identifier: "capsuleRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sealed capsule never showed up")
        XCTAssertEqual(row.value as? String, "sealed")
        XCTAssertFalse(rowShowing(secret).exists, "a sealed capsule must not show its message")
        snap("3 Sealed with countdown")

        // 4. Opening early: the server refuses (HTTP 423) and the app says so.
        row.tap()
        XCTAssertTrue(app.staticTexts["lockedBanner"].waitForExistence(timeout: 5), "server didn't refuse an early open")
        snap("4 Server refused early open")

        // 5. Wait for the seal time to pass.
        let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: row)
        wait(for: [ready], timeout: 30)
        snap("5 Ready to open")

        // 6. Open it: the seal cracks and the server reveals the message.
        row.tap()
        let revealed = app.staticTexts["revealedMessage"]
        XCTAssertTrue(revealed.waitForExistence(timeout: 10), "message was never revealed")
        XCTAssertEqual(revealed.label, secret)
        sleep(1) // let the crack-open animation settle for the screenshot
        snap("6 Seal cracked, message revealed")

        // 7. Kill and relaunch: the opened capsule comes back from Postgres.
        app.terminate()
        app = launchApp()
        XCTAssertTrue(rowShowing(secret).waitForExistence(timeout: 20), "opened capsule didn't survive a relaunch")
        snap("7 After relaunch, loaded from Postgres")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_URL"] = ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787"
        app.launch()
        return app
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
