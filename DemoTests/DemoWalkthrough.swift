import UIKit
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
    private let letter = "Open this next year."
    private let note = "Dear future me: you made it."
    private let answer = "See you in ten seconds."

    @MainActor
    func testRecordWalkthrough() throws {
        continueAfterFailure = false
        app = launchApp()

        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        waitUntilDrawn()
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
        XCTAssertTrue(banner("Knock #1").waitForExistence(timeout: 10))
        pause(3.0)

        // 3. Knock again: the server counts every early knock, and the sealed row shows the tally.
        chapter(title: "Knock again. It's counted.",
                sub: "The server remembers every early knock, and tells you when it opens.",
                chip: "423 Locked  \u{00B7}  knocks: 2")
        pause(1.4)
        tap(rows.firstMatch)
        XCTAssertTrue(banner("Knock #2").waitForExistence(timeout: 10))
        pause(3.8)

        // 4. A note for ten seconds: watch it count down (8x), then break the seal. Nobody knocked on this one.
        chapter(title: "When time is up, break the seal.",
                sub: "This one opens in ten seconds. Wait it out: no knocks on record.",
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

        // 5. Write back from the reveal: the reply is sealed for as long as the note waited (ten seconds).
        chapter(title: "Then write back.",
                sub: "Your reply is sealed for as long as the first one waited.",
                chip: "POST /capsules  { replyTo }")
        pause(1.4)
        let replyField = app.textFields["replyField"]
        tap(replyField)
        pause(0.6)
        type(answer, into: replyField)
        pause(0.7)
        tap(app.buttons["replyButton"])
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 10))
        pause(2.8)

        // 6. Pull to refresh: all three come back from Postgres. (Not a relaunch: on the 3-CPU public-repo runner the
        //    recording stopped updating after the app quit, and showed the home screen to the end. The e2e test
        //    proves capsules survive a relaunch; the demo shows the same data reloading, on camera.)
        chapter(title: "Straight from Postgres.", sub: "Pull to refresh: all three come back, knocks and all.")
        pause(1.2)
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        XCTAssertTrue(waitForCount(app.buttons.matching(identifier: "capsuleRow"), 3))
        pause(3.6)

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

    @MainActor
    private func banner(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'lockedBanner' AND label CONTAINS %@", text)).firstMatch
    }

    /// The only thing that sets the pace: a deliberate hold, kept as is in the video.
    private func pause(_ seconds: Double) {
        let start = now()
        Thread.sleep(forTimeInterval: seconds)
        events.append(["t": start, "kind": "hold", "until": now()])
    }

    /// On a busy Simulator the screen lags the app by seconds: XCUITest finds the app's elements while the screen
    /// still shows the home screen or the white launch screen. Wait until the app is really on screen. This app's
    /// backdrop is a vivid gradient (colorfulness 0.44-0.64 measured; home screen 0.22, launch screen 0.00).
    @MainActor
    private func waitUntilDrawn(timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if colorfulness(XCUIScreen.main.screenshot().image) > 0.35 { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("the app never appeared on screen")
    }

    /// Mean saturation of a 12x26 thumbnail, 0 (grey) to 1 (vivid).
    private func colorfulness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = 12, h = 26
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var total = 0.0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            let hi = max(r, g, b), lo = min(r, g, b)
            total += hi > 0 ? (hi - lo) / hi : 0
        }
        return total / Double(w * h)
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

    /// One letter per typeText call, so every letter shows up on its own frame; compose.py then re-times them
    /// to a person's pace and trims the gaps. (A whole message in one call took ~0.8 s and some runs drew it in
    /// two or three frames: the letters arrived in clumps that no re-timing can spread out. Word by word took
    /// ~3 s a word with stalls.)
    @MainActor
    private func type(_ text: String, into element: XCUIElement) {
        var e = box(element.frame)
        let start = now()
        for letter in text {
            element.typeText(String(letter))
        }
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

    /// Drops a stretch from the video (the home screen and launch screen during a relaunch). It starts 0.4 s early,
    /// on the still screen before, so not a frame of the home screen shows in the dip.
    private func cut(from start: Date) {
        events.append(["t": start.timeIntervalSince1970 - 0.4, "kind": "cut", "until": now() - 0.2])
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
