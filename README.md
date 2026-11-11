# CloudSim

A minimal SwiftUI app that builds on the newest Xcode and runs in the newest iOS Simulator on a GitHub-hosted macOS runner. There's no Mac on your desk involved.

Each push to `main`, or a manual run from the Actions tab, does the following:

1. Picks the newest non-beta Xcode on the `macos-26` runner.
2. Picks the newest installed iOS runtime and an iPhone Pro simulator.
3. Generates the Xcode project with XcodeGen from `project.yml`, then builds it.
4. Boots the simulator, installs and launches the app, and records `screenshot.png` and `run.mp4`.
5. Uploads everything in `out/` as the `simulator-output` artifact.

The UI uses `glassEffect` (Liquid Glass), which only exists in the iOS 26 SDK, so a green run shows the latest SDK is in use.

To run a different app, swap the `App/` sources and `project.yml`, or point `scripts/run-in-simulator.sh` at an existing `.xcodeproj`/`.xcworkspace` and scheme.
