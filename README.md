# Time Capsule

Write a message to your future self and seal it for 10 seconds, a minute, a day or a year. A SwiftUI iOS app, a small Node API, and Postgres. Everything builds and is tested end to end on a GitHub-hosted Mac, with no Mac on your desk involved.

The twist: **the server is the lock.** While a capsule is sealed, the API never sends its message, not even to the app. Asking early gets `423 Locked` with the seconds remaining. When the time is up, tapping the capsule cracks the wax seal open and the server reveals the message (and records when you first opened it).

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app (iOS 26+ SDK, Liquid Glass). Reads the API from `API_URL`, defaulting to `http://localhost:8787` |
| `UITests/` | XCUITest end-to-end suite |
| `api/` | Node 24 + TypeScript API (`node:http` + `pg`), SQL migrations, `node --test` integration tests |
| `scripts/start-backend.sh` | Starts Postgres 17, runs the API tests, starts the API |
| `scripts/run-e2e.sh` | Picks the newest Xcode and iOS Simulator, runs the UI tests with video, exports step screenshots |
| `scripts/publish-output.sh` | Pushes the run's screenshots, video and logs to the `simulator-output` branch |

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

Each step saves a screenshot. CI runs on the `xcode-27` runner, records the whole test as `e2e.mp4`, and publishes everything to the [`simulator-output`](../../tree/simulator-output) branch.

## Run it locally (on a Mac)

```sh
brew install xcodegen postgresql@17
createdb capsules
cd api && npm ci && DATABASE_URL=postgres://localhost/capsules npm start
# in another terminal
xcodegen generate && open CloudSim.xcodeproj   # Cmd+U runs the e2e test
```
