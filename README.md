# Demo preview

From `knocks` at `8a4b56b`. Thrown away when the PR closes.

[demo.mp4](demo.mp4)

## Demo review

**Nothing flagged** by the automatic checks.

<details><summary>Measurements</summary>

- sync: 9 tap circles checked; offset -45.3s (confidence 0.15)
- dead air: longest still stretch 4.1s
- typing at 6.4s: 20 characters in 1.9s (11/s), longest gap 0.20s
- typing at 27.8s: 28 characters in 2.5s (11/s), longest gap 0.20s
- chapters: Time Capsule 4.2s, Write it. Pick when it opens. 9.4s, Sealed means sealed. 5.9s, Knock again. It's counted. 6.2s, When time is up, break the seal. 16.7s, Still there after a relaunch. 5.0s, Time Capsule 4.0s
- length: 51.6s (19s of dead air trimmed)

</details>

7 contact sheets (a frame every 0.5 s) in `sheets/`: read them all.

`source/` holds the synced screen recording and markers: `demo/compose.py --recording source/source.mp4 --markers source/markers.json` redraws the board without a Mac.
