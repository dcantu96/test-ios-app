import UIKit
import XCTest

/// The toolkit every demo scene is written with. DemoWalkthrough.swift holds the scene for the current PR and is
/// rewritten for each PR; this file stays. Read "Demo videos" in CLAUDE.md before writing a scene.
///
/// A scene shows only what its PR changed. Anything the change needs to exist first (a capsule that's ready to
/// open, a capsule that's been knocked on) is made with seed(...) through the API before the first caption, so it
/// never appears on camera: compose.py starts the video at the first chapter().
///
/// Alongside the actions, the kit writes markers (captions, taps, typing, deliberate pauses, fast-forwards, cuts)
/// as an attachment named "markers"; demo/compose.py turns the recording plus those markers into the finished MP4,
/// and demo/review.py checks the result.
///
/// Pacing: only pause() sets the pace. XCUITest's own slowness (finding elements, waiting for the app to idle) is
/// trimmed out by compose.py, so a stretch is kept only if it's a pause(), a fastForward() or the screen is moving.
class DemoCase: XCTestCase {
    var app: XCUIApplication!
    private var events: [[String: Any]] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    static let slowMotion = 4

    var apiURL: URL {
        URL(string: ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787")!
    }

    // MARK: - Setting the stage (off camera)

    /// Creates a capsule through the API, before the scene starts. Returns its id.
    @discardableResult
    func seed(_ message: String, opensIn seconds: Int) -> String {
        let (status, body) = api("POST", "capsules", ["message": message, "unlockInSeconds": seconds])
        XCTAssertEqual(status, 201, "seeding failed: \(body)")
        return body["id"] as? String ?? ""
    }

    /// Knocks on a sealed capsule through the API (an early GET), off camera.
    func seedKnock(_ id: String) {
        let (status, _) = api("GET", "capsules/\(id)", nil)
        XCTAssertEqual(status, 423, "a seeded knock should be refused")
    }

    /// Waits until a seeded capsule is ready to open, without opening it (the list never opens anything).
    func waitUntilReady(_ id: String, timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (_, body) = api("GET", "capsules", nil)
            let list = body["items"] as? [[String: Any]] ?? []
            if list.first(where: { $0["id"] as? String == id })?["status"] as? String == "ready" { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("seeded capsule \(id) never became ready")
    }

    /// A blocking HTTP call from the test runner to the API (the Simulator shares the Mac's network).
    func api(_ method: String, _ path: String, _ body: [String: Any]?) -> (Int, [String: Any]) {
        var request = URLRequest(url: apiURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        final class Box: @unchecked Sendable { var status = 0; var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.data = data ?? Data()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        let json = try? JSONSerialization.jsonObject(with: box.data)
        if let object = json as? [String: Any] { return (box.status, object) }
        if let array = json as? [[String: Any]] { return (box.status, ["items": array]) }
        return (box.status, [:])
    }

    // MARK: - The app

    @MainActor
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_URL"] = apiURL.absoluteString
        // Slow motion: the app runs its animations this many times slower and compose.py speeds the moving
        // stretches back up, so the Simulator gets that many times more frames into each animation (DemoPace).
        app.launchEnvironment["DEMO_SLOWMO"] = String(Self.slowMotion)
        app.launch()
        return app
    }

    @MainActor
    var rows: XCUIElementQuery { app.buttons.matching(identifier: "capsuleRow") }

    @MainActor
    func rowShowing(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'capsuleRow' AND label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval = 10) -> Bool {
        let e = expectation(for: NSPredicate(format: "count >= %d", count), evaluatedWith: query)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    /// On a busy Simulator the screen lags the app by seconds: XCUITest finds the app's elements while the screen
    /// still shows the home screen or the white launch screen. Wait until the app is really on screen. This app's
    /// backdrop is a vivid gradient (colorfulness 0.44-0.64 measured; home screen 0.22, launch screen 0.00).
    @MainActor
    func waitUntilDrawn(timeout: TimeInterval = 30) {
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

    // MARK: - On camera (each of these leaves a marker)

    private func now() -> Double { Date().timeIntervalSince1970 }

    /// The only thing that sets the pace: a deliberate hold, kept as is in the video.
    func pause(_ seconds: Double) {
        let start = now()
        Thread.sleep(forTimeInterval: seconds)
        events.append(["t": start, "kind": "hold", "until": now()])
    }

    /// A caption. style "title" opens the video (with a kicker), "step" is one beat of the change, "end" closes it.
    func chapter(style: String = "step", kicker: String? = nil, title: String, sub: String? = nil, chip: String? = nil) {
        var e: [String: Any] = ["t": now(), "kind": "chapter", "style": style, "title": title]
        if let kicker { e["kicker"] = kicker }
        if let sub { e["sub"] = sub }
        if let chip { e["chip"] = chip }
        events.append(e)
    }

    /// Taps like a finger would, and records the element's box and the window the touch landed in. compose.py
    /// draws the touch circle on the first on-screen change near the element inside that window.
    @MainActor
    func tap(_ element: XCUIElement) {
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
    /// to a person's pace and trims the gaps. (A whole message in one call arrived in clumps on some runs; word
    /// by word took ~3 s a word with stalls.)
    @MainActor
    func type(_ text: String, into element: XCUIElement) {
        // A tap doesn't always leave the field focused when the screen is moving (the reveal sheet grows as the
        // field is tapped). Tap again until it has the keyboard; typing into an unfocused field fails the run.
        for _ in 0..<4 where !hasFocus(element) {
            element.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(hasFocus(element), "\(element) never got keyboard focus")
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

    @MainActor
    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// The element's centre and size as a share of the screen.
    @MainActor
    private func box(_ f: CGRect) -> [String: Any] {
        let screen = app.windows.firstMatch.frame
        let w = max(screen.width, 1), h = max(screen.height, 1)
        return ["x": Double((f.midX - screen.minX) / w), "y": Double((f.midY - screen.minY) / h),
                "w": Double(f.width / w), "h": Double(f.height / h)]
    }

    /// Plays a real-time wait (a countdown) faster, so it's visible but short.
    func fastForward(from start: Date, factor: Double) {
        let until = now() - 0.25
        if until - start.timeIntervalSince1970 > 1.0 {
            events.append(["t": start.timeIntervalSince1970 + 0.3, "kind": "speed", "until": until, "factor": factor])
        }
    }

    /// Drops a stretch from the video. Avoid needing it: seed state off camera instead.
    func cut(from start: Date) {
        events.append(["t": start.timeIntervalSince1970 - 0.4, "kind": "cut", "until": now() - 0.2])
    }

    /// Ends the scene: the end marker, and the markers attachment that run-demo.sh pulls out.
    func finish() {
        events.append(["t": now(), "kind": "end"])
        let body: [String: Any] = ["events": events, "slowmo": Self.slowMotion]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "markers"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
