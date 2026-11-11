# CLAUDE.md

Time Capsule: a SwiftUI iOS app (`App/`), a Node + Postgres API (`api/`), an XCUITest e2e suite (`UITests/`), and a scripted demo walkthrough (`DemoTests/`) that becomes each PR's preview video. See README.md for what the app does.

## The one thing to know

You are probably running in a **Linux** cloud environment. Linux can't build or run iOS code, because Xcode and the iOS Simulator only exist on macOS. **The Mac is GitHub Actions** (`runs-on: xcode-27`). You check iOS work by pushing a branch, opening a PR, and reading what CI publishes. Don't use the user's own Mac unless they ask.

CI does two separate jobs. Keep them separate:

| | **E2E** (`.github/workflows/e2e.yml`) | **Demo** (`.github/workflows/demo.yml`) |
|---|---|---|
| Purpose | The merge gate: proves the feature works end to end | A one-off preview video of the change, for humans reviewing the PR |
| Runs | Every PR into `main`, and every push to `main` | When a PR opens or reopens, when it gets the `demo` label, or by hand |
| What runs | API tests against Postgres, then `UITests/` in the Simulator against the live API | `DemoTests/` at human pace in the Simulator, recorded, then composed into an MP4 |
| Output | Screenshots and logs on `e2e-output/<branch>` | `demo.mp4` (1080p60) on `demo-preview/<branch>`, linked in a PR comment |
| Kept | Until the PR closes | Until the PR closes (`cleanup.yml` deletes both branches) |

Never put assertions that matter only in the demo, and never record video in the e2e job.

## The loop for any change

1. Work on a branch, never directly on `main`.
2. Write the e2e step first (`UITests/`) that proves the change, with a `snap("N Description")` for each user-facing state. Then make the change.
3. If the change is visible to users, update `DemoTests/DemoWalkthrough.swift` so the demo shows it: add a `chapter(...)` caption, use `tap(...)` and `type(...)` so it reads like a person using the app, and `fastForward(...)` over any waiting.
4. Push and open a PR into `main` (`gh pr create --base main`). That starts both workflows.
5. Watch the runs:
   ```sh
   gh run list -R dcantu96/test-ios-app --branch <branch> --limit 4 --json databaseId,workflowName,status,conclusion
   gh run view <id> -R dcantu96/test-ios-app --json status,conclusion        # poll until completed
   gh run view <id> -R dcantu96/test-ios-app --log-failed | tail -80         # on failure
   ```
   E2E takes about 5 minutes; the demo takes about 8 (record on the Mac, then compose on Linux). If `gh run watch` returns early, poll `gh run view` in a loop.
6. Get the results from the branches, not the Actions artifacts. Artifact downloads go to an Azure blob host that the cloud sandbox's proxy blocks.
   ```sh
   git fetch --depth 1 origin +e2e-output/<branch>:refs/remotes/origin/e2e-output/<branch>
   mkdir -p /tmp/e2e && git archive origin/e2e-output/<branch> | tar -x -C /tmp/e2e
   git fetch --depth 1 origin +demo-preview/<branch>:refs/remotes/origin/demo-preview/<branch>
   mkdir -p /tmp/demo && git archive origin/demo-preview/<branch> | tar -x -C /tmp/demo
   ```
   `e2e-output/<branch>` has `README.md` (status, Xcode, device, DB, API test counts), `steps/*.png`, `api.log`, `xcodebuild-test.log` and `test-summary.json`. `demo-preview/<branch>` has `demo.mp4`.
7. **Look before you say it works.** Read the step screenshots with the Read tool. For the demo, pull frames from the MP4 (`ffmpeg -ss 12 -i demo.mp4 -frames:v 1 f.png`) and look at them. A green run only says the assertions passed.
8. The e2e check must be green before merging. The demo is for people; a failed demo never blocks a merge, but fix it if the walkthrough broke.

## Demo videos

- `scripts/run-demo.sh` (Mac): builds the `CloudSimDemo` scheme, starts `simctl io recordVideo`, notes when the first frame was taken, runs the walkthrough, then pulls the `markers` attachment (captions, taps, fast-forwards) out of the result bundle into `out-demo/markers.json`.
- `demo/compose.py` (Linux, needs `ffmpeg` and Pillow): draws the board (dusk sky, phone, captions, tap ripples, a footer with PR, commit, device and Xcode), fast-forwards the marked waits, and encodes 1920×1080 at 60 fps with H.264 (`--quality high` is CRF 16, `slow`; `--quality draft` is quick). Fonts are vendored in `demo/fonts` (Inter and Space Grotesk, OFL).
- You can iterate on the look in Linux without a Mac: point `compose.py` at any recording plus a hand-written `markers.json` (the format is in its docstring) and use `--quality draft --keep <dir>`.
- Re-record a PR's demo by adding the `demo` label (remove it first if it's already there) or with `gh workflow run demo.yml --ref <branch>`.

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
- `scripts/sim-setup.sh` (sourced by both run scripts) picks the newest Xcode, the newest *general* iOS runtime and an iPhone Pro, and boots it with a 9:41 status bar.
- `scripts/run-e2e.sh` runs the `CloudSim` scheme (`UITests/` only) and exports the `XCTAttachment` screenshots to `out/steps/`. `scripts/publish-output.sh` force-pushes them to `e2e-output/<branch>`.
- The Xcode project is **generated** from `project.yml` with XcodeGen. Never commit or hand-edit `*.xcodeproj`. Add targets, schemes and settings in `project.yml`. Two schemes: `CloudSim` (e2e) and `CloudSimDemo` (demo).
- The app reads its API base URL from the `API_URL` env var. UI tests pass it through `app.launchEnvironment`.

## Gotchas already hit (don't rediscover them)

- **macOS ships bash 3.2.** No `${var^}`, no `mapfile`, and an empty array under `set -u` is "unbound", so expand it as `${arr[@]+"${arr[@]}"}`.
- **Device-specific runtimes.** The Xcode 27 image includes runtimes like `iOS-27-2-iPhone19-4` that only run one device (a dual-screen "iPhone Duo"). Picking one breaks `simctl io` ("Cannot choose between 2 displays"). `sim-setup.sh` prefers runtime identifiers without a device suffix. Keep it that way.
- **`macos-26` vs `xcode-27`.** The `macos-26` image tops out at Xcode 26.x and iOS 26.x. The newest SDK is on the separate `xcode-27` image. When a new Xcode image ships, change `runs-on` in both workflows.
- **Simulator recordings have messy timestamps.** `simctl recordVideo` writes a variable frame rate with out-of-order decode timestamps, so ffmpeg filters that read timestamps (`trim`, `select`, `fps` over the whole file) see the wrong frames, and a whole recording can look like nothing but the home screen. Seek on the input instead (`ffmpeg -ss 150 -i rec.mp4 …`); `compose.py` normalizes this way before cutting.
- **Videos inside Claude's Motion artifacts don't play in the mobile app.** The user wants demos as MP4 files anyway; don't build demos as artifacts.
- **Node's test runner output.** Node 24 prints `ℹ pass 3` (spec reporter), not TAP's `# pass 3`. Parse both.
- **The cloud sandbox can't create repos** through the GitHub API (it's scoped to attached repos). Ask the user to create one, or use a browser.
- **Swift versions:** the app target is Swift 6 (strict concurrency). The two UI test targets are Swift 5 so XCTest's non-isolated setup methods don't fight `@MainActor` `XCUIApplication`. Mark helpers that touch the app `@MainActor`.
- **Required checks and path filters don't mix.** The e2e workflow has no `paths-ignore` on `pull_request`, on purpose: a required check that never runs leaves the PR blocked.
- **macOS minutes cost more.** The repo is private, so each run uses the account's Actions minutes, and macOS minutes are billed at a higher rate than Linux. Don't push in a loop to "see if it's fixed"; read the log first. That's also why composing the demo runs on Linux.

## Conventions

- Commit as `David Cantu <dcantu96@users.noreply.github.com>` with a `Co-Authored-By: Claude` trailer.
- Branch, PR into `main`, green e2e, then merge. No direct pushes to `main`.
- Every user-facing change gets an e2e step with a `snap(...)` and, if it's visible, a beat in the demo walkthrough.
- Keep `README.md` describing the product and `CLAUDE.md` describing how to work on it.
