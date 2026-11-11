import SwiftUI
import UIKit

@main
struct CloudSimApp: App {
    init() {
        // Demo recordings only (DEMO_SLOWMO): UIKit's animations (sheets, the keyboard) run slower on every window,
        // matching the SwiftUI ones slowed by `Animation.paced`. See DemoPace.
        if DemoPace.factor > 1 {
            DemoWindowPacer.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Slow motion for demo recordings. On a small CI Mac the Simulator draws only ~10 frames a second while things
/// move, so animations recorded at normal speed stutter. The demo launches the app with DEMO_SLOWMO=4: every
/// animation runs 4x slower, the Simulator gets 4x as many frames into each one, and demo/compose.py plays the
/// moving stretches back 4x faster. Off (1) everywhere else, including the e2e tests.
enum DemoPace {
    static let factor: Double = {
        let value = Double(ProcessInfo.processInfo.environment["DEMO_SLOWMO"] ?? "") ?? 1
        return value > 1 ? value : 1
    }()
}

/// Slows every window's Core Animation clock as it appears (the app's window, the sheet, the keyboard).
/// Selector-based so it compiles cleanly under Swift 6: the closure form sent a Notification across actors.
@MainActor
final class DemoWindowPacer: NSObject {
    static let shared = DemoWindowPacer()

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible(_:)),
                                               name: UIWindow.didBecomeVisibleNotification, object: nil)
    }

    @objc private func windowBecameVisible(_ note: Notification) {
        (note.object as? UIWindow)?.layer.speed = Float(1 / DemoPace.factor)
    }
}

extension Animation {
    /// This animation, slowed for demo recordings (see DemoPace). Use it for every animation in the app.
    var paced: Animation {
        DemoPace.factor > 1 ? speed(1 / DemoPace.factor) : self
    }
}
