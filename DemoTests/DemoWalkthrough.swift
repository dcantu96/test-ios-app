import XCTest

/// Not part of the e2e gate. A scripted walkthrough that CI records as a PR's demo video.
/// Alongside the actions it writes markers (captions, taps, typing, deliberate pauses, fast-forwards, cuts) as an
/// attachment named "markers"; demo/compose.py turns the recording plus those markers into the finished MP4, and
/// demo/review.py checks the result. Before changing this file, read "Writing the walkthrough" in CLAUDE.md.
///
/// Pacing: only pause() sets the pace. XCUITest's own slowness (finding elements, waiting for the app to idle) is
/// trimmed out by compose.py, so a stretch is kept only if it's a pause(), a fastForward() or the screen is moving.
final class DemoWalkthrough: XCTestCase {
    private var app: XCUIApplication!
    private var events: [[String: Any]] = []
    private var shots = 0
    private let letter = "Open this next year."
    private let note = "Dear future me: you made it."

    @MainActor
    func testRecordWalkthrough() throws {
        continueAfterFailure = false
        app = launchApp()

        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let rows = app.buttons.matching(identifier: "capsuleRow")
        pause(0.6)
        chapter(style: "title", kicker: "Notes to your future self", title: "Time Capsule",
                sub: "Write something today. The server keeps it sealed until it's time.")
        pause(4.2)

        // 1. Write a letter and seal it for a year.
        chapter(title: "Write it. Pick when it opens.", sub: "Ten seconds, a minute, an hour, a day or a year.")
        pause(1.2)
        tap(field)
        pause(0.4)
        type(letter, into: field)
        pause(0.7)
        tap(app.buttons["1y"])
        pause(0.8)
        tap(app.buttons["sealButton"])
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        pause(1.4)

        // 2. Try to open it now: the server refuses.
        chapter(title: "Sealed means sealed.",
                sub: "Tap it early and the server refuses. Not even the app can read it yet.",
                chip: "GET /capsules/:id  \u{2192}  423 Locked")
        pause(1.8)
        tap(rows.firstMatch)
        XCTAssertTrue(app.staticTexts["lockedBanner"].waitForExistence(timeout: 10))
        pause(3.0)

        // 3. A note for ten seconds: watch it count down (8x), then break the seal.
        chapter(title: "When time is up, break the seal.",
                sub: "This one opens in ten seconds. Only then does the server hand it over.",
                chip: "GET /capsules/:id  \u{2192}  200 OK")
        pause(1.2)
        tap(field)
        pause(0.4)
        type(note, into: field)
        pause(0.6)
        tap(app.buttons["10s"])
        pause(0.6)
        tap(app.buttons["sealButton"])
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 10))
        let fresh = rows.firstMatch  // newest first
        pause(1.0)
        let waitStart = Date()
        let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: fresh)
        wait(for: [ready], timeout: 30)
        fastForward(from: waitStart, factor: 8)
        pause(1.0)
        tap(fresh)
        XCTAssertTrue(app.staticTexts["revealedMessage"].waitForExistence(timeout: 10))
        pause(3.6)

        // 4. Quit and reopen. The home screen and launch screen in between are cut out.
        chapter(title: "Still there after a relaunch.", sub: "Quit, reopen: both capsules come back from Postgres.")
        pause(1.0)
        let relaunchStart = Date()
        app.terminate()
        app = launchApp()
        let opened = app.buttons.matching(NSPredicate(format: "identifier == 'capsuleRow' AND label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForCount(app.buttons.matching(identifier: "capsuleRow"), 2))
        cut(from: relaunchStart)
        pause(3.0)

        chapter(style: "end", title: "Time Capsule", sub: "SwiftUI app, Node API, Postgres. Recorded on a cloud Mac.")
        pause(4.0)
        events.append(["t": now(), "kind": "end"])
        attachMarkers()
    }

    // MARK: - Actions that leave markers

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_URL"] = ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787"
        app.launch()
        return app
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    /// The only thing that sets the pace: a deliberate hold, kept as is in the video.
    /// Longer holds also save a screenshot with its time: compose.py lines the recording up against these (the
    /// recording's own start time can be off by half a minute).
    @MainActor
    private func pause(_ seconds: Double) {
        if seconds >= 0.6 { syncShot() }
        let start = now()
        Thread.sleep(forTimeInterval: seconds)
        events.append(["t": start, "kind": "hold", "until": now()])
    }

    @MainActor
    private func syncShot() {
        shots += 1
        let name = String(format: "sync-%02d", shots)
        let before = now()
        let shot = XCUIScreen.main.screenshot()
        let after = now()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        events.append(["t": before, "kind": "shot", "until": after, "name": name])
    }

    private func chapter(style: String = "step", kicker: String? = nil, title: String, sub: String? = nil, chip: String? = nil) {
        var e: [String: Any] = ["t": now(), "kind": "chapter", "style": style, "title": title]
        if let kicker { e["kicker"] = kicker }
        if let sub { e["sub"] = sub }
        if let chip { e["chip"] = chip }
        events.append(e)
    }

    /// Taps like a finger would, and records the element's box and the window the touch landed in. compose.py
    /// draws the touch circle on the first on-screen change near the element inside that window.
    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "can't tap \(element)")
        var e = box(element.frame)
        let pre = now()
        element.tap()
        e["kind"] = "tap"
        e["pre"] = pre
        e["t"] = now() - 0.12
        events.append(e)
    }

    /// One typeText call per message, so it appears letter by letter. compose.py re-times the keystrokes it sees
    /// to a person's pace (XCUITest types in bursts).
    @MainActor
    private func type(_ text: String, into element: XCUIElement) {
        var e = box(element.frame)
        let start = now()
        element.typeText(text)
        e["kind"] = "type"
        e["t"] = start
        e["until"] = now()
        e["chars"] = text.count
        events.append(e)
    }

    /// The element's centre and size as a share of the screen.
    @MainActor
    private func box(_ f: CGRect) -> [String: Any] {
        let screen = app.windows.firstMatch.frame
        let w = max(screen.width, 1), h = max(screen.height, 1)
        return ["x": Double((f.midX - screen.minX) / w), "y": Double((f.midY - screen.minY) / h),
                "w": Double(f.width / w), "h": Double(f.height / h)]
    }

    @MainActor
    private func waitForCount(_ query: XCUIElementQuery, _ count: Int) -> Bool {
        let e = expectation(for: NSPredicate(format: "count >= %d", count), evaluatedWith: query)
        return XCTWaiter().wait(for: [e], timeout: 10) == .completed
    }

    /// Plays a real-time wait (a countdown) faster, so it's visible but short.
    private func fastForward(from start: Date, factor: Double) {
        let until = now() - 0.25
        if until - start.timeIntervalSince1970 > 1.0 {
            events.append(["t": start.timeIntervalSince1970 + 0.3, "kind": "speed", "until": until, "factor": factor])
        }
    }

    /// Drops a stretch from the video (the home screen and launch screen during a relaunch).
    private func cut(from start: Date) {
        events.append(["t": start.timeIntervalSince1970, "kind": "cut", "until": now() - 0.2])
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
