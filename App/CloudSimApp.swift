import SwiftUI
import UIKit

@main
struct CloudSimApp: App {
    init() {
        // Demo recordings only (DEMO_SLOWMO): UIKit's animations (sheets, the keyboard) run slower on every window,
        // matching the SwiftUI ones slowed by `Animation.paced`. See DemoPace.
        if DemoPace.factor > 1 {
            let speed = Float(1 / DemoPace.factor)
            NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let window = note.object as? UIWindow {
                        window.layer.speed = speed
                    }
                }
            }
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

extension Animation {
    /// This animation, slowed for demo recordings (see DemoPace). Use it for every animation in the app.
    var paced: Animation {
        DemoPace.factor > 1 ? speed(1 / DemoPace.factor) : self
    }
}
