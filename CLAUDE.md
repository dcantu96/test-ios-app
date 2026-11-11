# CLAUDE.md

Time Capsule: a SwiftUI iOS app (`App/`), a Node + Postgres API (`api/`), an XCUITest e2e suite (`UITests/`), and a scripted demo walkthrough (`DemoTests/`) that becomes each PR's preview video. See README.md for what the app does.

## The one thing to know

You are probably running in a **Linux** cloud environment. Linux can't build or run iOS code, because Xcode and the iOS Simulator only exist on macOS. **The Mac is GitHub Actions** (`runs-on: xcode-27`). You check iOS work by pushing a branch, opening a PR, and reading what CI publishes. Don't use the user's own Mac unless they ask.

CI (`.github/workflows/e2e.yml`, workflow name "CI") runs two Macs in parallel. Keep their jobs separate:

| | **e2e** job | **demo** job |
|---|---|---|
| Purpose | The merge gate: proves the feature works end to end | A one-off preview video of the change, for people reviewing the PR |
| Runs | Every PR into `main`, and every push to `main` | Every PR push (re-recorded each time), or by hand |
| What runs | API tests against Postgres, then `UITests/` in the Simulator against the live API | `DemoTests/` at human pace in the Simulator, recorded, then composed into an MP4 on the same Mac |
| Output | Screenshots and logs on `e2e-output/<branch>` | `demo.mp4` (1080p60) on `demo-preview/<branch>`, linked in a PR comment |
| Kept | Until the PR closes (`cleanup.yml`) | Until the PR closes (`cleanup.yml`) |

Never put assertions that matter only in the demo, and never record video in the e2e job.

## The fastest path from a feature request to a green e2e + a demo

Measured on this repo: **about 5 minutes from push to both "e2e passed" and "demo posted"**, with one push. The only slow part is the Mac, so do everything you can in Linux first and push once.

1. **Branch.** `git checkout -b <feature>` from `main`. Never commit to `main`.
2. **API first, locally, in seconds.** If the feature touches the API: write the `api/test/*.test.ts` case, then the code, and run `npm test` against local Postgres (see "API work"). Get it green here; never use CI to find API bugs.
3. **Write the e2e step before the Swift.** In `UITests/TimeCapsuleUITests.swift`, add the steps that prove the feature, with a `snap("N Description")` at each user-facing state. Rules that keep it fast and unflaky:
   - Never race the clock. If something must not have happened yet, set it up so it *can't* happen during the test (the "too early" check uses a capsule sealed for a year).
   - Start any wait first and do other checks while it runs (the 10-second capsule is sealed first).
   - Every wait is `waitForExistence` or an expectation with a timeout, never a fixed `sleep` (the one `sleep(1)` is only for a screenshot of a finished animation).
4. **Write the Swift.** Keep identifiers (`accessibilityIdentifier`) on everything a test touches. You can't compile Swift here, so read your code twice: check Swift 6 concurrency (`@MainActor`), optionals and API names. A compile error costs a whole CI round (about 5 minutes).
5. **Update the demo** if the change is visible: in `DemoTests/DemoWalkthrough.swift`, add a `chapter(title:sub:chip:)` caption, use `tap(...)` and `type(...)` so it reads like a person, and `fastForward(from:factor:)` over any waiting. Preview the look locally with `demo/compose.py` and a hand-written `markers.json` if you change captions or the board (see "Demo videos").
6. **Push once and open the PR** (`gh pr create --base main`, or `gh api repos/dcantu96/test-ios-app/pulls -f ...` if GraphQL is blocked). Both Mac jobs start at once.
7. **Wait and measure.** Poll, then read the timings:
   ```sh
   RUN=$(gh run list -R dcantu96/test-ios-app --branch <branch> --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run view $RUN -R dcantu96/test-ios-app --json status,conclusion        # poll every ~20 s until completed
   python3 scripts/ci-timing.py $RUN                                         # per-job, per-step seconds
   gh run view $RUN -R dcantu96/test-ios-app --log-failed | tail -80         # on failure
   ```
   If `gh run watch` returns early, poll `gh run view` in a loop. Commands block for at most 10 minutes, so poll in chunks.
8. **Look at the results** (from the branches; Actions artifact downloads are blocked by the sandbox proxy):
   ```sh
   git fetch --depth 1 origin +e2e-output/<branch>:refs/remotes/origin/e2e-output/<branch>
   mkdir -p /tmp/e2e && git archive origin/e2e-output/<branch> | tar -x -C /tmp/e2e     # README.md, steps/*.png, api.log, xcodebuild-test.log
   git fetch --depth 1 origin +demo-preview/<branch>:refs/remotes/origin/demo-preview/<branch>
   mkdir -p /tmp/demo && git archive origin/demo-preview/<branch> | tar -x -C /tmp/demo  # demo.mp4
   ffmpeg -ss 12 -i /tmp/demo/demo.mp4 -frames:v 1 /tmp/f.png                           # look at frames
   ```
   Read the step screenshots and a few demo frames with the Read tool before saying it works. A green run only says the assertions passed.
9. **Fix in one go.** If something failed, read `--log-failed` and `xcodebuild-test.log` first, fix everything you can see, then push once. Don't push to "see if it's fixed": every round is about 5 minutes and about 10 Mac minutes.
10. The **e2e** check must be green before merging; the user merges (it can't be merged from the sandbox). A failed demo never blocks a merge, but fix the walkthrough if it broke.

### Where the 5 minutes go (measured on `xcode-27`, 5 CPUs, 14 GB)

| Step | e2e job | demo job |
|---|---|---|
| Checkout, Node (cached), XcodeGen binary, pick Simulator | ~10 s | ~10 s |
| Postgres + API tests + API | ~12 s | ~12 s |
| Build (no Simulator running) | ~13 s | ~13 s |
| Simulator boot | 40–95 s | 40–95 s |
| Tests / walkthrough (on a just-booted Simulator) | 100–180 s | 120–200 s |
| Compose MP4 (Simulator shut down) | | ~35 s |
| **Job** | **~4.5 min** | **~5–6 min** |

Before this work it was e2e ~5 min and demo ~10 min (record, then a Linux job composing for ~4 min), 593 s push-to-done; now ~290–370 s.

### Why it's laid out like this (don't re-learn these)

- **A freshly booted iOS 27 Simulator saturates the runner for minutes.** After `bootstatus` returns, iOS renders wallpaper posters, refreshes widgets (Calendar, Health, Safari, Wallet, News), runs photo analysis, Shortcuts, social, Apple Intelligence and Spotlight-knowledge jobs; load average passes 300 on 5 CPUs. It happens on *every* boot, even of a device that has settled before. Anything overlapping it crawls: the build went from 13 s to 111 s, Postgres + API tests from 12 s to 119 s, `simctl status_bar` took 37 s, `app.terminate()` took 39 s.
- So **boot last**: setup, backend and build run first with no Simulator, then boot, then test. Overlapping boot with them (booting at second zero) was slower every time.
- **One Simulator per machine.** Two on one runner (e2e and demo side by side) starved everything (`setup-node` took 2 minutes); two Macs in parallel is faster.
- **Tried and dropped** (measured, no net gain or broken): caching a booted or fully settled Simulator (`~/Library/Developer/CoreSimulator/Devices`, 1.6–2.6 GB, boots in ~15 s but the per-boot churn remains and the restore costs ~25 s plus an 8-minute job to build the cache); `launchctl disable`/`bootout` of iOS services inside the Simulator (doesn't persist, and 90 services took 80 s to stop); `SIGSTOP`-freezing the heavy processes during tests (hangs XCTest); pre-enabling accessibility before boot (`SIM_PREWARM_AX=1` in `sim.sh`: test-runner start drops from ~40 s to ~5 s, but the time reappears in the first app launch; left as an option, off).
- **Spotlight is turned off** on the runner (`mdutil -a -i off`): it indexes each new Simulator device at full CPU.
- **XcodeGen comes from its release binary**, not Homebrew (`brew install` took up to 2 minutes on a busy runner).
- **The demo is composed on its own Mac** with the Simulator shut down (~35 s on 5 CPUs; the 2-CPU Linux runner took 75 s plus a job hand-off).
- **What would make it faster still** (not done; needs the user's call): bigger paid macOS runners (more CPUs absorb the Simulator's churn), or running the e2e suite on a self-hosted Mac that keeps a Simulator booted between runs.

## Demo videos

- `scripts/run-demo.sh` (Mac): starts `simctl io recordVideo`, notes when the first frame was taken, runs the `CloudSimDemo` scheme from the shared build, then pulls the `markers` attachment (captions, taps, fast-forwards) out of the result bundle into `out-demo/markers.json`.
- `demo/compose.py` (needs an ffmpeg with libx264 and Pillow; CI uses the static ffmpeg from the `imageio-ffmpeg` pip wheel, `FFMPEG=...`): draws the board (dusk sky, phone, captions, tap ripples, footer with PR, commit, device and Xcode), fast-forwards the marked waits, and encodes 1920×1080 at 60 fps. `--quality high` is x264 `veryfast` CRF 16 (visually identical to `slow`, SSIM 0.998, several times faster). It decodes each still once with the `loop` filter (`-loop 1` re-decoded the PNG every frame) and cuts the recording in one pass.
- Iterate on the look in Linux without a Mac: point `compose.py` at any recording plus a hand-written `markers.json` (format in its docstring) and use `--quality draft --keep <dir>`. In this sandbox, get a static ffmpeg with `python3 -m venv v && v/bin/pip install imageio-ffmpeg pillow`, then `FFMPEG=$(ls v/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*)`.
- Re-record a PR's demo by pushing again, or `gh workflow run CI --ref <branch>` once the workflow is on `main`.

## API work (can be done fully in Linux)

```sh
cd api && npm ci
DATABASE_URL=postgres://postgres@127.0.0.1:5432/capsules_test npm test    # integration tests against real Postgres
DATABASE_URL=postgres://postgres@127.0.0.1:5432/capsules npm start        # http://127.0.0.1:8787
```
If no Postgres is running, check for a local install (`/usr/lib/postgresql/*/bin`). Postgres refuses to run as root, so run `initdb` and `pg_ctl` as the `postgres` user, with a data directory that user can reach (for example `/var/lib/postgresql/devdata`). The scratchpad under `/tmp/claude-0` isn't reachable by that user.

The API is TypeScript run directly by Node (`--experimental-strip-types`). Use only erasable TS syntax (no `enum`, `namespace` or parameter properties) and import with `.ts` extensions.

## How the pieces fit

- `.github/actions/mac-setup` (used by both Mac jobs): `sim.sh prepare`, Node, XcodeGen, `start-backend.sh`, `build.sh`, back to back.
- `scripts/sim.sh prepare` picks the newest Xcode, the newest *general* iOS runtime and the newest iPhone Pro, and turns Spotlight off. `scripts/sim.sh boot UDID` boots it (`SIM_STATUS_BAR=1` gives recordings a 9:41 status bar).
- `scripts/start-backend.sh` starts Postgres 17 (Homebrew), creates `capsules` (the app) and `capsules_test` (API tests), runs the API tests, then starts the API on `:8787`. The Simulator shares the Mac's network, so the app reaches it at `http://localhost:8787` (`NSAllowsLocalNetworking` is set in `project.yml`).
- `scripts/build.sh` generates the project and runs `build-for-testing` once; `run-e2e.sh` and `run-demo.sh` use `test-without-building`.
- `scripts/run-e2e.sh` runs the `CloudSim` scheme (`UITests/` only) and exports the `XCTAttachment` screenshots to `out/steps/`; `scripts/publish-output.sh` force-pushes them to `e2e-output/<branch>`.
- `scripts/ci-timing.py [RUN_ID]` prints per-job and per-step seconds for a run.
- The Xcode project is **generated** from `project.yml` with XcodeGen. Never commit or hand-edit `*.xcodeproj`. Two schemes: `CloudSim` (e2e) and `CloudSimDemo` (demo).
- The app reads its API base URL from the `API_URL` env var. UI tests pass it through `app.launchEnvironment`.

## Gotchas already hit

- **macOS ships bash 3.2.** No `${var^}`, no `mapfile`, and an empty array under `set -u` is "unbound", so expand it as `${arr[@]+"${arr[@]}"}`.
- **`simctl boot` blocks** until the device is up; background it with `&` if you ever need to.
- **Device-specific runtimes.** The Xcode 27 image includes runtimes like `iOS-27-2-iPhone19-4` that only run one device (a dual-screen "iPhone Duo"); `simctl io` then fails with "Cannot choose between 2 displays". `sim.sh` prefers runtime identifiers without a device suffix.
- **A runtime's `supportedDeviceTypes` is oldest first by release, not by model number.** Taking the last "Pro" picked an iPhone 11 Pro; `sim.sh` picks the highest model number.
- **`macos-26` vs `xcode-27`.** The `macos-26` image tops out at Xcode 26.x / iOS 26.x; the newest SDK is on the `xcode-27` image. When a new Xcode image ships, change `runs-on`.
- **Simulator recordings have messy timestamps.** `simctl recordVideo` writes a variable frame rate with out-of-order decode timestamps, so ffmpeg filters that read timestamps over the whole file (`trim`, `select`, `fps`) see the wrong frames. Seek on the input (`ffmpeg -ss 150 -i rec.mp4 …`); `compose.py` does.
- **Videos inside Claude's Motion artifacts don't play in the mobile app.** The user wants demos as MP4 files; don't build demos as artifacts.
- **Node's test runner output.** Node 24 prints `ℹ pass 3` (spec reporter), not TAP's `# pass 3`. Parse both.
- **The sandbox can't** create repos, merge PRs, change branch protection, delete remote branches, or use GitHub's GraphQL API. Use REST (`gh api repos/...`) and ask the user for the rest.
- **The file tools turn `\uXXXX` in your input into the actual character.** In code that needs a literal backslash-u escape (JS/Python regexes), build it at runtime (`chr(92) + "u..."`) or use the character.
- **Swift versions:** the app target is Swift 6 (strict concurrency). The two UI test targets are Swift 5 so XCTest's non-isolated setup methods don't fight `@MainActor` `XCUIApplication`. Mark helpers that touch the app `@MainActor`.
- **Required checks and path filters don't mix.** The workflow has no `paths-ignore` on `pull_request`, on purpose: a required check that never runs leaves the PR blocked.
- **macOS minutes cost 10×.** The repo is private, so each run's Mac minutes count ten times against the account's Actions allowance (GitHub Free: 2,000 a month; one PR push here is ~10 Mac minutes, about 100 billed). Experiment in Linux, batch fixes, and push once.

## Conventions

- Commit as `David Cantu <dcantu96@users.noreply.github.com>` with a `Co-Authored-By: Claude` trailer.
- Branch, PR into `main`, green e2e, then the user merges. No direct pushes to `main`.
- Every user-facing change gets an e2e step with a `snap(...)` and, if it's visible, a beat in the demo walkthrough.
- Keep `README.md` describing the product and `CLAUDE.md` describing how to work on it.
