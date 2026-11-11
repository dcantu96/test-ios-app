# Demo preview

From `faster-ci` at `9b0af1d`. Thrown away when the PR closes.

[demo.mp4](demo.mp4)

## Demo review

**Nothing flagged** by the automatic checks.

<details><summary>Measurements</summary>

- sync: 8 tap circles checked; offset -0.1s (confidence 0.37)
- dead air: longest still stretch 3.6s
- typing at 6.4s: 20 characters in 1.9s (11/s), longest gap 0.20s
- typing at 21.3s: 28 characters in 2.6s (11/s), longest gap 0.10s
- chapters: Time Capsule 4.2s, Write it. Pick when it opens. 9.0s, Sealed means sealed. 5.9s, When time is up, break the seal. 16.5s, Still there after a relaunch. 4.4s, Time Capsule 4.0s
- length: 44.2s (16s of dead air trimmed)

</details>

6 contact sheets (a frame every 0.5 s) in `sheets/`: read them all.

`source/` holds the synced screen recording and markers: `demo/compose.py --recording source/source.mp4 --markers source/markers.json` redraws the board without a Mac.
