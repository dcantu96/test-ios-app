# Time Capsule

Write a message to your future self and seal it for 10 seconds, a minute, a day or a year. A SwiftUI iOS app, a small Node API, and Postgres. Everything builds and is tested end to end on a GitHub-hosted Mac, with no Mac on your desk involved.

The twist: **the server is the lock.** While a capsule is sealed, the API never sends its message, not even to the app. Asking early gets `423 Locked` with the seconds remaining. When the time is up, tapping the capsule cracks the wax seal open and the server reveals the message (and records when you first opened it).

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app (iOS 26+ SDK, Liquid Glass). Reads the API from `API_URL`, defaulting to `http://localhost:8787` |
| `UITests/` | XCUITest end-to-end suite: the merge gate |
| `DemoTests/` | A human-paced walkthrough that CI records as each PR's demo video (not a test gate) |
| `demo/compose.py` | Turns a Simulator recording plus the walkthrough's markers into a 1080p60 MP4 |
| `api/` | Node 24 + TypeScript API (`node:http` + `pg`), SQL migrations, `node --test` integration tests |
| `scripts/start-backend.sh` | Starts Postgres 17, runs the API tests, starts the API |
| `scripts/sim-setup.sh` | Picks the newest Xcode, iOS runtime and an iPhone Pro, and boots it |
| `scripts/run-e2e.sh` | Runs the e2e suite and exports step screenshots |
| `scripts/run-demo.sh` | Records the demo walkthrough and its markers |
| `scripts/publish-output.sh` | Pushes a run's screenshots and logs to `e2e-output/<branch>` |

## API

| | |
|---|---|
| `GET /health` | DB check |
| `POST /capsules` `{ message, unlockInSeconds }` | Seal a capsule (the response never includes the message) |
| `GET /capsules` | Newest first; only opened capsules include their message |
| `GET /capsules/:id` | `423 Locked` while sealed; otherwise opens it and returns the message |

## The e2e test

`UITests/TimeCapsuleUITests.swift` drives the real app against the real API and database:

1. Launch, then write a message and seal it for 10 seconds.
2. Check that the capsule shows as sealed and the message is not on screen.
3. Tap it early. The server answers 423 and the app shows "Still sealed".
4. Wait for the countdown, then tap again. The seal cracks and the message is revealed.
5. Kill and relaunch the app. The opened capsule comes back from Postgres.

Each step saves a screenshot.

## CI

- **E2E** (`.github/workflows/e2e.yml`) runs on every PR into `main` and every push to `main`, on GitHub's `xcode-27` macOS runner: API tests against Postgres, then the e2e suite in the Simulator against the live API. It's the check that has to pass before merging. Screenshots and logs go to `e2e-output/<branch>`.
- **Demo** (`.github/workflows/demo.yml`) runs when a PR opens, when it gets the `demo` label, or by hand. A Mac records the walkthrough, a Linux runner composes it into `demo.mp4`, and a comment on the PR links to it on `demo-preview/<branch>`.
- **Cleanup** (`.github/workflows/cleanup.yml`) deletes a PR's `demo-preview/` and `e2e-output/` branches when it closes.

## Run it locally (on a Mac)

```sh
brew install xcodegen postgresql@17
createdb capsules
cd api && npm ci && DATABASE_URL=postgres://localhost/capsules npm start
# in another terminal
xcodegen generate && open CloudSim.xcodeproj   # Cmd+U on the CloudSim scheme runs the e2e test
```
