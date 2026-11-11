import XCTest

/// Not part of the e2e gate. A scripted walkthrough at human pace that CI records as a PR's demo video.
/// Alongside the actions it writes markers (captions, taps, stretches to fast-forward) as an attachment named
/// "markers"; demo/compose.py turns the recording plus those markers into the finished MP4.
///
/// When a PR changes what the app does, update this walkthrough so the demo shows the change.
final class DemoWalkthrough: XCTestCase {
    private var app: XCUIApplication!
    private var events: [[String: Any]] = []
    private let message = "Dear future me: this demo recorded itself."

    @MainActor
    func testRecordWalkthrough() throws {
        continueAfterFailure = false
        app = launchApp()

        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        pause(0.8)
        chapter(style: "title", kicker: "Notes to your future self", title: "Time Capsule",
                sub: "Write something today. The server keeps it sealed until it is time.")
        pause(3.4)

        // Write a note and seal it.
        chapter(title: "Write it. Pick when it opens.", sub: "Ten seconds, a minute, an hour, a day or a year.")
        pause(1.4)
        tap(field)
        pause(0.6)
        type(message, into: field)
        pause(0.9)
        tap(app.buttons["1m"])
        pause(0.7)
        tap(app.buttons["10s"])
        pause(1.0)
        tap(app.buttons["sealButton"])
        let row = app.buttons.matching(identifier: "capsuleRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        pause(1.6)

        // Try to open it early: the server says no.
        chapter(title: "Sealed means sealed.",
                sub: "Tap it early and the server refuses. Not even the app can read the message yet.",
                chip: "GET /capsules/:id  \u{2192}  423 Locked")
        pause(1.6)
        tap(row)
        XCTAssertTrue(app.staticTexts["lockedBanner"].waitForExistence(timeout: 5))
        pause(2.8)

        // Waiting out the seal is dull: the video fast-forwards it.
        let waitStart = Date()
        let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: row)
        wait(for: [ready], timeout: 30)
        fastForward(from: waitStart, factor: 5)
        pause(0.6)

        chapter(title: "When time is up, break the seal.",
                sub: "The wax cracks, and only now does the server hand over the message.",
                chip: "GET /capsules/:id  \u{2192}  200 OK")
        pause(1.4)
        tap(row)
        XCTAssertTrue(app.staticTexts["revealedMessage"].waitForExistence(timeout: 10))
        pause(4.0)

        // Quit and come back: the capsule is loaded from Postgres.
        chapter(title: "Still there after a relaunch.",
                sub: "Quit the app, open it again: the capsule comes back from Postgres, already opened.")
        pause(1.2)
        let relaunchStart = Date()
        app.terminate()
        app = launchApp()
        let opened = app.buttons.matching(NSPredicate(format: "identifier == 'capsuleRow' AND label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 20))
        fastForward(from: relaunchStart, factor: 4)
        pause(3.2)

        chapter(style: "end", title: "Time Capsule", sub: "SwiftUI app, Node API, Postgres. Recorded on a cloud Mac.")
        pause(3.4)
        events.append(["t": now(), "kind": "end"])
        attachMarkers()
    }

    // MARK: - Pacing and markers

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_URL"] = ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787"
        app.launch()
        return app
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func chapter(style: String = "step", kicker: String? = nil, title: String, sub: String? = nil, chip: String? = nil) {
        var e: [String: Any] = ["t": now(), "kind": "chapter", "style": style, "title": title]
        if let kicker { e["kicker"] = kicker }
        if let sub { e["sub"] = sub }
        if let chip { e["chip"] = chip }
        events.append(e)
    }

    /// Taps like a finger would, and records where, so the video can show a touch ripple.
    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "can't tap \(element)")
        let f = element.frame, screen = app.windows.firstMatch.frame
        events.append(["t": now(), "kind": "tap",
                       "x": (f.midX - screen.minX) / max(screen.width, 1),
                       "y": (f.midY - screen.minY) / max(screen.height, 1)])
        element.tap()
    }

    /// Types a few letters at a time with small pauses, so it reads like someone typing.
    @MainActor
    private func type(_ text: String, into element: XCUIElement) {
        var rng = SystemRandomNumberGenerator()
        var chunk = ""
        for ch in text {
            chunk.append(ch)
            if chunk.count >= 2 || ch == " " {
                element.typeText(chunk)
                chunk = ""
                pause(Double.random(in: 0.03...0.12, using: &rng))
            }
        }
        if !chunk.isEmpty { element.typeText(chunk) }
    }

    private func fastForward(from start: Date, factor: Double) {
        let until = now() - 0.25
        if until - start.timeIntervalSince1970 > 1.0 {
            events.append(["t": start.timeIntervalSince1970 + 0.3, "kind": "speed", "until": until, "factor": factor])
        }
    }

    private func attachMarkers() {
        let body: [String: Any] = ["events": events]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "markers"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
