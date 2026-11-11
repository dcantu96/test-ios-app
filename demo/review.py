#!/usr/bin/env python3
"""Review a finished demo video: automatic checks on the pixels, plus contact sheets for a person (or Claude) to read.

    python3 demo/review.py demo.mp4 [--report demo.report.json] [--sheets DIR] [--out review.md] [--strict]

compose.py writes demo.report.json next to the video: what it put where, in output time (chapters, tap ripples,
typing, holds, cuts). This script decodes the phone's screen from the finished MP4 and checks the video against it:

  sync        every tap circle lands on a visible response near what was tapped (no circles on nothing)
  dead air    no stretch where the screen doesn't change for longer than DEAD_AIR outside a deliberate pause,
              and no pause longer than LONG_HOLD
  typing      text appears at a person's pace (TYPE_MIN..TYPE_MAX characters a second) with no stalls
  flashes     nothing pops on screen for under a second and away again (a home screen, a white launch screen)
  blank       no flat one-color screen (a launch screen) outside the dip at a cut
  not the app the phone shows the app (or its sheets), never the home screen
  smoothness  animations show at least SMOOTH_MIN distinct frames a second (a busy Mac drops frames)
  captions    every caption stays up long enough to read
  length      the whole video stays under MAX_LENGTH

Then it tiles a frame every half second into labeled contact sheets (DIR/sheet-NN.jpg). The automatic checks catch
timing; only looking catches the rest (clipped text, wrong screen, ugly moments), so read every sheet.
Exit status is 0 unless --strict and something was flagged.
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compose  # noqa: E402  (FFMPEG, fonts, screen geometry)

FPS = 10
DEAD_AIR = 2.0      # s of unchanging screen outside a pause
LONG_HOLD = 5.0     # s of unchanging screen even inside a pause
TYPE_MIN, TYPE_MAX = 5.0, 30.0   # characters a second
TYPE_STALL = 0.6    # s without a keystroke while typing
SMOOTH_MIN = 24     # distinct frames a second while things move
MAX_LENGTH = 60.0   # s: a demo shows one change; longer means it's touring the app
STATIC = 0.002
PIX = 14


def screen_frames(video, box, w=144):
    x, y, sw, sh = box
    h = int(w * sh / sw)
    raw = subprocess.run([compose.FFMPEG, "-v", "error", "-i", video, "-vf", f"fps={FPS},crop={sw}:{sh}:{x}:{y},scale={w}:{h}:flags=area,format=gray",
                          "-f", "rawvideo", "-"], check=True, capture_output=True).stdout
    n = len(raw) // (w * h)
    return np.frombuffer(raw[: n * w * h], dtype=np.uint8).reshape(n, h, w)


def motion_fps(video, rep):
    """Median distinct frames a second over half-seconds where the phone moves, outside typing and fast-forwards."""
    x, y, sw, sh = rep["screen"]
    raw = subprocess.run([compose.FFMPEG, "-v", "error", "-i", video, "-vf",
                          f"fps=60,crop={sw}:{sh}:{x}:{y},scale=96:208:flags=area,format=gray", "-f", "rawvideo", "-"],
                         check=True, capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, 208, 96).astype(np.int16)
    d = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))
    skip = [(t["start"] - 0.3, t["end"] + 0.3) for t in rep.get("typing", [])] + \
           [(a - 0.3, b + 0.3) for a, b, _ in rep.get("fastForwards", [])] + \
           [(c - 0.6, c + 0.6) for c in rep.get("cuts", [])] + [(0, 0.6), (rep["duration"] - 0.8, 1e9)]
    rates = []
    for i in range(0, len(d) - 30, 30):
        t = i / 60
        if any(a <= t <= b or a <= t + 0.5 <= b for a, b in skip):
            continue
        seg = d[i:i + 30]
        if (seg > 0.3).sum() >= 3:
            rates.append(int((seg > 0.05).sum() * 2))
    return float(np.median(rates)) if rates else None


def app_look(video, box):
    """Per half second: mean saturation and share of near-white pixels on the phone's screen."""
    x, y, sw, sh = box
    raw = subprocess.run([compose.FFMPEG, "-v", "error", "-i", video, "-vf", f"fps=2,crop={sw}:{sh}:{x}:{y},scale=48:104:flags=area",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, 104, 48, 3).astype(np.float32)
    hi, lo = a.max(-1), a.min(-1)
    sat = np.where(hi > 0, (hi - lo) / np.maximum(hi, 1), 0).mean(axis=(1, 2))
    return sat, (lo > 215).mean(axis=(1, 2))


def region(changed, e, grow=0.05):
    n, H, W = changed.shape
    x0, x1 = max(0, e["x"] - e["w"] / 2 - grow), min(1, e["x"] + e["w"] / 2 + grow)
    y0, y1 = max(0, e["y"] - e["h"] / 2 - grow / 2), min(1, e["y"] + e["h"] / 2 + grow / 2)
    sub = changed[:, int(y0 * H): max(int(y0 * H) + 1, int(y1 * H)), int(x0 * W): max(int(x0 * W) + 1, int(x1 * W))]
    return sub.reshape(n, -1).mean(axis=1)


def runs(mask):
    """(start, end) frame indexes of True runs."""
    out, k = [], 0
    while k < len(mask):
        if mask[k]:
            j = k
            while j < len(mask) and mask[j]:
                j += 1
            out.append((k, j))
            k = j
        else:
            k += 1
    return out


def overlap(a, b, spans):
    return sum(max(0.0, min(b, s1) - max(a, s0)) for s0, s1 in spans)


def check(video, rep):
    frames = screen_frames(video, rep["screen"])
    changed = np.zeros(frames.shape, dtype=bool)
    changed[1:] = np.abs(frames[1:].astype(np.int16) - frames[:-1].astype(np.int16)) > PIX
    moving = changed.reshape(len(changed), -1).mean(axis=1)
    T = lambda k: k / FPS
    K = lambda t: int(round(t * FPS))
    flags, notes = [], []

    # sync: a tap circle needs a response near the element, from just before it to shortly after
    # (A change of the whole screen, like an app launching, doesn't count: it would hide a video that's out of sync.)
    for r in rep["ripples"]:
        ser = region(changed, r) - 1.5 * moving
        k0, k1 = max(0, K(r["t"] - 0.4)), min(len(ser), K(r["t"] + 0.9))
        if k1 <= k0 or ser[k0:k1].max() < 0.01:
            flags.append(f"sync: tap circle at {r['t']:.1f}s with no response on the tapped element")
    notes.append(f"sync: {len(rep['ripples'])} tap circles checked; offset {rep['offset']:+.1f}s (confidence {rep['syncConfidence']:.2f})")

    # dead air
    # Deliberate stills (pauses), and typing: one letter changes too few pixels to count as motion on the whole screen.
    holds = rep.get("holds", []) + [[t["start"], t["end"]] for t in rep.get("typing", [])]
    longest = 0.0
    for k0, k1 in runs(moving < STATIC):
        a, b = T(k0), T(k1)
        if a < 0.5 or b > rep["duration"] - 0.5:   # the fade in/out
            a, b = max(a, 0.5), min(b, rep["duration"] - 0.5)
        if b - a <= 0:
            continue
        # The title and end cards are about the caption, not the phone: a still phone there is fine.
        cards = [[c["start"], c["end"]] for c in rep["chapters"] if c.get("style") in ("title", "end")]
        if (b - a) - overlap(a, b, cards) <= 0.3:
            continue
        a2 = max([a] + [c1 for c0, c1 in cards if c0 <= a < c1])
        b2 = min([b] + [c0 for c0, c1 in cards if c0 < b <= c1])
        a, b = a2, b2
        if b - a <= 0:
            continue
        longest = max(longest, b - a)
        outside = (b - a) - overlap(a, b, holds)
        if outside > DEAD_AIR:
            flags.append(f"dead air: the screen doesn't change for {b - a:.1f}s at {a:.1f}-{b:.1f}s ({outside:.1f}s of it isn't a pause)")
        elif b - a > LONG_HOLD:
            flags.append(f"long pause: the screen holds still for {b - a:.1f}s at {a:.1f}-{b:.1f}s")
    notes.append(f"dead air: longest still stretch {longest:.1f}s")

    # typing
    for tp in rep.get("typing", []):
        a, b = tp["start"], tp["end"]
        if b - a < 0.05 or not tp.get("chars"):
            continue
        ser = region(changed, tp, grow=0.02)
        ks = [k for k in range(K(a), min(len(ser), K(b) + 1)) if ser[k] > 0.004]
        if not ks:
            flags.append(f"typing: nothing visible typed at {a:.1f}-{b:.1f}s (if several, the video is probably out of sync)")
            continue
        span = max(T(ks[-1] - ks[0]), 0.1)
        rate = tp["chars"] / span
        gaps = [T(y - x) for x, y in zip(ks, ks[1:])]
        stall = max(gaps) if gaps else 0
        notes.append(f"typing at {a:.1f}s: {tp['chars']} characters in {span:.1f}s ({rate:.0f}/s), longest gap {stall:.2f}s")
        if rate < TYPE_MIN:
            flags.append(f"typing: {rate:.1f} characters a second at {a:.1f}s is slower than a person types")
        if rate > TYPE_MAX:
            flags.append(f"typing: {rate:.0f} characters a second at {a:.1f}s is faster than a person types")
        if stall > TYPE_STALL:
            flags.append(f"typing: stalls for {stall:.1f}s mid-message at {a:.1f}s")

    # flashes: a big change that is undone within a second
    cuts = rep.get("cuts", [])
    for k in range(1, len(frames) - 12):
        if moving[k] > 0.5:
            before = frames[k - 1].astype(np.int16)
            for j in range(k + 1, min(len(frames), k + 10)):
                if moving[j] > 0.5 and np.mean(np.abs(frames[j].astype(np.int16) - before) > PIX) < 0.05:
                    t = T(k)
                    if not any(abs(t - c) < 0.6 for c in cuts):
                        flags.append(f"flash: something pops on screen for {T(j - k):.1f}s at {t:.1f}s")
                    break

    # blank screens: a launch screen or anything else that's one flat color (outside the dip at a cut)
    for k0, k1 in runs(np.array([(np.abs(fr.astype(np.int16) - int(np.median(fr))) <= 12).mean() > 0.95 for fr in frames])):
        a, b = T(k0), T(k1)
        if b - a >= 0.4 and not any(a - 0.6 <= c <= b + 0.6 for c in cuts) and 0.5 < b and a < rep["duration"] - 0.7:
            flags.append(f"blank screen: the phone shows one flat color for {b - a:.1f}s at {a:.1f}s (a launch screen?)")

    # not the app: the phone must show this app (vivid gradient, or one of its white sheets), not the home screen
    # or another app. Measured on real videos: app 0.40-0.65 saturation, its sheets 0.4-0.85 white, the home
    # screen 0.24 saturation and 0.04 white. (PR #4's video ended on 8 s of home screen and nothing else noticed.)
    sat, white = app_look(video, rep["screen"])
    looks_wrong = np.array([sv < 0.35 and wv < 0.3 for sv, wv in zip(sat, white)])
    for k0, k1 in runs(looks_wrong):
        a, b = k0 / 2, min(k1 / 2, rep["duration"] - 0.8)  # the closing fade doesn't count
        for c in cuts:  # neither does the half-second dip to black at a cut
            if a - 0.5 <= c <= a + 0.5:
                a = max(a, c + 0.5)
        if b - a >= 1.0:
            flags.append(f"not the app: the phone shows something else (home screen?) for {b - a:.1f}s at {a:.1f}s")
    notes.append(f"app on screen: {100 * (1 - looks_wrong.mean()):.0f}% of the video")

    # smoothness: how many distinct frames a second the phone shows while something moves at normal speed (not
    # typing, which is re-timed, and not fast-forwards). The Simulator drops frames when the Mac is busy; under
    # ~24 a second animations visibly stutter (PR #4: 10).
    fps = motion_fps(video, rep)
    if fps is not None:
        notes.append(f"smoothness: {fps:.0f} distinct frames a second while things move")
        if fps < SMOOTH_MIN:
            flags.append(f"choppy: animations show only {fps:.0f} frames a second (the Mac was busy while recording)")

    # captions
    for ch in rep["chapters"]:
        shown = ch["end"] - ch["start"]
        if shown + 0.05 < ch["reading"]:
            flags.append(f"caption '{ch['title']}' is up {shown:.1f}s, needs ~{ch['reading']:.1f}s to read")
    notes.append("chapters: " + ", ".join(f"{c['title']} {c['end'] - c['start']:.1f}s" for c in rep["chapters"]))

    if rep["duration"] > MAX_LENGTH:
        flags.append(f"length: {rep['duration']:.0f}s is longer than {MAX_LENGTH:.0f}s")
    notes.append(f"length: {rep['duration']:.1f}s ({rep.get('trimmed', 0):.0f}s of dead air trimmed)")
    return flags, notes


def sheets(video, out_dir, step=0.5, cols=4, rows=4):
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, "_frames")
    os.makedirs(tmp, exist_ok=True)
    subprocess.run([compose.FFMPEG, "-v", "error", "-y", "-i", video, "-vf", f"fps={1 / step},scale=480:-1", os.path.join(tmp, "%05d.png")], check=True)
    files = sorted(os.listdir(tmp))
    f = ImageFont.truetype(os.path.join(compose.FONTS, "Inter.ttf"), 22)
    paths = []
    per = cols * rows
    for s in range(0, len(files), per):
        sheet = Image.new("RGB", (480 * cols, 270 * rows))
        for i, name in enumerate(files[s:s + per]):
            im = Image.open(os.path.join(tmp, name)).convert("RGB")
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 86, 28), fill="black")
            d.text((6, 2), f"{(s + i) * step:.1f}s", fill="yellow", font=f)
            sheet.paste(im, ((i % cols) * 480, (i // cols) * 270))
        p = os.path.join(out_dir, f"sheet-{s // per:02d}.jpg")
        sheet.save(p, quality=85)
        paths.append(p)
    for name in files:
        os.remove(os.path.join(tmp, name))
    os.rmdir(tmp)
    return paths


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--report")
    ap.add_argument("--sheets", help="write contact sheets here")
    ap.add_argument("--out", help="write the review as Markdown here")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    rep = json.load(open(a.report or os.path.splitext(a.video)[0] + ".report.json"))
    flags, notes = check(a.video, rep)
    lines = ["## Demo review", "", f"**{len(flags)} flagged**" if flags else "**Nothing flagged** by the automatic checks.", ""]
    lines += [f"- ⚠️ {x}" for x in flags] + ([""] if flags else [])
    lines += ["<details><summary>Measurements</summary>", ""] + [f"- {x}" for x in notes] + ["", "</details>"]
    if a.sheets:
        ps = sheets(a.video, a.sheets)
        lines += ["", f"{len(ps)} contact sheets (a frame every 0.5 s) in `{os.path.basename(a.sheets.rstrip('/'))}/`: read them all."]
    text = "\n".join(lines) + "\n"
    if a.out:
        open(a.out, "w").write(text)
    print(text)
    sys.exit(1 if (a.strict and flags) else 0)


if __name__ == "__main__":
    main()
