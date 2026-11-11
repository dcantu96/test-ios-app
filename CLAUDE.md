# CLAUDE.md

Time Capsule: a SwiftUI iOS app (`App/`), a Node + Postgres API (`api/`), and an XCUITest e2e suite (`UITests/`). See README.md for what the app does.

## The one thing to know

You are probably running in a **Linux** cloud environment. Linux can't build or run iOS code, because Xcode and the iOS Simulator only exist on macOS. **The Mac is GitHub Actions.** Every push to `main` builds the app on a hosted Mac (`runs-on: xcode-27`), starts Postgres and the API there, runs the e2e test in the iOS Simulator, and publishes screenshots, video and logs to the `simulator-output` branch. You check iOS work by pushing it and reading those results. Don't use the user's own Mac unless they ask.

## The loop for any iOS change

1. Edit the Swift code, and add or update the XCUITest in `UITests/` that proves the change (e2e first).
2. Commit and push to `main` (or open a PR to `main`; both trigger the workflow).
3. Watch the run:
   ```sh
   RUN=$(gh run list -R dcantu96/test-ios-app --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run view $RUN -R dcantu96/test-ios-app --json status,conclusion        # poll until completed
   gh run view $RUN -R dcantu96/test-ios-app --log-failed | tail -80         # on failure
   ```
   A run takes about 5 minutes. If `gh run watch` returns early, poll `gh run view` in a loop.
4. Get the results from the branch, not the Actions artifact. Artifact downloads go to an Azure blob host that the cloud sandbox's proxy blocks.
   ```sh
   git fetch --depth 1 origin +simulator-output:refs/remotes/origin/simulator-output
   mkdir -p /tmp/e2e && git archive origin/simulator-output | tar -x -C /tmp/e2e
   ```
   You get `README.md` (status, Xcode, device, DB, API test counts), `steps/*.png` (one per `snap()` in the test), `e2e.mp4` (the whole test), `api.log` (every request the app made), `xcodebuild-test.log` and `test-summary.json`.
5. **Look at the screenshots** with the Read tool before saying something works. A green run only says the assertions passed. The images show what the user will actually see.

## API work (can be done fully in Linux)

```sh
cd api && npm ci
DATABASE_URL=postgres://postgres@127.0.0.1:5432/capsules_test npm test    # integration tests against real Postgres
DATABASE_URL=postgres://postgres@127.0.0.1:5432/capsules npm start        # http://127.0.0.1:8787
```
If no Postgres is running, check for a local install (`/usr/lib/postgresql/*/bin`). Postgres refuses to run as root, so run `initdb` and `pg_ctl` as the `postgres` user, with a data directory that user can reach (for example `/var/lib/postgresql/devdata`). The scratchpad under `/tmp/claude-0` isn't reachable by that user.

The API is TypeScript run directly by Node (`--experimental-strip-types`). Use only erasable TS syntax (no `enum`, `namespace` or parameter properties) and import with `.ts` extensions.

## How the pieces fit

- `scripts/start-backend.sh` installs and starts Postgres 17 with Homebrew, creates `capsules` (used by the app) and `capsules_test` (used by the API tests), runs the API tests, then starts the API on `:8787`. The Simulator shares the Mac's network, so the app reaches it at `http://localhost:8787`. The app needs `NSAllowsLocalNetworking` for plain HTTP, and it's set in `project.yml`.
- `scripts/run-e2e.sh` picks the newest Xcode and the newest *general* iOS runtime, picks an iPhone Pro, boots it, generates the project with XcodeGen, then runs `xcodebuild test` while recording video and exports the `XCTAttachment` screenshots to `out/steps/`.
- `scripts/publish-output.sh` force-pushes `out/` to the `simulator-output` branch with a README.
- The Xcode project is **generated** from `project.yml` with XcodeGen. Never commit or hand-edit `*.xcodeproj`. Add targets and settings in `project.yml`.
- The app reads its API base URL from the `API_URL` env var. UI tests pass it through `app.launchEnvironment`.

## Gotchas already hit (don't rediscover them)

- **macOS ships bash 3.2.** No `${var^}`, no `mapfile`, and an empty array under `set -u` is "unbound", so expand it as `${arr[@]+"${arr[@]}"}`.
- **Device-specific runtimes.** The Xcode 27 image includes runtimes like `iOS-27-2-iPhone19-4` that only run one device (a dual-screen "iPhone Duo"). Picking one breaks `simctl io screenshot` ("Cannot choose between 2 displays"). `run-e2e.sh` prefers runtime identifiers without a device suffix. Keep it that way.
- **`macos-26` vs `xcode-27`.** The `macos-26` image tops out at Xcode 26.x and iOS 26.x. The newest SDK is on the separate `xcode-27` image. When a new Xcode image ships, change `runs-on`.
- **Node's test runner output.** Node 24 prints `ℹ pass 3` (spec reporter), not TAP's `# pass 3`. Parse both.
- **The cloud sandbox can't create repos** through the GitHub API (it's scoped to attached repos). Ask the user to create one, or use a browser.
- **Swift versions:** the app target is Swift 6 (strict concurrency). The UI test target is Swift 5 so XCTest's non-isolated setup methods don't fight `@MainActor` `XCUIApplication`. Mark test helpers `@MainActor`.
- **`e2e.mp4` has a variable frame rate.** `simctl recordVideo` only writes frames when the screen changes, and recording starts before the build, so the app shows up in roughly the last minute. Sampling it with `-vf fps=1` gives misleading frames (it can look like nothing but the home screen). To inspect a moment, seek to it: `ffmpeg -ss 150 -i e2e.mp4 -frames:v 1 f.png`.
- **macOS minutes cost more.** The repo is private, so each run uses the account's Actions minutes, and macOS minutes are billed at a higher rate than Linux. Don't push in a loop to "see if it's fixed"; read the log first.

## Conventions

- Commit as `David Cantu <dcantu96@users.noreply.github.com>` with a `Co-Authored-By: Claude` trailer.
- Every user-facing change gets an e2e step with a `snap("N Description")` so it shows up in `steps/`.
- Keep `README.md` describing the product and `CLAUDE.md` describing how to work on it.
