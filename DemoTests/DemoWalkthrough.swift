import XCTest

/// This PR's demo: Write back, and nothing else.
///
/// Rewrite this file for every PR, so the video shows only what that PR changed (CLAUDE.md, "Demo videos").
/// Everything the change builds on is seeded through the API before the first caption, off camera: here, a note
/// that waited ten seconds and is now ready to open. The rest of the app is proven by the e2e suite, not shown here.
final class DemoWalkthrough: DemoCase {
    private let note = "Dear future me: you made it."
    private let answer = "Made it. See you soon."

    @MainActor
    func testRecordWalkthrough() throws {
        // Off camera: a note sealed for ten seconds, now ready to open.
        let id = seed(note, opensIn: 10)
        waitUntilReady(id)
        app = launchApp()
        XCTAssertTrue(rowShowing("Ready to open").waitForExistence(timeout: 30))
        waitUntilDrawn()
        waitForQuiet() // smooth animations need a calm Mac
        pause(0.5)

        chapter(style: "title", kicker: "New in this PR", title: "Write back",
                sub: "Answer a capsule once it opens. Your reply stays sealed as long as the first one did.")
        pause(4.8)

        // 1. Open it: the reveal now has a reply field.
        chapter(title: "Open it, then answer it.", sub: "The reveal now has a place to write back.",
                chip: "POST /capsules  { replyTo }")
        pause(1.0)
        tap(rows.firstMatch)
        XCTAssertTrue(app.staticTexts["revealedMessage"].waitForExistence(timeout: 10))
        pause(1.8)
        let replyField = app.textFields["replyField"]
        tap(replyField)
        pause(0.5)
        type(answer, into: replyField)
        pause(0.7)
        tap(app.buttons["replyButton"])
        let reply = rowShowing("Reply to")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        pause(0.8)

        // 2. The reply is sealed for as long as the note waited: ten seconds, counted down (fast-forwarded).
        chapter(title: "Sealed as long as the first one waited.",
                sub: "That note waited ten seconds, so the reply opens in ten.")
        pause(2.2)
        let waitStart = Date()
        let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: reply)
        wait(for: [ready], timeout: 30)
        fastForward(from: waitStart, factor: 5)
        pause(2.2)

        chapter(style: "end", title: "Write back", sub: "Time Capsule. SwiftUI app, Node API, Postgres.")
        pause(3.6)
        finish()
    }
}
