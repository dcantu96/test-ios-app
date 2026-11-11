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
5. **Update the demo** if the change is visible: go through "Before writing demo steps" (under "Demo videos") first, then edit `DemoTests/DemoWalkthrough.swift`. To change captions or the board, iterate in Linux on the previous run's `source/` (see "Demo videos").
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
   mkdir -p /tmp/demo && git archive origin/demo-preview/<branch> | tar -x -C /tmp/demo  # demo.mp4, review.md, sheets/, source/
   ```
   Read every e2e step screenshot, then **review the demo** (below): `review.md`, then every contact sheet in `sheets/`. A green run only says the assertions passed.
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
| Compose MP4 + review (Simulator shut down) | | ~50–70 s |
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

A demo is a short film of the change for people reviewing the PR. CI records `DemoTests/DemoWalkthrough.swift` driving the app, `demo/compose.py` turns the recording into the 1080p60 MP4, and `demo/review.py` checks it. The first fast-CI video (PR #2, 102 s) had every flaw below. They were found by watching it frame by frame, and each one is now a rule, an automatic fix or an automatic check.

### Before writing demo steps (go through this list first)

1. **One idea per chapter, shown on camera.** Write the captions first: each `chapter(...)` names one thing the viewer will *see* happen right after it. If something happens off camera (a countdown that ran out while you were typing something else), reorder the story so it happens on screen.
2. **Captions need reading time.** About 1 s plus 25 characters a second (title + sub + chip). Size the `pause()` after a caption, or the actions under it, to cover that. `compose.py` warns about short chapters and `review.py` flags them. Keep subs to one short sentence.
3. **Text must fit its field.** A message longer than the field scrolls sideways and loses its first letters. Keep typed text under about 30 characters.
4. **Type a message with one `type(...)` call.** It sends one letter per `typeText` so each letter is its own frame, and `compose.py` re-times them to about 11 a second. A whole message per `typeText` arrived in clumps of letters on some runs (no re-timing can spread one frame out); word by word made words pop in whole, with stalls.
5. **Tap only what the viewer should see tapped**, each once, in a sensible order. No warm-up taps (tapping "1m" then "10s" read as a mistake). Every `tap(...)` draws a touch circle.
6. **`pause()` is the only pacing.** Everything else XCUITest does (finding elements, waiting for the app to idle, slow typing) leaves the screen still, and `compose.py` trims any still stretch outside a `pause()` to a quarter second. So after every visible result, `pause()` long enough to see it (1–3 s). Never count on XCUITest's slowness for pacing.
7. **Real waits get `fastForward(from:factor:)`**: the 10 s countdown plays at 8×, about a second. At 4× it still read as dead air.
8. **Anything that isn't the app gets `cut(from:)`**: relaunching shows the home screen and a white launch screen. A cut drops it, with a quick dip on each side.
9. **Wait for the app to be visible, not just present: `waitUntilDrawn()`** after every launch, before the first caption and before ending a cut. On a busy Simulator the screen lags the app by seconds: XCUITest found the text field while the screen still showed the home screen, then a white launch screen, for 6 s of the title card.
10. **Aim for 45–75 s.** `review.py` flags anything over 90 s.

### Reviewing the finished video (every time, before calling it done)

CI runs `demo/review.py` after composing and posts its findings in the PR comment. Then, by hand:
1. Read `review.md` (it's also in the PR comment). Fix every flag, or say why it's fine.
2. Read **every** contact sheet in `sheets/` (a frame every 0.5 s, labeled with its time) with the Read tool. Look for: captions that don't match what the phone shows; a touch circle with nothing happening; text clipped in a field; the home screen or a blank screen; a stretch where nothing moves; anything ugly at a transition.
3. To check a moment closely: `ffmpeg -ss 12.5 -i demo.mp4 -frames:v 1 f.png`, then Read it.
4. Fix all of it in one go: the walkthrough (needs a Mac run), or the board and timing (iterate in Linux on `source/`, below).

What `review.py` checks, against `demo.report.json` (what `compose.py` placed where) and the pixels:
- **sync**: every touch circle sits on a response concentrated on the tapped element (a whole-screen change like an app launch doesn't count; counting it hid an out-of-sync video)
- **dead air**: no still stretch over 2 s outside a `pause()`, and none over 5 s at all
- **typing**: 5–30 characters a second, no stall over 0.6 s
- **flashes**: nothing pops on screen and away within a second, like a home screen or launch screen
- **blank**: no flat one-color screen (a launch screen) outside the dip at a cut
- **captions**: up long enough to read
- **length**: under 90 s

### Flaws found in the 102 s video, and what fixed them

| Flaw | Cause | Fix |
|---|---|---|
| Captions, touch circles and fast-forwards off by 9–35 s, a different amount every run | The recording's first frame comes long after simctl prints "Recording started" (an idle Simulator sends no frames), so `recordingStart` can't be trusted | `compose.py` syncs on the taps and typing: at the right offset each one changes the screen *on its own element* (a whole-screen change doesn't count) and the screen is still just before it (XCUITest waits for the app to go quiet before acting). It prints `sync: the recording runs -35.2s ... (confidence 0.25)`. Checked against five real recordings |
| The sync was right in analysis but the video still drifted 5–27 s | Two passes seeked into the raw recording at different points, and simctl's messy timestamps put them on different timelines | One pass normalizes the recording (from 90 s before the first caption) to a clean constant-rate copy; the analysis, the cut and the saved `source/` all read that copy. `source/` + its `markers.json` reproduce the run exactly in Linux |
| Typing still stalled and jumped after re-timing | Keystrokes were found at 10 frames a second (a 20-letter burst looked like 4 moments), and the recording was cut into pieces and joined, which rounded short pieces to nothing | Keystrokes are found at the full 60 fps, and the screen is re-timed in one frame-exact pass (one expression maps every frame's time; no pieces) |
| Home screen flashed in the dip before the relaunch cut | The cut started the instant `terminate()` was called; the screen was already leaving | `cut(from:)` starts 0.4 s early, on the still screen |
| Tried and dropped for sync | | Matching changes near elements without the stillness rule (an app launch and home-screen widgets fooled it); matching screenshots taken at known times (on a busy Simulator a screenshot can show the screen seconds late) |
| Touch circles on nothing ("unintentional presses") | Same offset | Same |
| Typing took 25 s for one sentence, word by word with ~3 s stalls; later, whole messages appeared in 2–3 clumps | One `typeText` per word (~3 s each on a busy Simulator); then one per message, which some runs drew in 2–3 frames | One `typeText` per letter, every letter its own frame; keystrokes found at 60 fps and re-timed to ~11 a second |
| 14 s with nothing moving before a seal, and more gaps like it | XCUITest finding elements (~5 s per tap on a busy Simulator) | Still stretches outside `pause()` trimmed to 0.25 s |
| Home screen, then a white screen, during the relaunch | `app.terminate()` and `launch()` on camera | `cut(from:)` around the relaunch |
| Home screen, then a white launch screen, under the title card (6 s) | The screen lags the app: XCUITest saw the field long before it was drawn | `waitUntilDrawn()` (screenshots until the app's colors show), and `review.py` flags blank screens |
| The 10 s capsule unlocked off camera while the next note was typed | Story order copied from the e2e test | Letter first, then the 10 s note with its countdown on screen |
| A headline ending on one word ("…when it / opens.") | Greedy line wrapping | Balanced wrapping: same line count, even lengths |
| Star trails across the captions, reading as strikethroughs | Random trails anywhere in the sky | Trails kept out of the caption column |
| Message clipped at the start of the field | Message longer than the field | Shorter messages (checklist 3) |

### Tools

- `scripts/run-demo.sh` (Mac): starts `simctl io recordVideo`, notes when simctl says it started (rough; `compose.py` syncs precisely), runs the `CloudSimDemo` scheme from the shared build, then pulls the `markers` attachment out of the result bundle into `out-demo/markers.json`.
- `demo/compose.py` (needs an ffmpeg with libx264, Pillow and numpy; CI uses the static ffmpeg from the `imageio-ffmpeg` pip wheel, `FFMPEG=...`): syncs, trims dead air, applies fast-forwards and cuts, draws the board (dusk sky, phone, captions, touch circles, footer with PR, commit, device and Xcode), and encodes 1920×1080 at 60 fps. It writes `demo.report.json` beside the video. `--quality high` is x264 `veryfast` CRF 16 (visually identical to `slow`, SSIM 0.998, several times faster). It decodes each still once with the `loop` filter (`-loop 1` re-decoded the PNG every frame) and cuts the recording in one pass. `--save-source DIR` also writes the normalized recording this run analysed and its markers (CI publishes them as `source/`); composing from them reproduces the run.
- `demo/review.py demo.mp4 --sheets DIR --out review.md`: the checks above, plus contact sheets.
- **Iterate on the board, timing and sync in Linux, without a Mac:** fetch the `demo-preview/<branch>` branch, then `python3 demo/compose.py --recording source/source.mp4 --markers source/markers.json --out demo.mp4 --quality draft` (it redoes the run's sync exactly) and `python3 demo/review.py demo.mp4 --sheets sheets`. You can also edit `markers.json` by hand (format in `compose.py`'s docstring). In this sandbox, get a static ffmpeg with `python3 -m venv v && v/bin/pip install imageio-ffmpeg pillow numpy`, then `FFMPEG=$(ls v/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*)`. Changing the walkthrough itself needs a Mac run.
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
- **A Simulator recording doesn't start when simctl says it does,** and on a busy runner the screen (and screenshots of it) lag the app by seconds. Never trust `recordingStart` or screenshot timing; `compose.py` syncs on how the screen responds to taps and typing.
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
- Every user-facing change gets an e2e step with a `snap(...)` and, if it's visible, a beat in the demo walkthrough, written against the demo checklist and reviewed with `review.py` and the contact sheets.
- Keep `README.md` describing the product and `CLAUDE.md` describing how to work on it.
